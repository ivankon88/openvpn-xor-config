#!/bin/sh
#VERSION=2.0
# ==========================================================
# OpenVPN XOR Watchdog
# ==========================================================

LOG="/tmp/vpn_watchdog.log"

VPN_CONFIG="/etc/openvpn/xor/client.conf"
BYPASS_FILE="/root/vpn-bypass.list"

BACKUP_DIR="/root/vpn_backup"


TMP_CLIENT="/tmp/client_new.conf"
TMP_BYPASS="/tmp/vpn-bypass_new.list"
# GitHub repository
GITHUB_USER="ivankon88"
GITHUB_REPO="openvpn-xor-config"
GITHUB_BRANCH="main"

# Main source (GitHub Raw)
GITHUB_RAW="https://raw.githubusercontent.com/$GITHUB_USER/$GITHUB_REPO/$GITHUB_BRANCH"

# Backup source (jsDelivr CDN)
GITHUB_CDN="https://cdn.jsdelivr.net/gh/$GITHUB_USER/$GITHUB_REPO@$GITHUB_BRANCH"

# Files
CLIENT_FILE="client.conf"
BYPASS_FILE_REMOTE="vpn-bypass.list"
WATCHDOG_FILE="watchdog.sh"
ROUTER_SYNC_FILE="router_sync.sh"

# Temporary files
TMP_CLIENT="/tmp/client_new.conf"
TMP_BYPASS="/tmp/vpn-bypass_new.list"
TMP_WATCHDOG="/tmp/watchdog_new.sh"
TMP_ROUTER_SYNC="/tmp/router_sync_new.sh"


VPN_INTERFACE="tun-xor"
VPN_GATEWAY="10.10.0.1"

WAN_INTERFACE="eth0.2"

PROVIDER_DNS1="217.174.227.102"
PROVIDER_DNS2="217.174.237.105"

RESOLV_BACKUP="/tmp/resolv.conf.watchdog.backup"
LOCK_FILE="/tmp/vpn_watchdog.lock"

# ==========================================================
# LOG
# ==========================================================

# ==========================================================
# SINGLE INSTANCE LOCK
# ==========================================================

if [ -f "$LOCK_FILE" ]; then
    PID="$(cat "$LOCK_FILE" 2>/dev/null)"

    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        exit 0
    fi

    rm -f "$LOCK_FILE"
fi

echo "$$" > "$LOCK_FILE"

trap 'rm -f "$LOCK_FILE"' EXIT

log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"

    # Защита от переполнения /tmp
    if [ -f "$LOG" ]; then
        SIZE="$(wc -c < "$LOG" 2>/dev/null)"

        if [ -n "$SIZE" ] && [ "$SIZE" -gt 32768 ]; then
            tail -200 "$LOG" > "${LOG}.tmp" 2>/dev/null
            mv "${LOG}.tmp" "$LOG" 2>/dev/null
        fi
    fi
}

# ==========================================================
# CHECK WAN
# ==========================================================

check_wan()
{
    # Проверяем физический линк
    if [ -f "/sys/class/net/$WAN_INTERFACE/carrier" ]; then
        CARRIER="$(cat "/sys/class/net/$WAN_INTERFACE/carrier" 2>/dev/null)"

        if [ "$CARRIER" != "1" ]; then
            return 1
        fi
    fi

    # Проверяем наличие WAN default route
    ip route show default dev "$WAN_INTERFACE" 2>/dev/null | grep -q default || {
        return 1
    }

    # Проверяем интернет напрямую через WAN.
    # Используем mark 1, чтобы гарантированно выбрать table wan.
    ip route get 213.180.204.127 mark 1 2>/dev/null |
        grep -q "dev $WAN_INTERFACE" || {
        return 1
    }

    return 0
}

# ==========================================================
# CHECK REAL VPN
# ==========================================================

check_vpn()
{
    # tun-xor должен существовать
    ip link show "$VPN_INTERFACE" >/dev/null 2>&1 || {
        return 1
    }

    # Проверяем именно VPN peer.
    # Наличие tun-xor само по себе НЕ означает, что VPN работает.
    ping -c 2 -W 3 -I "$VPN_INTERFACE" "$VPN_GATEWAY" \
        >/dev/null 2>&1 || {
        return 1
    }

    return 0
}

# ==========================================================
# ENABLE EMERGENCY DNS
# ==========================================================

enable_failover_dns()
{

    if [ ! -f "$RESOLV_BACKUP" ]; then
        cp /tmp/resolv.conf "$RESOLV_BACKUP"
    fi


    cat > /tmp/resolv.conf <<EOF
nameserver 217.174.227.102
nameserver 217.174.237.105
EOF


    # ==========================================
    # ==========================================
    # GitHub routes via WAN
    # ==========================================
    WAN_GW="$(ip route | awk '/default/ && /eth0.2/ {print $3; exit}')"
    [ -n "$WAN_GW" ] && {
        ip route add 185.199.108.0/22 via "$WAN_GW" dev "$WAN_INTERFACE" 2>/dev/null;
        ip route add 104.16.0.0/13 via "$WAN_GW" dev "$WAN_INTERFACE" 2>/dev/null;
        log "GitHub WAN routes added";
    }


    log "Emergency DNS enabled"

}

# ==========================================================
# RESTORE DNS
# ==========================================================

restore_dns()
{
    if [ -f "$RESOLV_BACKUP" ]; then
        cp "$RESOLV_BACKUP" /tmp/resolv.conf 2>/dev/null
        rm -f "$RESOLV_BACKUP"
        log "DNS restored"
    fi
}

# ------------------------------------------
# Download file from GitHub (Raw -> jsDelivr)
# ------------------------------------------

download_github()
{
    FILE="$1"
    OUTPUT="$2"

    RAW_URL="$GITHUB_RAW/$FILE"
    CDN_URL="$GITHUB_CDN/$FILE"

    rm -f "$OUTPUT"

    log "Download $FILE from GitHub Raw"

    wget -q --timeout=20 -O "$OUTPUT" "$RAW_URL"

    if [ -s "$OUTPUT" ]; then
        log "$FILE downloaded from GitHub Raw"
        return 0
    fi

    rm -f "$OUTPUT"

    log "GitHub Raw failed, trying jsDelivr"

    wget -q --timeout=20 -O "$OUTPUT" "$CDN_URL"

    if [ -s "$OUTPUT" ]; then
        log "$FILE downloaded from jsDelivr"
        return 0
    fi

    rm -f "$OUTPUT"

    log "Download failed: $FILE"

    return 1
}

# ------------------------------------------
# Validate client.conf
# ------------------------------------------

# ==========================================================
# CHECK CLIENT CONFIG
# ==========================================================

check_client()
{
    grep -q 'dev tun-xor' "$TMP_CLIENT" || {
        log "client.conf validation failed: tun-xor missing"
        return 1
    }

    grep -q 'scramble xormask' "$TMP_CLIENT" || {
        log "client.conf validation failed: XOR missing"
        return 1
    }

    grep -q 'remote ' "$TMP_CLIENT" || {
        log "client.conf validation failed: remote missing"
        return 1
    }

    return 0
}

# ==========================================================
# CHECK BYPASS
# ==========================================================

check_bypass()
{
    grep -q '/' "$TMP_BYPASS" || {
        log "vpn-bypass.list validation failed"
        return 1
    }

    return 0
}

# ==========================================================
# INSTALL FILES
# ==========================================================

install_files()
{
    mkdir -p "$BACKUP_DIR"

    if [ -f "$VPN_CONFIG" ]; then
        cp "$VPN_CONFIG" "$BACKUP_DIR/client.conf.old" 2>/dev/null
    fi

    if [ -f "$BYPASS_FILE" ]; then
        cp "$BYPASS_FILE" "$BACKUP_DIR/vpn-bypass.list.old" 2>/dev/null
    fi

    cp "$TMP_CLIENT" "$VPN_CONFIG" || {
        log "Failed to install client.conf"
        return 1
    }

    chmod 600 "$VPN_CONFIG"

    cp "$TMP_BYPASS" "$BYPASS_FILE" || {
        log "Failed to install vpn-bypass.list"
        return 1
    }

    log "Files replaced"

    return 0
}

# ==========================================================
# RESTART SERVICES
# ==========================================================

restart_services()
{
    log "Restart vpn-bypass"

    /etc/init.d/vpn-bypass restart >/dev/null 2>&1

    sleep 3

    log "Stop OpenVPN"

    /etc/init.d/openvpn stop >/dev/null 2>&1

    sleep 5

    log "Start OpenVPN"

    /etc/init.d/openvpn start >/dev/null 2>&1

    return 0
}

# ==========================================================
# CLEAN TEMP FILES
# ==========================================================

cleanup()
{
    rm -f "$TMP_CLIENT"
    rm -f "$TMP_BYPASS"
    rm -f "$TMP_WATCHDOG"
    rm -f "$TMP_ROUTER_SYNC"
}

# ==========================================================
# MAIN
# ==========================================================

log "Watchdog started"

# ----------------------------------------------------------
# 1. Проверяем WAN
# ----------------------------------------------------------

if ! check_wan; then
    log "WAN internet unavailable"
    log "No WAN internet, recovery skipped"
    cleanup
    exit 0
fi

# ----------------------------------------------------------
# 2. Проверяем настоящий VPN
# ----------------------------------------------------------

if check_vpn; then
    log "VPN OK"
    cleanup
    exit 0
fi

log "VPN DOWN"

# ----------------------------------------------------------
# 3. Даём OpenVPN немного времени
# ----------------------------------------------------------

sleep 30

if check_vpn; then
    log "VPN recovered automatically"
    cleanup
    exit 0
fi

log "Starting recovery"

# ----------------------------------------------------------
# 4. Проверяем WAN ещё раз
# ----------------------------------------------------------

if ! check_wan; then
    log "WAN lost before recovery"
    log "Recovery skipped"
    cleanup
    exit 0
fi

# ----------------------------------------------------------
# 5. Включаем аварийный DNS
# ----------------------------------------------------------

enable_failover_dns

sleep 3

# ----------------------------------------------------------
# 6. Скачиваем новый client.conf
# ----------------------------------------------------------

if ! download_github "$CLIENT_FILE" "$TMP_CLIENT"; then
    log "client.conf download failed"
    restore_dns
    cleanup
    exit 1
fi

if ! check_client; then
    log "client.conf rejected"
    restore_dns
    cleanup
    exit 1
fi

# ----------------------------------------------------------
# 7. Скачиваем bypass
# ----------------------------------------------------------

if ! download_github "$BYPASS_FILE_REMOTE" "$TMP_BYPASS"; then
    log "vpn-bypass.list download failed"
    restore_dns
    cleanup
    exit 1
fi

if ! check_bypass; then
    log "vpn-bypass.list rejected"
    restore_dns
    cleanup
    exit 1
fi

# ----------------------------------------------------------
# 8. Устанавливаем файлы
# ----------------------------------------------------------

if ! install_files; then
    log "File installation failed"
    restore_dns
    cleanup
    exit 1
fi

# ----------------------------------------------------------
# 9. Перезапускаем
# ----------------------------------------------------------

restart_services

# ----------------------------------------------------------
# 10. Ждём восстановления VPN
# ----------------------------------------------------------

log "Waiting for VPN restoration"

sleep 30

if check_vpn; then
    log "VPN RESTORED SUCCESSFULLY"
    restore_dns
    cleanup
    exit 0
fi

sleep 30

if check_vpn; then
    log "VPN RESTORED SUCCESSFULLY"
    restore_dns
    cleanup
    exit 0
fi

sleep 30

if check_vpn; then
    log "VPN RESTORED SUCCESSFULLY"
    restore_dns
    cleanup
    exit 0
fi

# ----------------------------------------------------------
# 11. Не восстановился
# ----------------------------------------------------------

log "VPN STILL DOWN"

restore_dns
cleanup

exit 1

