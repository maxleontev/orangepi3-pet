#!/bin/sh
# =============================================================================
# wifi-usb-connect — STA on a secondary USB WiFi stick (ath9k_htc, …)
# =============================================================================
#
# wifi-connect owns wlan0 (AP6256) and may start the setup AP. This service
# waits for any other wireless netdev, associates with the same
# /data/wifi.conf, and runs DHCP with a higher default-route metric so
# onboard wlan0 stays the preferred gateway.
#
# Long-running (not a one-shot): if the stick is unplugged/replugged or the
# radio drops and comes back, we re-associate and ask for an IPv4 again.
# Missing stick or setup-AP mode → idle and retry (do not exit).
#
# Env: SKIP_IFACE, CONF, WAIT_IFACE_SEC, WAIT_ASSOC_SEC, DHCP_METRIC, POLL_SEC
# =============================================================================
set -eu

SKIP_IFACE="${SKIP_IFACE:-wlan0}"
CONF="${CONF:-/data/wifi.conf}"
WAIT_IFACE_SEC="${WAIT_IFACE_SEC:-45}"
WAIT_ASSOC_SEC="${WAIT_ASSOC_SEC:-60}"
DHCP_METRIC="${DHCP_METRIC:-100}"
POLL_SEC="${POLL_SEC:-5}"

log() { printf 'wifi-usb: %s\n' "$*" >&2; }

find_usb_wifi() {
	for path in /sys/class/net/*/phy80211 /sys/class/net/*/wireless; do
		[ -e "$path" ] || continue
		iface=$(basename "$(dirname "$path")")
		[ "$iface" = "$SKIP_IFACE" ] && continue
		printf '%s\n' "$iface"
		return 0
	done
	return 1
}

wait_iface() {
	i=0
	while [ "$i" -lt "$WAIT_IFACE_SEC" ]; do
		if IFACE=$(find_usb_wifi); then
			export IFACE
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

has_ipv4() {
	ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q 'inet '
}

cleanup_iface() {
	[ -n "${IFACE:-}" ] || return 0
	if [ -f "/run/udhcpc-${IFACE}.pid" ]; then
		kill "$(cat "/run/udhcpc-${IFACE}.pid")" 2>/dev/null || true
		rm -f "/run/udhcpc-${IFACE}.pid"
	fi
	# BusyBox may leave a nameless child; match by iface arg.
	pkill -f "udhcpc -i ${IFACE}" 2>/dev/null || true
	if [ -f "/run/wpa_supplicant-${IFACE}.pid" ]; then
		kill "$(cat "/run/wpa_supplicant-${IFACE}.pid")" 2>/dev/null || true
		rm -f "/run/wpa_supplicant-${IFACE}.pid"
	fi
	wpa_cli -i "$IFACE" terminate 2>/dev/null || true
	rm -f "/var/run/wpa_supplicant/$IFACE" "/run/wpa_supplicant/$IFACE" 2>/dev/null || true
	ip -4 addr flush dev "$IFACE" 2>/dev/null || true
	sleep 1
}

assoc_state() {
	wpa_cli -i "$IFACE" status 2>/dev/null | sed -n 's/^wpa_state=//p' | tr -d '\r'
}

wait_associated() {
	i=0
	while [ "$i" -lt "$WAIT_ASSOC_SEC" ]; do
		st=$(assoc_state || true)
		if [ "$st" = "COMPLETED" ]; then
			log "associated on $IFACE ($st)"
			return 0
		fi
		if [ $((i % 10)) -eq 0 ]; then
			wpa_cli -i "$IFACE" enable_network all >/dev/null 2>&1 || true
			wpa_cli -i "$IFACE" reassociate >/dev/null 2>&1 || true
			wpa_cli -i "$IFACE" scan >/dev/null 2>&1 || true
			log "waiting ($IFACE state=${st:-unknown}) ${i}/${WAIT_ASSOC_SEC}"
		fi
		i=$((i + 1))
		sleep 1
	done
	log "association timeout on $IFACE; last=$(assoc_state || echo none)"
	return 1
}

raise_default_metric() {
	# udhcpc installs metric 10; bump USB default so wlan0 stays preferred.
	gw=$(ip -4 route show default dev "$IFACE" 2>/dev/null \
		| sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -n1)
	[ -n "$gw" ] || return 0
	ip route del default via "$gw" dev "$IFACE" 2>/dev/null || true
	ip route add default via "$gw" dev "$IFACE" metric "$DHCP_METRIC" 2>/dev/null || true
}

# One-shot lease attempt, then leave a background client to renew.
# If already associated but address was lost, call again.
ensure_dhcp() {
	if has_ipv4; then
		raise_default_metric
		return 0
	fi
	if [ -f "/run/udhcpc-${IFACE}.pid" ]; then
		kill "$(cat "/run/udhcpc-${IFACE}.pid")" 2>/dev/null || true
		rm -f "/run/udhcpc-${IFACE}.pid"
	fi
	pkill -f "udhcpc -i ${IFACE}" 2>/dev/null || true
	ip -4 addr flush dev "$IFACE" 2>/dev/null || true
	# -n: fail this attempt if no lease; -b: keep renewing after success.
	# No -q: do not exit after the first lease (that was the old bug).
	if udhcpc -i "$IFACE" -n -b -p "/run/udhcpc-${IFACE}.pid" -t 10 -T 3; then
		raise_default_metric
		log "DHCP ok on $IFACE metric=${DHCP_METRIC}"
		return 0
	fi
	log "DHCP failed on $IFACE (link up, no lease)"
	return 1
}

wpa_running() {
	[ -f "/run/wpa_supplicant-${IFACE}.pid" ] || return 1
	kill -0 "$(cat "/run/wpa_supplicant-${IFACE}.pid")" 2>/dev/null
}

start_wpa() {
	cleanup_iface
	ip link set "$IFACE" up
	iw dev "$IFACE" set power_save off 2>/dev/null || true
	wpa_supplicant -B -i "$IFACE" -c "$CONF" -P "/run/wpa_supplicant-${IFACE}.pid"
	i=0
	while [ "$i" -lt 10 ]; do
		[ -S "/var/run/wpa_supplicant/$IFACE" ] || [ -S "/run/wpa_supplicant/$IFACE" ] && break
		i=$((i + 1))
		sleep 1
	done
}

# Watch one stick until it disappears (unplug) or we give up on assoc.
run_session() {
	log "using $IFACE"
	start_wpa
	if ! wait_associated; then
		cleanup_iface
		return 1
	fi
	ensure_dhcp || true

	while [ -d "/sys/class/net/$IFACE" ]; do
		if ! wpa_running; then
			log "wpa gone on $IFACE; restart session"
			return 1
		fi
		st=$(assoc_state || true)
		if [ "$st" = "COMPLETED" ]; then
			if ! has_ipv4; then
				log "associated but no IPv4; DHCP again"
				ensure_dhcp || true
			else
				raise_default_metric
			fi
		else
			# Brief drop: nudge wpa; address may already be gone.
			wpa_cli -i "$IFACE" enable_network all >/dev/null 2>&1 || true
			wpa_cli -i "$IFACE" reassociate >/dev/null 2>&1 || true
		fi
		sleep "$POLL_SEC"
	done
	log "iface $IFACE gone (unplugged?)"
	cleanup_iface
	return 0
}

log "supervisor start"
while true; do
	if [ -f /run/wifi-mode ] && [ "$(cat /run/wifi-mode)" = "ap" ]; then
		log "setup AP mode; idle"
		sleep 30
		continue
	fi

	if [ ! -f "$CONF" ] || ! grep -q 'ssid=' "$CONF" 2>/dev/null; then
		log "no networks in $CONF; idle"
		sleep 30
		continue
	fi

	if ! wait_iface; then
		# Stick absent: keep waiting forever (replug recovers without reboot).
		log "no USB wireless iface; wait ${WAIT_IFACE_SEC}s"
		continue
	fi

	run_session || sleep "$POLL_SEC"
done
