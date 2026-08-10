#!/bin/sh
# =============================================================================
# wifi-connect — bring up wlan0 on Orange Pi 3 (AP6256 / brcmfmac)
# =============================================================================
#
# Why a dedicated script instead of a chain of ExecStartPre in wifi.service
# -------------------------------------------------------------------------
# The old unit roughly did: "wait for wlan0 → ip link up → wpa_supplicant -B
# → udhcpc -b" and immediately reported success. In practice that produced a
# false "active (exited)" while the link was dead:
#   - wpa_state=SCANNING or DISCONNECTED;
#   - operstate=down;
#   - yet the iface still held a stale IPv4 (e.g. 192.168.3.71) from a previous
#     half-association / DHCP — the host looked "alive" on ping, SSH was not.
#
# Current scheme: one oneshot script that
#   1) waits for the iface to appear,
#   2) cleans leftovers from a previous run,
#   3) brings the link up and disables powersave,
#   4) starts wpa_supplicant,
#   5) blocks until wpa_state=COMPLETED (or fails on timeout),
#   6) only then runs DHCP.
# If COMPLETED is never reached — non-zero exit → systemd Restart=on-failure
# (see wifi.service) retries after reboot / AP glitches.
#
# Problems this closes (from on-device debugging)
# -----------------------------------------------
# 1. Asynchronous brcmfmac probe
#    wlan0 appears seconds after systemd-modules-load (SDIO + firmware).
#    ConditionPathExists=/sys/class/net/wlan0 is often false at unit start and
#    simply skips the service. Wait for the iface in a loop here instead.
#
# 2. "Match already configured" / sticky ctrl iface
#    Restarting wpa_supplicant while a previous process or leftover socket
#    /var/run/wpa_supplicant/wlan0 remains breaks bring-up. cleanup_stale kills
#    wpa_supplicant/udhcpc and removes ctrl-iface sockets.
#
# 3. Unit success without association
#    Wait specifically for COMPLETED via wpa_cli. While SCANNING/ASSOCIATING,
#    do not call DHCP. On timeout, print scan_results (shows whether the chip
#    sees the SSID at all).
#
# 4. Stuck in SCANNING while the AP is visible
#    Observed: Chuck Norris present in scan_results, but association never
#    completes. Periodically: enable_network all + reassociate + scan. Do NOT
#    use select_network N — that disables other network{} blocks (broke 5 GHz
#    preference and wifi-roam; earlier select_network 0 hard-pinned only the
#    2.4 GHz "Chuck Norris" network).
#
# 5. AP6256 powersave
#    With PS enabled, association / link hold is less reliable on this combo;
#    power_save off before starting wpa_supplicant.
#
# 6. DHCP on a half-alive iface and stale IP
#    udhcpc only after COMPLETED; flush IPv4 beforehand so we do not keep an
#    old address while down/SCANNING (typical after a drop, including when the
#    link came up at boot and later fell).
#
# 7. RF / HDMI (outside this script, but explains symptoms)
#    Loading sun4i_drm/HDMI after a successful 2.4 GHz COMPLETED dropped the
#    link into SCANNING/operstate=down (HDMI pixel-clock coexistence with
#    AP6256). Fixed at image level (do not autoload DRM at boot). wifi-connect
#    must still fail honestly and retry, not mask the drop as a "successful"
#    unit with a stale IP.
#
# 8. Dual SSID (2.4 + 5 GHz) and band selection
#    SSID list lives in /data/wpa_supplicant.conf. Ongoing choice by measured
#    RSSI is wifi-roam (wpa priority alone will not leave a weaker COMPLETED
#    BSS for a louder one on the other band).
#
# Optional env: IFACE, CONF, WAIT_IFACE_SEC, WAIT_ASSOC_SEC
# =============================================================================
set -eu

IFACE="${IFACE:-wlan0}"
CONF="${CONF:-/data/wpa_supplicant.conf}"
WAIT_IFACE_SEC="${WAIT_IFACE_SEC:-30}"
WAIT_ASSOC_SEC="${WAIT_ASSOC_SEC:-60}"

log() { printf 'wifi-connect: %s\n' "$*"; }

cleanup_stale() {
	# Problem: re-ExecStart / manual wifi-connect with a live wpa_supplicant or
	# leftover ctrl socket → start failure or a silently stuck client. Kill
	# daemons first, then remove sockets.
	killall wpa_supplicant udhcpc 2>/dev/null || true
	rm -f "/var/run/wpa_supplicant/$IFACE" "/run/wpa_supplicant/$IFACE" 2>/dev/null || true
	sleep 1
}

wait_iface() {
	# Problem: brcmfmac creates the netdev after the unit starts; without a
	# wait this is a false failure.
	i=0
	while [ "$i" -lt "$WAIT_IFACE_SEC" ]; do
		[ -d "/sys/class/net/$IFACE" ] && return 0
		i=$((i + 1))
		sleep 1
	done
	log "$IFACE not found after ${WAIT_IFACE_SEC}s"
	return 1
}

assoc_state() {
	wpa_cli -i "$IFACE" status 2>/dev/null | sed -n 's/^wpa_state=//p' | tr -d '\r'
}

wait_associated() {
	# Problem: "wpa is running" ≠ "on the network". Only COMPLETED counts.
	# While SCANNING, nudge scan/reassociate without pinning one network id.
	i=0
	while [ "$i" -lt "$WAIT_ASSOC_SEC" ]; do
		st=$(assoc_state || true)
		case "$st" in
			COMPLETED)
				log "associated ($st)"
				return 0
				;;
			*)
				;;
		esac
		if [ $((i % 10)) -eq 0 ]; then
			wpa_cli -i "$IFACE" enable_network all >/dev/null 2>&1 || true
			wpa_cli -i "$IFACE" reassociate >/dev/null 2>&1 || true
			wpa_cli -i "$IFACE" scan >/dev/null 2>&1 || true
			log "waiting for association (state=${st:-unknown}) ${i}/${WAIT_ASSOC_SEC}"
		fi
		i=$((i + 1))
		sleep 1
	done
	# Diagnostics: on timeout, see empty air vs AP visible but auth/assoc fail.
	log "association timeout; last state=$(assoc_state || echo none)"
	wpa_cli -i "$IFACE" scan_results 2>/dev/null || true
	return 1
}

wait_iface
cleanup_stale

ip link set "$IFACE" down 2>/dev/null || true
ip link set "$IFACE" up
iw dev "$IFACE" set power_save off 2>/dev/null || true

wpa_supplicant -B -i "$IFACE" -c "$CONF" -P /run/wpa_supplicant-"$IFACE".pid
# ctrl iface is required for wpa_cli in wait_associated; without a pause the
# first status calls are empty.
i=0
while [ "$i" -lt 10 ]; do
	[ -S "/var/run/wpa_supplicant/$IFACE" ] || [ -S "/run/wpa_supplicant/$IFACE" ] && break
	i=$((i + 1))
	sleep 1
done

wait_associated

ip -4 addr flush dev "$IFACE" 2>/dev/null || true
udhcpc -i "$IFACE" -n -q -t 10 -T 3
log "DHCP done; operstate=$(cat /sys/class/net/$IFACE/operstate 2>/dev/null || echo ?)"
