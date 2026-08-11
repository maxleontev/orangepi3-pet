#!/bin/sh
# Start open setup AP + DHCP + web UI when STA mode is unavailable.
set -eu

IFACE="${IFACE:-wlan0}"
CONF="${CONF:-/data/wifi.conf}"
HOSTAPD_TMPL="${HOSTAPD_TMPL:-/usr/share/wifi-setup/hostapd-ap.conf}"
HTTPD_ROOT="${HTTPD_ROOT:-/usr/share/wifi-setup/www}"

. /usr/share/wifi-setup/wifi-conf-lib.sh

log() { printf 'wifi-ap-start: %s\n' "$*" >&2; }

ap_ssid() {
	if [ -n "${AP_SSID:-}" ]; then
		printf '%s\n' "$AP_SSID"
		return 0
	fi
	mac=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null | tr -d ':')
	suffix=$(echo "$mac" | awk '{ print substr($0, length($0)-3) }')
	printf 'Khepri-Setup-%s\n' "$suffix"
}

write_hostapd_conf() {
	ssid=$(ap_ssid)
	{
		cat <<EOF
interface=$IFACE
driver=nl80211
ssid=$ssid
hw_mode=g
channel=${AP_CHANNEL:-6}
ieee80211n=1
wmm_enabled=0
ignore_broadcast_ssid=0
auth_algs=1
wpa=0
country_code=${COUNTRY:-RU}
ieee80211d=1
EOF
	} > /run/hostapd-ap.conf
	chmod 0600 /run/hostapd-ap.conf
	# Ephemeral runtime only — never persist under /data.
	rm -f /data/hostapd-ap.conf /data/lighttpd-wifi-setup.conf 2>/dev/null || true
	log "AP SSID=$ssid on $IFACE ($AP_IP/$AP_PREFIX)"
}

wait_iface() {
	i=0
	while [ "$i" -lt 30 ]; do
		[ -d "/sys/class/net/$IFACE" ] && return 0
		i=$((i + 1))
		sleep 1
	done
	return 1
}

wifi_load_setup_ap
COUNTRY="${COUNTRY:-}"
if [ -z "$COUNTRY" ] && [ -f "$CONF" ]; then
	COUNTRY=$(sed -n 's/^country=//p' "$CONF" | sed -n '1p')
fi
COUNTRY="${COUNTRY:-RU}"

killall wpa_supplicant udhcpc 2>/dev/null || true
rm -f "/var/run/wpa_supplicant/$IFACE" "/run/wpa_supplicant/$IFACE" 2>/dev/null || true

wait_iface || { log "$IFACE not found"; exit 1; }

write_hostapd_conf

ip link set "$IFACE" down 2>/dev/null || true
ip -4 addr flush dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" up
iw dev "$IFACE" set power_save off 2>/dev/null || true

# Scan before hostapd (skipped on fast AP restore after connection test).
if [ "${SKIP_SCAN:-0}" != "1" ]; then
	/usr/sbin/wifi-scan >/dev/null 2>&1 || true
fi

ip addr add "$AP_IP/$AP_PREFIX" dev "$IFACE"

hostapd -B -P /run/hostapd-ap.pid /run/hostapd-ap.conf

# Stock dnsmasq.service binds :53 and breaks our AP DHCP/DNS instance.
systemctl stop dnsmasq.service 2>/dev/null || true
killall dnsmasq 2>/dev/null || true
sleep 1
wifi_write_dnsmasq_ap_conf /run/dnsmasq-ap.conf
dnsmasq -C /run/dnsmasq-ap.conf -x /run/dnsmasq-ap.pid

# Prefer lighttpd pid-file; stale wrapper pid is only a fallback.
if [ -f /run/lighttpd-wifi-setup.pid ]; then
	kill "$(cat /run/lighttpd-wifi-setup.pid)" 2>/dev/null || true
	rm -f /run/lighttpd-wifi-setup.pid
fi
if [ -f /run/wifi-setup-httpd.pid ]; then
	kill "$(cat /run/wifi-setup-httpd.pid)" 2>/dev/null || true
	rm -f /run/wifi-setup-httpd.pid
fi
# Daemonize (no -D): /dev/stderr is unavailable under systemd.
lighttpd -f /usr/share/wifi-setup/lighttpd.conf
cp -f /run/lighttpd-wifi-setup.pid /run/wifi-setup-httpd.pid 2>/dev/null || true

printf 'ap\n' > /run/wifi-mode
printf '%s\n' "$AP_IP" > /run/wifi-setup-ap-ip
printf '%s\n' "$(ap_ssid)" > /run/wifi-setup-ap-ssid
chmod 0644 /run/wifi-setup-ap-ip /run/wifi-setup-ap-ssid 2>/dev/null || true
log "setup AP ready: http://$AP_IP/ (SSID $(ap_ssid))"
