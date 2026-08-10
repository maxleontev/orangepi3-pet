#!/bin/sh
# Shared helpers for /data/wifi.conf (STA networks + setup AP address).
# Sourced by wifi-connect, wifi-ap-start, wifi-write-config.

CONF="${CONF:-/data/wifi.conf}"
DEFAULT_AP_IP="192.168.4.1"
DEFAULT_AP_PREFIX="24"
DEFAULT_COUNTRY="RU"

wifi_conf_get() {
	# wifi_conf_get KEY → value of "# KEY=..." line in $CONF
	key=$1
	[ -f "$CONF" ] || return 0
	sed -n "s/^#[[:space:]]*${key}=//p" "$CONF" | sed -n '1p'
}

wifi_conf_ensure_setup_defaults() {
	mkdir -p /data
	if [ ! -f "$CONF" ]; then
		cat > "$CONF" <<EOF
# setup_ap_ip=$DEFAULT_AP_IP
# setup_ap_prefix=$DEFAULT_AP_PREFIX

ctrl_interface=DIR=/var/run/wpa_supplicant
update_config=1
ap_scan=1
country=$DEFAULT_COUNTRY
bgscan="simple:30:-70:300"
EOF
		chmod 0600 "$CONF"
		return 0
	fi
	tmp=$CONF.setup_defaults.new
	: > "$tmp"
	need_ip=1
	need_pfx=1
	grep -q '^#[[:space:]]*setup_ap_ip=' "$CONF" 2>/dev/null && need_ip=0
	grep -q '^#[[:space:]]*setup_ap_prefix=' "$CONF" 2>/dev/null && need_pfx=0
	if [ "$need_ip" -eq 1 ]; then
		printf '# setup_ap_ip=%s\n' "$DEFAULT_AP_IP" >> "$tmp"
	fi
	if [ "$need_pfx" -eq 1 ]; then
		printf '# setup_ap_prefix=%s\n' "$DEFAULT_AP_PREFIX" >> "$tmp"
	fi
	if [ "$need_ip" -eq 1 ] || [ "$need_pfx" -eq 1 ]; then
		cat "$CONF" >> "$tmp"
		chmod 0600 "$tmp"
		mv -f "$tmp" "$CONF"
	else
		rm -f "$tmp"
	fi
}

wifi_load_setup_ap() {
	# Sets AP_IP and AP_PREFIX (env overrides win).
	wifi_conf_ensure_setup_defaults
	if [ -z "${AP_IP:-}" ]; then
		AP_IP=$(wifi_conf_get setup_ap_ip)
	fi
	if [ -z "${AP_PREFIX:-}" ]; then
		AP_PREFIX=$(wifi_conf_get setup_ap_prefix)
	fi
	AP_IP="${AP_IP:-$DEFAULT_AP_IP}"
	AP_PREFIX="${AP_PREFIX:-$DEFAULT_AP_PREFIX}"
	# Basic sanity: IPv4 dotted quad
	case "$AP_IP" in
		*.*.*.*) ;;
		*) AP_IP=$DEFAULT_AP_IP ;;
	esac
	case "$AP_PREFIX" in
		*[!0-9]*|"") AP_PREFIX=$DEFAULT_AP_PREFIX ;;
	esac
}

wifi_ipv4_octet() {
	# wifi_ipv4_octet A.B.C.D N → Nth octet (1..4)
	echo "$1" | cut -d. -f"$2"
}

wifi_write_dnsmasq_ap_conf() {
	# Requires AP_IP, AP_PREFIX, IFACE. Writes /run/dnsmasq-ap.conf
	out="${1:-/run/dnsmasq-ap.conf}"
	o1=$(wifi_ipv4_octet "$AP_IP" 1)
	o2=$(wifi_ipv4_octet "$AP_IP" 2)
	o3=$(wifi_ipv4_octet "$AP_IP" 3)
	o4=$(wifi_ipv4_octet "$AP_IP" 4)
	# /24 pool .10–.100; skip AP address if it lands in the pool.
	start=10
	end=100
	if [ "$AP_PREFIX" = "24" ]; then
		base="$o1.$o2.$o3"
		mask=255.255.255.0
	else
		# Non-/24: still use same last-octet pool on the AP's /24-like base.
		base="$o1.$o2.$o3"
		mask=255.255.255.0
	fi
	range_start="$base.$start"
	range_end="$base.$end"
	if [ "$o4" -ge "$start" ] 2>/dev/null && [ "$o4" -le "$end" ] 2>/dev/null; then
		# Keep gateway outside the pool when possible.
		range_start="$base.101"
		range_end="$base.200"
	fi
	cat > "$out" <<EOF
interface=$IFACE
bind-interfaces
except-interface=lo
no-dhcp-interface=lo
dhcp-range=$range_start,$range_end,$mask,12h
dhcp-option=3,$AP_IP
dhcp-option=6,$AP_IP
address=/#/$AP_IP
pid-file=/run/dnsmasq-ap.pid
log-facility=-
EOF
	chmod 0644 "$out"
}
