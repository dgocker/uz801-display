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
#
# pm8916-bms-vm implements STATUS, VOLTAGE_NOW, VOLTAGE_OCV and HEALTH - and
# no CAPACITY at all, so there is no percentage to read from anywhere. It has
# to be derived here, from the cell's discharge curve.
#
# The curve below is the vendor's own pc-temp-ocv-lut at 25 C, lifted from the
# stock Android device tree of this board (pairs of millivolts and percent,
# descending). A linear volts-to-percent map is not an approximation of it:
# the curve is flat through the middle and steep at both ends, so linear reads
# far too high at rest and leaps by tens of points the moment charging starts.
BATTERY=-1
CHARGING=""
BMS=/sys/class/power_supply/pm8916-bms-vm
CHG=/sys/class/power_supply/pm8916-lbc-chgr
STATE=/tmp/router-display.battery
OCV="4189 100 4073 95 4044 90 4039 85 4032 80 4025 75 4008 70 3974 65 3953 60 3912 55 3884 50 3858 45 3849 40 3839 35 3816 30 3774 25 3690 20 3647 16 3611 13 3571 11 3556 10 3542 9 3529 8 3507 7 3480 6 3439 5 3402 4 3398 3 3367 2 3336 1 3300 0"

# Charging is reported by the charger, not by the gauge: the gauge derives its
# status from power_supply_am_i_supplied() and answers Discharging unless the
# battery node is linked to the charger.
[ "$(cat "$CHG/online" 2>/dev/null)" = "1" ] && CHARGING="-c"

V=$(cat "$BMS/voltage_now" 2>/dev/null)

# With no pack fitted the gauge measures the supply rail the charger drives,
# not a cell, and reports about 4.35 V - above the 4.20 V the charger
# regulates to, which is impossible for a battery it is charging. Treat that
# as "no battery" and show nothing, rather than the confident 99 percent it
# used to read while running on USB alone.
[ -n "$V" ] && [ "$V" -gt 4250000 ] 2>/dev/null && V=""

if [ -n "$V" ]; then
    # With current flowing in, terminal voltage sits above the open circuit
    # voltage the curve is indexed by, by roughly I times the cell's internal
    # resistance. The stock device tree puts that at 180 mOhm
    # (qcom,default-rbatt-mohm = <0xB4>) and the charger is set to 1 A, so
    # 180 mV. Without this the reading leaps some twenty points the instant a
    # charger is plugged in.
    [ -n "$CHARGING" ] && V=$((V - 180000))

    BATTERY=$(awk -v v="$V" -v tbl="$OCV" 'BEGIN{
        n = split(tbl, a, " ");
        mv = v / 1000;
        if (mv >= a[1]) { print 100; exit }
        for (i = 1; i + 3 <= n; i += 2) {
            v1 = a[i]; p1 = a[i+1]; v2 = a[i+2]; p2 = a[i+3];
            if (mv <= v1 && mv >= v2) {
                printf "%.0f", p2 + (mv - v2) * (p1 - p2) / (v1 - v2);
                exit
            }
        }
        print 0
    }')

    # A voltage mode gauge cannot be trusted minute to minute: terminal
    # voltage jumps the moment current starts or stops flowing, and surface
    # charge keeps it high for a while afterwards. Rate limit the displayed
    # value to what the cell can physically do - 3000 mAh at the 1 A this
    # charger delivers is about 1.7 percent per minute - so the reading walks
    # to the truth instead of leaping past it.
    NOW=$(cut -d. -f1 /proc/uptime)
    PREV=$(cut -d' ' -f1 "$STATE" 2>/dev/null)
    PREV_T=$(cut -d' ' -f2 "$STATE" 2>/dev/null)
    if [ -n "$PREV" ] && [ -n "$PREV_T" ] && [ "$BATTERY" -ge 0 ] 2>/dev/null; then
        DT=$((NOW - PREV_T))
        [ "$DT" -lt 0 ] && DT=0
        if [ -n "$CHARGING" ]; then
            LIMIT=$(( (DT * 2 / 60) + 1 ))     # ~2 %/min going up
        else
            LIMIT=$(( (DT * 6 / 60) + 1 ))     # discharge can be quicker
        fi
        D=$((BATTERY - PREV))
        [ "$D" -gt "$LIMIT" ]  && BATTERY=$((PREV + LIMIT))
        [ "$D" -lt -"$LIMIT" ] && BATTERY=$((PREV - LIMIT))
    fi
    [ "$BATTERY" -ge 0 ] 2>/dev/null && echo "$BATTERY $NOW" > "$STATE"
fi
[ -z "$BATTERY" ] && BATTERY=-1

# ---------------------------------------------------------------- render
"$RENDER" \
    -n "$OPERATOR" -t "$NETWORK" -q "$SIGNAL" -r "$RSSI" \
    -s "$SSID" -i "$IP" -C "$CLIENTS" \
    -b "$BATTERY" $CHARGING \
    -u "$UP_KBPS" -d "$DOWN_KBPS" \
    > "$FB"
