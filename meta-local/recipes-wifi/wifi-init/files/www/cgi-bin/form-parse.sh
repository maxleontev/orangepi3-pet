#!/bin/sh
# Parse application/x-www-form-urlencoded POST body into shell variables.
# Sets FORM_* variables and network_count when present.
set -eu

read_post() {
	POST_DATA=""
	if [ -n "${CONTENT_LENGTH:-}" ] && [ "$CONTENT_LENGTH" -gt 0 ]; then
		POST_DATA=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
	fi
}

urldecode() {
	# shellcheck disable=SC1003
	printf '%b' "$(echo "$1" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
}

parse_field() {
	key=$1
	value=$2
	case "$key" in
		network_count) network_count=$value ;;
		ssid)
			eval "ssid=\$(urldecode \"$value\")"
			;;
		psk)
			eval "psk=\$(urldecode \"$value\")"
			;;
		ssid_*)
			id=${key#ssid_}
			eval "ssid_$id=\$(urldecode \"$value\")"
			;;
		psk_*)
			id=${key#psk_}
			eval "psk_$id=\$(urldecode \"$value\")"
			;;
	esac
}

parse_post() {
	network_count=0
	# shellcheck disable=SC2153
	old_ifs=$IFS
	IFS='&'
	for pair in $POST_DATA; do
		key=${pair%%=*}
		value=${pair#*=}
		[ "$value" != "$pair" ] || value=""
		parse_field "$key" "$value"
	done
	IFS=$old_ifs
}
