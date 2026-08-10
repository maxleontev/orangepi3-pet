#!/bin/sh
# Write /data/wifi.conf from "ssid:psk" pairs (colon-separated).
# Preserves setup_ap_ip / setup_ap_prefix and country from the existing file.
# Usage: wifi-write-config 'SSID:PSK' ['SSID:PSK' ...]
set -eu

CONF="${CONF:-/data/wifi.conf}"

. /usr/share/wifi-setup/wifi-conf-lib.sh

log() { printf 'wifi-write-config: %s\n' "$*" >&2; }

write_conf() {
	mkdir -p /data
	wifi_conf_ensure_setup_defaults

	setup_ip=$(wifi_conf_get setup_ap_ip)
	setup_pfx=$(wifi_conf_get setup_ap_prefix)
	setup_ip="${setup_ip:-$DEFAULT_AP_IP}"
	setup_pfx="${setup_pfx:-$DEFAULT_AP_PREFIX}"

	country=${COUNTRY:-}
	if [ -z "$country" ] && [ -f "$CONF" ]; then
		country=$(sed -n 's/^country=//p' "$CONF" | sed -n '1p')
	fi
	country="${country:-$DEFAULT_COUNTRY}"

	{
		cat <<EOF
# Managed by wifi-setup web UI or wifi-write-config.
# Edit on device: systemctl restart wifi.service
# setup_ap_ip=$setup_ip
# setup_ap_prefix=$setup_pfx

ctrl_interface=DIR=/var/run/wpa_supplicant
update_config=1
ap_scan=1
country=$country
bgscan="simple:30:-70:300"

EOF
		priority=10
		for entry in "$@"; do
			[ -n "$entry" ] || continue
			ssid=${entry%%:*}
			psk=${entry#*:}
			[ -n "$ssid" ] || continue
			[ "$psk" != "$entry" ] || psk=""
			cat <<EOF
network={
	ssid="$ssid"
EOF
			if [ -n "$psk" ]; then
				printf '\tpsk="%s"\n' "$psk"
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
	priority=$priority
}

EOF
			priority=$((priority + 10))
		done
	} > "$CONF.new"
	chmod 0600 "$CONF.new"
	mv -f "$CONF.new" "$CONF"
	log "wrote $CONF ($# network(s), setup_ap_ip=$setup_ip)"
}

if [ "$#" -eq 0 ]; then
	log "usage: wifi-write-config 'SSID:PSK' ..."
	exit 1
fi

write_conf "$@"
