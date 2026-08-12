#!/bin/sh
# /usr/bin/update-display
#
# Collects status and hands it to the renderer.
#   update-display        -> status dashboard
#   update-display qr     -> Wi-Fi QR screen
#
# The operator name is cached: it cannot change without a reboot (SIM swap).

RENDER=/usr/bin/router-display
FB=/dev/fb0

[ -x "$RENDER" ] || exit 1
[ -c "$FB" ] || exit 1

# ----------------------------------------------------------------- Wi-Fi
SSID=$(uci -q get wireless.@wifi-iface[0].ssid || echo "")
PASSWORD=$(uci -q get wireless.@wifi-iface[0].key || echo "")

# QR screen: nothing else to gather
if [ "$1" = "qr" ]; then
    "$RENDER" -Q -s "$SSID" -p "$PASSWORD" > "$FB"
    exit 0
fi

# ----------------------------------------------------------------- modem
# Queried through qmicli, not ModemManager: MM wedges this modem into a
# permanent "offline" operating mode (postmarketOS documents the same).
# --device-open-proxy is required - direct access fails to take the modem
# online at all.
QMI_DEV=/dev/wwan0qmi0
QMI="qmicli -d $QMI_DEV --device-open-proxy"

OPERATOR=""
NETWORK=""
SIGNAL=-1
RSSI=0

if [ -c "$QMI_DEV" ]; then
    SERVING=$($QMI --nas-get-serving-system 2>/dev/null)

    # Prefer the name the network broadcasts over the one burned into the SIM:
    # the two often differ, and the network one reflects where the subscriber
    # actually is right now (roaming included).
    OPERATOR=$(echo "$SERVING" | awk -F"'" '/Description:/ {print $2; exit}')
    [ -z "$OPERATOR" ] && OPERATOR=$($QMI --nas-get-operator-name 2>/dev/null |
               sed -n "s/.*Name  *: '\(.*\)'.*/\1/p" | head -1)
    case "$SERVING" in
        *"'lte'"*)              NETWORK="4G" ;;
        *umts*|*hsdpa*|*hspa*)  NETWORK="3G" ;;
        *gsm*|*gprs*|*edge*)    NETWORK="2G" ;;
    esac
    echo "$SERVING" | grep -q "Registration state: 'registered'" || NETWORK=""

    RSSI=$($QMI --nas-get-signal-strength 2>/dev/null |
           grep -A1 '^RSSI:' | grep -oE '\-[0-9]+' | head -1)
    [ -z "$RSSI" ] && RSSI=0

    # map RSSI to a 0..100 bar: -113 dBm and worse = empty, -51 and better = full
    if [ "$RSSI" -lt 0 ] 2>/dev/null; then
        SIGNAL=$(( (RSSI + 113) * 100 / 62 ))
        [ "$SIGNAL" -lt 0 ] && SIGNAL=0
        [ "$SIGNAL" -gt 100 ] && SIGNAL=100
    fi
fi

# ------------------------------------------------------------------- LAN
IP=$(uci -q get network.lan.ipaddr)
[ -z "$IP" ] && IP=$(ip -4 addr show br-lan 2>/dev/null |
                     grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1)

# associated Wi-Fi stations
CLIENTS=0
for IFACE in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
    N=$(iw dev "$IFACE" station dump 2>/dev/null | grep -c '^Station')
    CLIENTS=$((CLIENTS + N))
done

# --------------------------------------------------------------- traffic
# The QMI raw-ip WAN interface does not maintain byte counters on this kernel
# (upstream needs a patch for that), so when they read as zero we measure the
# LAN side instead and swap the directions: what clients send is what goes up.
WAN_IF=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
[ -z "$WAN_IF" ] && WAN_IF=wwan0

COUNT_IF="$WAN_IF"
SWAP=0
if [ "$(cat /sys/class/net/$WAN_IF/statistics/rx_bytes 2>/dev/null || echo 0)" = "0" ] &&
   [ "$(cat /sys/class/net/$WAN_IF/statistics/tx_bytes 2>/dev/null || echo 0)" = "0" ]; then
    COUNT_IF=br-lan
    SWAP=1
fi

UP_KBPS=0
DOWN_KBPS=0
STATE=/tmp/.display_traffic

if [ -e "/sys/class/net/$COUNT_IF/statistics/rx_bytes" ]; then
    RX=$(cat "/sys/class/net/$COUNT_IF/statistics/rx_bytes")
    TX=$(cat "/sys/class/net/$COUNT_IF/statistics/tx_bytes")
    NOW=$(awk '{print int($1)}' /proc/uptime)

    if [ -s "$STATE" ]; then
        read -r P_RX P_TX P_NOW P_IF < "$STATE"
        DT=$((NOW - P_NOW))
        if [ "$P_IF" = "$COUNT_IF" ] && [ "$DT" -gt 0 ] &&
           [ "$RX" -ge "$P_RX" ] && [ "$TX" -ge "$P_TX" ]; then
            A=$(( (RX - P_RX) * 8 / DT / 1000 ))
            B=$(( (TX - P_TX) * 8 / DT / 1000 ))
            if [ "$SWAP" = "1" ]; then
                UP_KBPS=$A; DOWN_KBPS=$B
            else
                DOWN_KBPS=$A; UP_KBPS=$B
            fi
        fi
    fi
    echo "$RX $TX $NOW $COUNT_IF" > "$STATE"
fi

# --------------------------------------------------------------- battery
BATTERY=-1
CHARGING=""
BMS=/sys/class/power_supply/pm8916-bms-vm

if [ -d "$BMS" ]; then
    if [ -r "$BMS/capacity" ]; then
        BATTERY=$(cat "$BMS/capacity" 2>/dev/null)
    else
        V=$(cat "$BMS/voltage_now" 2>/dev/null)
        VMAX=$(cat "$BMS/voltage_max_design" 2>/dev/null)
        VMIN=$(cat "$BMS/voltage_min_design" 2>/dev/null)
        if [ -n "$V" ] && [ -n "$VMAX" ] && [ -n "$VMIN" ] && [ "$VMAX" != "$VMIN" ]; then
            BATTERY=$(awk "BEGIN{p=(($V-$VMIN)/($VMAX-$VMIN))*100;
                                 if(p<0)p=0; if(p>100)p=100; printf \"%.0f\", p}")
        fi
    fi
    [ "$(cat "$BMS/status" 2>/dev/null)" = "Charging" ] && CHARGING="-c"
fi
[ -z "$BATTERY" ] && BATTERY=-1

# ---------------------------------------------------------------- render
"$RENDER" \
    -n "$OPERATOR" -t "$NETWORK" -q "$SIGNAL" -r "$RSSI" \
    -s "$SSID" -i "$IP" -C "$CLIENTS" \
    -b "$BATTERY" $CHARGING \
    -u "$UP_KBPS" -d "$DOWN_KBPS" \
    > "$FB"
