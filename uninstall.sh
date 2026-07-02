#!/usr/bin/env bash
# =================================================================
# Uninstaller Sing-box + HAProxy + API
# Sumber: masjeho2/singbox-bot
#
# Mode:
#   --full    = hapus semua (sing-box, haproxy, grpcurl, acme.sh,
#               node, api, config, cert, menu, tools)
#   --keep    = cuma stop & remove sing-box + haproxy services,
#               keep node/api/grpcurl/tools
#
# Usage:
#   bash uninstall.sh           # mode interaktif (tanya dulu)
#   bash uninstall.sh --full    # full uninstall
#   bash uninstall.sh --keep    # keep tools, remove services
# =================================================================

set -e

NC='\e[0m'
GB='\e[32;1m'
YB='\e[33;1m'
RB='\e[31;1m'
WB='\e[37;1m'

log_message() {
    local type="$1"
    local message="$2"
    case "$type" in
        "INFO")  color="$GB" ;;
        "WARN")  color="$YB" ;;
        "ERROR") color="$RB" ;;
        *)       color="$NC" ;;
    esac
    echo -e "${color}[ ${type} ]${NC} ${WB}${message}${NC}"
}

is_service_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

is_cmd_installed() {
    command -v "$1" &>/dev/null
}

# ==========================================
#         PARSING ARGUMENTS
# ==========================================
MODE="${1:-}"

if [ "$MODE" != "--full" ] && [ "$MODE" != "--keep" ]; then
    echo ""
    log_message "WARN" "Pilih mode uninstall:"
    echo ""
    echo "  1) --full   Hapus SEMUA (sing-box, haproxy, grpcurl, acme.sh,"
    echo "              node, api.js, config, cert, proto files, menu)"
    echo ""
    echo "  2) --keep   Stop & remove services (sing-box, haproxy)"
    echo "              TAPI keep: node, pm2, grpcurl, api.js, protos, menu"
    echo ""
    read -rp "$(echo -e "${WB}Pilih mode [1/2]: ${NC}")" choice
    case "$choice" in
        1) MODE="--full" ;;
        2) MODE="--keep" ;;
        *)
            log_message "ERROR" "Invalid choice. Exiting."
            exit 1
            ;;
    esac
fi

echo ""
log_message "WARN" "Mode: ${MODE}"
echo ""
read -rp "$(echo -e "${RB}⚠️  Yakin ingin uninstall? Semua config sing-box akan hilang! (y/N): ${NC}")" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_message "INFO" "Dibatalkan. Tidak ada yang dihapus."
    exit 0
fi

start_time=$(date +%s)

# ==========================================
#       STOP & DISABLE SERVICES
# ==========================================
stop_services() {
    log_message "INFO" "Stop & disable semua services..."

    for svc in sing-box haproxy singbox-api pm2-root; do
        if is_service_active "$svc"; then
            systemctl stop "$svc"
            log_message "INFO" "Stopped: $svc"
        fi
        if systemctl is-enabled "$svc" 2>/dev/null; then
            systemctl disable "$svc" 2>/dev/null || true
            log_message "INFO" "Disabled: $svc"
        fi
    done

    # PM2 daemon
    if is_cmd_installed "pm2"; then
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        export PATH="$PATH:/root/.nvm/versions/node/v24.18.0/bin"
        pm2 kill 2>/dev/null || true
        log_message "INFO" "PM2 daemon killed."
    fi
}

# ==========================================
#       REMOVE SING-BOX
# ==========================================
remove_singbox() {
    log_message "INFO" "Menghapus sing-box..."

    # Binary
    rm -f /usr/bin/sing-box
    log_message "INFO" "Removed: /usr/bin/sing-box"

    # Systemd service
    rm -f /etc/systemd/system/sing-box.service
    log_message "INFO" "Removed: sing-box.service"

    # Config & data
    rm -rf /etc/sing-box
    log_message "INFO" "Removed: /etc/sing-box/ (config, certs, domain)"

    # Logs
    rm -rf /var/log/sing-box
    log_message "INFO" "Removed: /var/log/sing-box/"

    # Data dir
    rm -rf /var/lib/sing-box
    log_message "INFO" "Removed: /var/lib/sing-box/"

    # System shared
    rm -rf /usr/local/share/sing-box
    log_message "INFO" "Removed: /usr/local/share/sing-box/ (geoip, geosite)"
}

# ==========================================
#       REMOVE HAPROXY
# ==========================================
remove_haproxy() {
    log_message "INFO" "Menghapus haproxy..."

    if is_pkg_installed "haproxy"; then
        apt-get remove --purge -y haproxy 2>/dev/null || true
        log_message "INFO" "Purged: haproxy"
    fi

    # Config & certs
    rm -rf /etc/haproxy
    log_message "INFO" "Removed: /etc/haproxy/"

    # Systemd (redundant, tapi cleanup)
    rm -f /etc/systemd/system/haproxy.service
}

# ==========================================
#       REMOVE API (root/api)
# ==========================================
remove_api() {
    log_message "INFO" "Menghapus API server (root/api/)..."
    rm -rf /root/api
    log_message "INFO" "Removed: /root/api/"

    # PM2 systemd
    rm -f /etc/systemd/system/singbox-api.service
    rm -f /etc/systemd/system/pm2-root.service
    systemctl daemon-reload
    log_message "INFO" "Removed: pm2-root.service, singbox-api.service"
}

# ==========================================
#       REMOVE PROTO FILES
# ==========================================
remove_protos() {
    log_message "INFO" "Menghapus proto files..."
    rm -rf /root/protos
    log_message "INFO" "Removed: /root/protos/"
}

# ==========================================
#       REMOVE TOOLS (menu, dns, certsing-box)
# ==========================================
remove_tools() {
    log_message "INFO" "Menghapus tools (menu, dns, certsing-box)..."
    rm -f /usr/bin/menu
    rm -f /usr/bin/dns
    rm -f /usr/bin/certsing-box
    log_message "INFO" "Removed: menu, dns, certsing-box"
}

# ==========================================
#       REMOVE GRPCURL
# ==========================================
remove_grpcurl() {
    log_message "INFO" "Menghapus grpcurl..."
    rm -f /usr/local/bin/grpcurl
    log_message "INFO" "Removed: grpcurl"
}

# ==========================================
#       REMOVE ACME.SH
# ==========================================
remove_acme() {
    log_message "INFO" "Menghapus acme.sh..."
    if [ -d ~/.acme.sh ]; then
        ~/.acme.sh/acme.sh --uninstall 2>/dev/null || true
        rm -rf ~/.acme.sh
        log_message "INFO" "Removed: acme.sh + certs"
    else
        log_message "INFO" "acme.sh tidak ditemukan, skip."
    fi
}

# ==========================================
#       REMOVE NODE.JS (NVM)
# ==========================================
remove_nodejs() {
    log_message "INFO" "Menghapus Node.js (nvm)..."
    export NVM_DIR="$HOME/.nvm"
    if [ -d "$NVM_DIR" ]; then
        rm -rf "$NVM_DIR"
        log_message "INFO" "Removed: $NVM_DIR"
    fi

    # PM2 global cache
    rm -rf /root/.pm2
    log_message "INFO" "Removed: PM2 cache"

    # NVM traces di shell profile
    for f in /root/.bashrc /root/.profile /root/.zshrc; do
        if [ -f "$f" ]; then
            sed -i '/NVM_DIR/d' "$f" 2>/dev/null || true
            sed -i '/nvm.sh/d' "$f" 2>/dev/null || true
            sed -i '/nvm\/bash_completion/d' "$f" 2>/dev/null || true
        fi
    done
    log_message "INFO" "Cleaned NVM references from shell profiles."
}

# ==========================================
#       REMOVE PM2 SYSTEMD
# ==========================================
remove_pm2_systemd() {
    log_message "INFO" "Removing PM2 systemd files..."
    rm -f /etc/systemd/system/pm2-root.service
    systemctl daemon-reload 2>/dev/null || true
}

# ==========================================
#       CLEANUP APT
# ==========================================
cleanup_apt() {
    log_message "INFO" "Cleaning apt cache..."
    apt-get autoremove -y 2>/dev/null || true
    apt-get clean 2>/dev/null || true
}

# ==========================================
#       FINALIZE
# ==========================================
finalize() {
    local total_secs="$(($(date +%s) - start_time))"
    local mins=$((total_secs / 60))
    local secs=$((total_secs % 60))

    echo ""
    log_message "INFO" "=============================================="
    log_message "INFO" "  Uninstall selesai dalam ${mins}m ${secs}s"
    log_message "INFO" "=============================================="

    # Verify removal
    echo ""
    log_message "INFO" "=== VERIFIKASI ==="
    is_cmd_installed "sing-box" && log_message "WARN" "sing-box masih ada" || log_message "INFO" "✓ sing-box removed"
    is_cmd_installed "haproxy" && log_message "WARN" "haproxy masih ada" || log_message "INFO" "✓ haproxy removed"
    is_cmd_installed "grpcurl" && log_message "WARN" "grpcurl masih ada" || log_message "INFO" "✓ grpcurl removed"
    [ -d /etc/sing-box ] && log_message "WARN" "/etc/sing-box masih ada" || log_message "INFO" "✓ /etc/sing-box removed"
    [ -d /etc/haproxy ] && log_message "WARN" "/etc/haproxy masih ada" || log_message "INFO" "✓ /etc/haproxy removed"
    [ -d /root/api ] && log_message "WARN" "/root/api masih ada" || log_message "INFO" "✓ /root/api removed"
    [ -d /root/.nvm ] && log_message "WARN" "Node.js/nvm masih ada" || log_message "INFO" "✓ Node.js removed"
    [ -f /usr/bin/menu ] && log_message "WARN" "menu masih ada" || log_message "INFO" "✓ tools removed"

    echo ""
    log_message "WARN" "Reboot disarankan untuk bersihkan semua service."
    read -rp "$(echo -e "${YB}Reboot sekarang? (y/N): ${NC}")" answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# ==========================================
#       MAIN
# ==========================================
main() {
    clear
    echo ""
    log_message "WARN" "=============================================="
    log_message "WARN" "  UNINSTALL Sing-box + HAProxy              "
    log_message "WARN" "  Mode: ${MODE}                             "
    log_message "WARN" "=============================================="
    echo ""

    stop_services

    if [ "$MODE" == "--full" ]; then
        remove_singbox
        remove_haproxy
        remove_api
        remove_protos
        remove_tools
        remove_grpcurl
        remove_acme
        remove_nodejs
        remove_pm2_systemd
        cleanup_apt
    else
        # --keep: cuma remove services, keep tools
        remove_singbox
        remove_haproxy
        remove_api
        remove_pm2_systemd
        cleanup_apt
        echo ""
        log_message "INFO" "Mode --keep: grpcurl, node, api, protos, menu, acme.sh TIDAK dihapus."
    fi

    systemctl daemon-reload
    finalize
}

main
