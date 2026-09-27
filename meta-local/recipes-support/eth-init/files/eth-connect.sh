#!/bin/sh
# =============================================================================
# eth-connect — bring up onboard Ethernet and get an IP
# =============================================================================
# Kernel may name the port eth0 or end0 (predictable naming). Prefer IFACE=
# from the environment, else the first non-wireless ethernet netdev.
set -eu

WAIT_IFACE_SEC="${WAIT_IFACE_SEC:-30}"
DHCP_METRIC="${DHCP_METRIC:-50}"

log() { printf 'eth: %s\n' "$*" >&2; }

is_wireless() {
	[ -d "/sys/class/net/$1/phy80211" ] || [ -d "/sys/class/net/$1/wireless" ]
}

find_eth() {
	if [ -n "${IFACE:-}" ] && [ -d "/sys/class/net/$IFACE" ]; then
		printf '%s\n' "$IFACE"
		return 0
	fi
	for cand in eth0 end0; do
		[ -d "/sys/class/net/$cand" ] || continue
		is_wireless "$cand" && continue
		printf '%s\n' "$cand"
		return 0
	done
	for path in /sys/class/net/*; do
		[ -e "$path" ] || continue
		iface=$(basename "$path")
		case "$iface" in
		lo|wlan*|wlu*|wlx*|docker*|veth*|br*|sit*|tun*|tap*) continue ;;
		esac
		is_wireless "$iface" && continue
		# wired: has device/type or just not wireless
		printf '%s\n' "$iface"
		return 0
	done
	return 1
}

i=0
while [ "$i" -lt "$WAIT_IFACE_SEC" ]; do
	if IFACE=$(find_eth); then
		export IFACE
		break
	fi
	i=$((i + 1))
	sleep 1
done
if [ -z "${IFACE:-}" ]; then
	log "no ethernet iface after ${WAIT_IFACE_SEC}s; skip"
	exit 0
fi

log "using $IFACE"
ip link set "$IFACE" up
ip -4 addr flush dev "$IFACE" 2>/dev/null || true

if [ -f "/run/udhcpc-${IFACE}.pid" ]; then
	kill "$(cat "/run/udhcpc-${IFACE}.pid")" 2>/dev/null || true
	rm -f "/run/udhcpc-${IFACE}.pid"
fi
pkill -f "udhcpc -i ${IFACE}" 2>/dev/null || true

# Wait briefly for carrier (cable / PHY link)
j=0
while [ "$j" -lt 20 ]; do
	car=$(cat /sys/class/net/"$IFACE"/carrier 2>/dev/null || echo 0)
	[ "$car" = "1" ] && break
	j=$((j + 1))
	sleep 1
done

if udhcpc -i "$IFACE" -n -b -p "/run/udhcpc-${IFACE}.pid" -t 10 -T 3; then
	gw=$(ip -4 route show default dev "$IFACE" 2>/dev/null \
		| sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -n1)
	if [ -n "$gw" ]; then
		ip route del default via "$gw" dev "$IFACE" 2>/dev/null || true
		ip route add default via "$gw" dev "$IFACE" metric "$DHCP_METRIC" 2>/dev/null || true
	fi
	log "DHCP ok on $IFACE metric=${DHCP_METRIC}"
else
	log "DHCP failed on $IFACE (carrier=$(cat /sys/class/net/$IFACE/carrier 2>/dev/null || echo ?))"
fi
exit 0
