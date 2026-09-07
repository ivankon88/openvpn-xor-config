#!/bin/sh
#VERSION=2.2
# OpenVPN + XOR Router Bot
# =====================================================

VPS="http://132.243.65.204:8080"

VPN_CONF="/etc/openvpn/xor/client.conf"
VPN_IF="tun-xor"
AUTH_FILE="/etc/openvpn/xor/auth.txt"

# VPN логин автоматически читаем из auth.txt
VPN_LOGIN=$(head -n1 "$AUTH_FILE" 2>/dev/null | tr -d '\r')

ROUTER="$VPN_LOGIN"

# Если auth.txt отсутствует или логин пустой — ничего не отправляем.
[ -z "$ROUTER" ] && exit

# =====================================================
# SYSTEM
# =====================================================

OPENWRT=$(grep DISTRIB_RELEASE /etc/openwrt_release 2>/dev/null | cut -d"'" -f2)

# =====================================================
# VPN STATUS
# =====================================================

VPN_IP=$(ip -4 addr show "$VPN_IF" 2>/dev/null | awk '/inet /{print $2; exit}')
[ -z "$VPN_IP" ] && VPN_IP="none"

VPN_NET="DOWN"

if ip link show "$VPN_IF" >/dev/null 2>&1; then
    if ip -4 addr show "$VPN_IF" | grep -q "inet "; then
        VPN_NET="OK"
    fi
fi

# =====================================================
# VPN SERVER (remote IP:PORT from client.conf)
# =====================================================

VPN_SERVER=$(awk '/^remote /{print $2; exit}' "$VPN_CONF" 2>/dev/null)
VPN_PORT=$(awk '/^remote /{print $3; exit}' "$VPN_CONF" 2>/dev/null)

[ -z "$VPN_SERVER" ] && VPN_SERVER="unknown"
[ -z "$VPN_PORT" ] && VPN_PORT="-"

# =====================================================
# ROUTER INFO
# =====================================================

UPTIME=$(uptime | sed 's/.*up //' | cut -d',' -f1)

WIFI=$(iw dev 2>/dev/null | awk '
/Interface/ {iface=$2}
/type AP/ {print iface}' | while read i; do
    iw dev "$i" station dump 2>/dev/null | grep -c Station
done | awk '{s+=$1} END {print s}')

[ -z "$WIFI" ] && WIFI="0"

FLASH=$(df -h /overlay 2>/dev/null | awk 'END{print $4}')
[ -z "$FLASH" ] && FLASH="?"

# =====================================================
# FILE VERSIONS
# =====================================================

VPN_VER=$(grep -m1 VERSION "$VPN_CONF" 2>/dev/null | cut -d= -f2)
SCRIPT_VER=$(grep -m1 VERSION /root/router_sync.sh 2>/dev/null | cut -d= -f2)
BYPASS_VER=$(grep -m1 VERSION /root/vpn-bypass.list 2>/dev/null | cut -d= -f2)

[ -z "$VPN_VER" ] && VPN_VER="0"
[ -z "$SCRIPT_VER" ] && SCRIPT_VER="0"
[ -z "$BYPASS_VER" ] && BYPASS_VER="0"

# =====================================================
# WAN TRAFFIC
# =====================================================

WAN=$(ip route show default | awk 'NR==1{print $5}')

RX=0
TX=0

if [ -n "$WAN" ]; then
    RX=$(awk -v dev="$WAN:" '$1==dev {print int($2/1024/1024)}' /proc/net/dev)
    TX=$(awk -v dev="$WAN:" '$1==dev {print int($10/1024/1024)}' /proc/net/dev)
fi

[ -z "$RX" ] && RX=0
[ -z "$TX" ] && TX=0

# =====================================================
# SEND REPORT TO BOT
# =====================================================

JSON=$(printf '{"router":"%s","vpn_login":"%s","openwrt":"%s","vpn_ip":"%s","vpn_server":"%s:%s","vpn_net":"%s","uptime":"%s","wifi":"%s","flash":"%s","rx":"%s MB","tx":"%s MB","vpn_ver":"%s","script_ver":"%s","bypass_ver":"%s"}' \
"$ROUTER" \
"$VPN_LOGIN" \
"$OPENWRT" \
"$VPN_IP" \
"$VPN_SERVER" \
"$VPN_PORT" \
"$VPN_NET" \
"$UPTIME" \
"$WIFI" \
"$FLASH" \
"$RX" \
"$TX" \
"$VPN_VER" \
"$SCRIPT_VER" \
"$BYPASS_VER")

curl -m 5 -s -X POST "$VPS/report" \
-H "Content-Type: application/json" \
-d "$JSON" >/dev/null

# =====================================================
# GET COMMAND FROM BOT
# =====================================================

CMD=$(curl -m 5 -s "$VPS/check?router=$ROUTER")

ID=$(echo "$CMD" | jsonfilter -e '@.id' 2>/dev/null)
COMMAND=$(echo "$CMD" | jsonfilter -e '@.cmd' 2>/dev/null)

# =====================================================
# UPDATE OPENVPN CONFIG
# =====================================================

if [ "$COMMAND" = "vpn" ]; then

    echo "Updating OpenVPN XOR..."

    mkdir -p /etc/openvpn/xor

    wget -q -O /tmp/client.conf "$VPS/configs/client.conf"

    if [ -s /tmp/client.conf ]; then

        cp /tmp/client.conf "$VPN_CONF"
        chmod 600 "$VPN_CONF"

        /etc/init.d/openvpn restart

        sleep 3

        curl -m 5 -s -X POST "$VPS/done" \
        -H "Content-Type: application/json" \
        -d "{\"id\":$ID}" >/dev/null

        echo "OpenVPN updated."

    else

        echo "ERROR: client.conf download failed."

    fi

fi

# =====================================================
# UPDATE ROUTER_SYNC.SH
# =====================================================

if [ "$COMMAND" = "script" ]; then

    echo "Updating router_sync.sh..."

    wget -q -O /tmp/router_sync.sh "$VPS/configs/router_sync.sh"

    if [ -s /tmp/router_sync.sh ] && grep -q "^#!/bin/sh" /tmp/router_sync.sh; then

        cp /tmp/router_sync.sh /root/router_sync.sh
        chmod +x /root/router_sync.sh

        curl -m 5 -s -X POST "$VPS/done" \
        -H "Content-Type: application/json" \
        -d "{\"id\":$ID}" >/dev/null

        echo "router_sync.sh updated."

    else

        echo "ERROR: router_sync.sh download failed."

    fi

fi

# =====================================================
# UPDATE VPN BYPASS LIST
# =====================================================

if [ "$COMMAND" = "bypass" ]; then

    echo "Updating vpn-bypass.list..."

    wget -q -O /tmp/vpn-bypass.list "$VPS/configs/vpn-bypass.list"

    if [ -s /tmp/vpn-bypass.list ]; then

        cp /tmp/vpn-bypass.list /root/vpn-bypass.list
        chmod 644 /root/vpn-bypass.list

        curl -m 5 -s -X POST "$VPS/done" \
        -H "Content-Type: application/json" \
        -d "{\"id\":$ID}" >/dev/null

        echo "vpn-bypass.list updated."

    else

        echo "ERROR: vpn-bypass.list download failed."

    fi

fi

# =====================================================
# REBOOT ROUTER
# =====================================================

if [ "$COMMAND" = "reboot" ]; then

    curl -m 5 -s -X POST "$VPS/done" \
    -H "Content-Type: application/json" \
    -d "{\"id\":$ID}" >/dev/null

    echo "Rebooting router..."

    reboot

fi
