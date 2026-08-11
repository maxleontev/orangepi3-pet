#!/bin/sh
# Tear down WiFi (STA or setup AP) on wifi.service stop.
set -eu

IFACE="${IFACE:-wlan0}"

log() { printf 'wifi-ap-stop: %s\n' "$*" >&2; }

killall udhcpc wpa_supplicant 2>/dev/null || true
if [ -f "/run/wpa_supplicant-${IFACE}.pid" ]; then
	pid=$(cat "/run/wpa_supplicant-${IFACE}.pid")
	kill "$pid" 2>/dev/null || true
	rm -f "/run/wpa_supplicant-${IFACE}.pid"
fi

if [ -f /run/wifi-setup-httpd.pid ]; then
	pid=$(cat /run/wifi-setup-httpd.pid)
	kill "$pid" 2>/dev/null || true
	rm -f /run/wifi-setup-httpd.pid
fi
killall lighttpd 2>/dev/null || true

if [ -f /run/dnsmasq-ap.pid ]; then
	pid=$(cat /run/dnsmasq-ap.pid)
	kill "$pid" 2>/dev/null || true
	rm -f /run/dnsmasq-ap.pid
fi
killall dnsmasq 2>/dev/null || true
rm -f /run/dnsmasq-ap.pid 2>/dev/null || true

if [ -f /run/hostapd-ap.pid ]; then
	pid=$(cat /run/hostapd-ap.pid)
	kill "$pid" 2>/dev/null || true
	rm -f /run/hostapd-ap.pid
fi
killall hostapd 2>/dev/null || true
rm -f /run/hostapd-ap.conf 2>/dev/null || true

# Flush AP address but keep the link up. Bringing brcmfmac down right after
# hostapd exit often makes wlan0 disappear until a module reload.
if [ -d "/sys/class/net/$IFACE" ]; then
	ip -4 addr flush dev "$IFACE" 2>/dev/null || true
fi
rm -f /run/wifi-mode /run/wifi-setup-ap-ip /run/wifi-setup-ap-ssid /run/dnsmasq-ap.conf
log "setup AP stopped"
