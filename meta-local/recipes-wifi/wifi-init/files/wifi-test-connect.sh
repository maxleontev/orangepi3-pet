#!/bin/sh
# Try STA association with given SSID/PSK, then restore setup AP.
# Hard budget: ~20s for associate+DHCP, then always restore setup AP.
# Writes JSON status to /run/wifi-test-result (no password in output).
# Usage: wifi-test-connect 'SSID' ['PSK']
set -eu

IFACE="${IFACE:-wlan0}"
RESULT="${RESULT:-/run/wifi-test-result}"
LOCK="${LOCK:-/run/wifi-test.lock}"
TMP_CONF="${TMP_CONF:-/run/wifi-test.conf}"
# Total STA attempt budget (assoc + DHCP). AP restore is extra.
TEST_BUDGET_SEC="${TEST_BUDGET_SEC:-20}"
WAIT_ASSOC_SEC="${WAIT_ASSOC_SEC:-15}"
DHCP_TRIES="${DHCP_TRIES:-4}"
DHCP_TIMEOUT="${DHCP_TIMEOUT:-1}"

SSID=${1:-}
PSK=${2:-}
RESTORED=0

log() { printf 'wifi-test-connect: %s\n' "$*" >&2; }

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

now_s() { date +%s; }

write_result() {
	status=$1
	connected=$2
	reason=${3:-}
	ip=${4:-}
	esc_ssid=$(json_escape "$SSID")
	esc_reason=$(json_escape "$reason")
	esc_ip=$(json_escape "$ip")
	cat > "$RESULT" <<EOF
{"status":"$status","connected":$connected,"ssid":"$esc_ssid","reason":"$esc_reason","ip":"$esc_ip"}
EOF
}

cleanup_sta() {
	killall udhcpc wpa_supplicant 2>/dev/null || true
	rm -f "/var/run/wpa_supplicant/$IFACE" "/run/wpa_supplicant/$IFACE" \
		"/run/wpa_supplicant-${IFACE}.pid" "$TMP_CONF" 2>/dev/null || true
	ip -4 addr flush dev "$IFACE" 2>/dev/null || true
}

recover_radio() {
	log "reloading brcmfmac"
	killall hostapd dnsmasq lighttpd udhcpc wpa_supplicant 2>/dev/null || true
	modprobe -r brcmfmac brcmutil 2>/dev/null || true
	sleep 2
	modprobe brcmfmac 2>/dev/null || true
	sleep 2
}

restore_ap() {
	[ "$RESTORED" = "1" ] && return 0
	RESTORED=1
	cleanup_sta
	# Skip pre-AP scan — iw scan after STA teardown often hangs on brcmfmac.
	if ! SKIP_SCAN=1 /usr/sbin/wifi-ap-start; then
		log "wifi-ap-start failed; recovering radio"
		recover_radio
		SKIP_SCAN=1 /usr/sbin/wifi-ap-start || log "failed to restore setup AP"
	fi
}

assoc_state() {
	wpa_cli -i "$IFACE" status 2>/dev/null | sed -n 's/^wpa_state=//p' | tr -d '\r'
}

if [ -z "$SSID" ]; then
	write_result fail false "missing_ssid"
	exit 1
fi

if [ -f "$LOCK" ]; then
	if [ -n "$(find "$LOCK" -mmin +3 2>/dev/null)" ]; then
		rm -f "$LOCK"
	else
		write_result fail false "busy"
		exit 1
	fi
fi
printf '%s\n' "$$" > "$LOCK"
trap 'restore_ap; rm -f "$LOCK"' EXIT INT TERM

write_result testing false "in_progress"
deadline=$(($(now_s) + TEST_BUDGET_SEC))

/usr/sbin/wifi-ap-stop 2>/dev/null || true
sleep 1

if [ ! -d "/sys/class/net/$IFACE" ]; then
	recover_radio
fi

{
	cat <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant
update_config=0
ap_scan=1
country=${COUNTRY:-RU}

network={
	ssid="$SSID"
EOF
	if [ -n "$PSK" ]; then
		printf '\tpsk="%s"\n' "$PSK"
		cat <<EOF
	key_mgmt=WPA-PSK
	proto=RSN
	pairwise=CCMP
	group=CCMP TKIP
EOF
	else
		cat <<EOF
	key_mgmt=NONE
EOF
	fi
	cat <<EOF
	scan_ssid=1
	priority=10
}
EOF
} > "$TMP_CONF"
chmod 0600 "$TMP_CONF"

ip link set "$IFACE" down 2>/dev/null || true
ip -4 addr flush dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" up
iw dev "$IFACE" set power_save off 2>/dev/null || true

wpa_supplicant -B -i "$IFACE" -c "$TMP_CONF" -P /run/wpa_supplicant-"$IFACE".pid

i=0
while [ "$i" -lt 5 ]; do
	[ -S "/var/run/wpa_supplicant/$IFACE" ] || [ -S "/run/wpa_supplicant/$IFACE" ] && break
	i=$((i + 1))
	sleep 1
done

ok=0
i=0
while [ "$i" -lt "$WAIT_ASSOC_SEC" ]; do
	[ "$(now_s)" -lt "$deadline" ] || break
	st=$(assoc_state || true)
	case "$st" in
		COMPLETED)
			ok=1
			break
			;;
	esac
	# Do NOT call wpa_cli scan here — it can hang brcmfmac until reboot.
	if [ $((i % 5)) -eq 0 ]; then
		wpa_cli -i "$IFACE" reassociate >/dev/null 2>&1 || true
	fi
	i=$((i + 1))
	sleep 1
done

ip_addr=""
if [ "$ok" -eq 1 ]; then
	ip -4 addr flush dev "$IFACE" 2>/dev/null || true
	remain=$((deadline - $(now_s)))
	if [ "$remain" -lt 2 ]; then
		write_result fail false "dhcp_timeout"
		log "test FAIL ssid='$SSID' reason=dhcp_timeout"
	elif udhcpc -i "$IFACE" -n -q -t "$DHCP_TRIES" -T "$DHCP_TIMEOUT"; then
		ip_addr=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sed -n '1p')
		write_result ok true "connected" "$ip_addr"
		log "test OK ssid='$SSID' ip='${ip_addr:-?}'"
	else
		write_result fail false "dhcp_failed"
		log "test FAIL ssid='$SSID' reason=dhcp_failed"
	fi
else
	st=$(assoc_state || echo none)
	write_result fail false "no_associate:$st"
	log "test FAIL ssid='$SSID' reason=no_associate state=$st"
fi

restore_ap
log "setup AP restored after test"
