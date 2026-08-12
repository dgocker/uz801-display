#!/bin/sh

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_zhiheqmi_init_config() {
	available=1
	no_device=1
	# Plain string, not "device:device": the latter makes netifd (and
	# LuCI) resolve it to a network interface name, so the QMI character
	# device path silently turns into "wwan0" and nothing can talk to the modem.
	proto_config_add_string device
	proto_config_add_string "apn"
	proto_config_add_string "profile"
}

proto_zhiheqmi_setup() {
	local config="$1"
	local iface="$2"
	local device apn profile
	json_get_vars device apn profile

	# Guard against a stale or resolved-away value
	case "$device" in
		/dev/*) ;;
		*) device="/dev/wwan0qmi0" ;;
	esac
	[ -c "$device" ] || device="/dev/wwan0qmi0"
	[ -z "$apn" ] && apn="internet"
	[ -z "$profile" ] && profile="3"
	[ -z "$iface" ] && iface="wwan0"

	logger -t zhihe-qmi "Starting connection on $iface ($device) with APN: $apn, Profile: $profile"
	ip link set "$iface" up 2>/dev/null || true
	qmicli -d "$device" --device-open-proxy --dms-set-operating-mode=online >/dev/null 2>&1
	logger -t zhihe-qmi "Waiting for network registration..."
	local registered=0
	for i in $(seq 1 60); do
		STATUS=$(qmicli -d "$device" --device-open-proxy --nas-get-serving-system 2>/dev/null)
		if echo "$STATUS" | grep -q "Registration state: 'registered'"; then
			registered=1
			break
		fi
		sleep 1
	done

	if [ "$registered" -eq 0 ]; then
		logger -t zhihe-qmi "Error: Network registration timeout!"
		proto_notify_error "$config" "REGISTRATION_FAILED"
		proto_setup_failed "$config"
		return 1
	fi

	logger -t zhihe-qmi "Registered to network! Starting data session..."

	qmicli -d "$device" --device-open-net='net-raw-ip|net-no-qos-header' \
		--wds-start-network="3gpp-profile=$profile" \
		--device-open-proxy --wds-follow-network > /dev/null 2>&1 &

	local qmipid=$!
	echo "$qmipid" > "/var/run/zhiheqmi_${config}.pid"
	sleep 5

	local SETTINGS=$(qmicli -d "$device" --device-open-proxy --wds-get-current-settings 2>/dev/null)

	local IP=$(echo "$SETTINGS" | grep -oE "IPv4 address: [0-9.]+" | awk '{print $3}')
	local GW=$(echo "$SETTINGS" | grep -oE "IPv4 gateway address: [0-9.]+" | awk '{print $4}')
	local MASK=$(echo "$SETTINGS" | grep -oE "IPv4 subnet mask: [0-9.]+" | awk '{print $4}')
	local DNS1=$(echo "$SETTINGS" | grep -oE "IPv4 primary DNS: [0-9.]+" | awk '{print $4}')
	local DNS2=$(echo "$SETTINGS" | grep -oE "IPv4 secondary DNS: [0-9.]+" | awk '{print $4}')
	local MTU=$(echo "$SETTINGS" | grep -oE "MTU: [0-9]+" | awk '{print $2}')

	if [ -z "$IP" ] || [ -z "$MASK" ]; then
		logger -t zhihe-qmi "Error: Failed to get IP settings from modem!"
		kill -9 "$qmipid" 2>/dev/null
		proto_notify_error "$config" "IP_FETCH_FAILED"
		proto_setup_failed "$config"
		return 1
	fi

	# Derive the prefix length from any netmask - the original hardcoded list
	# of three masks fell through to /32 for everything else (e.g. the /28 this
	# operator hands out), which leaves the gateway unreachable.
	local CIDR=0 octet
	for octet in $(echo "$MASK" | tr '.' ' '); do
		while [ "$octet" -gt 0 ]; do
			CIDR=$((CIDR + (octet & 1)))
			octet=$((octet >> 1))
		done
	done
	[ "$CIDR" -ge 1 ] 2>/dev/null || CIDR=32

	logger -t zhihe-qmi "Success! IP: $IP/$CIDR, GW: $GW, MTU: $MTU, DNS: $DNS1, $DNS2"

	proto_init_update "$iface" 1
	proto_add_ipv4_address "$IP" "$CIDR" "" "$GW"
	[ -n "$GW" ] && proto_add_ipv4_route "0.0.0.0" 0 "$GW"
	[ -n "$DNS1" ] && proto_add_dns_server "$DNS1"
	[ -n "$DNS2" ] && proto_add_dns_server "$DNS2"
	[ -n "$MTU" ] && json_add_int mtu "$MTU"
	proto_send_update "$config"

	(
		local misses=0
		while sleep 20; do
			[ -f "/var/run/zhiheqmi_${config}.pid" ] || break
				if qmicli -d "$device" --device-open-proxy --wds-get-packet-service-status 2>/dev/null | grep -q "'disconnected'"; then
					misses=$((misses + 1))
				else
					misses=0
				fi
				if [ $misses -ge 2 ]; then
					logger -t zhihe-qmi "Watchdog: Modem reported disconnected! Forcing interface restart..."
					sh -c "ifdown '$config'; sleep 3; ifup '$config'" &
					break
				fi
		done
	) &
	echo "$!" > "/var/run/zhiheqmi_${config}_wd.pid"
}

proto_zhiheqmi_teardown() {
	local config="$1"
	local iface="$2"

	[ -z "$iface" ] && iface="wwan0"

	logger -t zhihe-qmi "Tearing down connection on $iface..."

	local wdpid=$(cat "/var/run/zhiheqmi_${config}_wd.pid" 2>/dev/null)
	if [ -n "$wdpid" ]; then
		kill -9 "$wdpid" 2>/dev/null
		rm -f "/var/run/zhiheqmi_${config}_wd.pid"
	fi

	local qmipid=$(cat "/var/run/zhiheqmi_${config}.pid" 2>/dev/null)
	if [ -n "$qmipid" ]; then
		kill -9 "$qmipid" 2>/dev/null
		rm -f "/var/run/zhiheqmi_${config}.pid"
	fi

	ip link set "$iface" down 2>/dev/null || true
}

[ -n "$INCLUDE_ONLY" ] || add_protocol zhiheqmi