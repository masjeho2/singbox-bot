# =================================================================
# Skrip Instalasi Server sing-box & HAProxy
# Sumber Bahan: https://github.com/masjeho2/singbox-bot
# =================================================================

set -e

# --- [ PENGATURAN AWAL ] ---
NC='\e[0m'
GB='\e[32;1m'
YB='\e[33;1m'
RB='\e[31;1m'
WB='\e[37;1m'

# URL Raw dari repositori GitHub Anda
REPO_URL="https://raw.githubusercontent.com/masjeho2/singbox-bot/main"

start_time=$(date +%s)

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

is_pkg_installed() { dpkg -l "$1" 2>/dev/null | grep -q "^ii"; }
is_cmd_installed() { command -v "$1" &>/dev/null; }

# --- [ PROSES INSTALASI ] ---

update_system() {
    log_message "INFO" "Memperbarui daftar paket sistem..."
    apt-get update -y
    apt-get full-upgrade -y
    apt-get autoremove -y
}

install_dependencies() {
    log_message "INFO" "Menginstal dependensi yang dibutuhkan..."
    local pkgs=(socat curl wget screen cron netfilter-persistent vnstat fail2ban sysstat jq gnupg software-properties-common)
    for pkg in "${pkgs[@]}"; do
        if ! is_pkg_installed "$pkg"; then
            apt-get install -y "$pkg"
        fi
    done
}

setup_directories() {
    log_message "INFO" "Membuat direktori sistem..."
    mkdir -p /etc/haproxy/certs /var/log/sing-box /usr/local/share/sing-box
    mkdir -p /etc/sing-box /var/lib/sing-box
}

download_and_setup_singbox() {
    log_message "INFO" "Mengunduh binary sing-box dari repositori masjeho2..."
    
    # 1. Download Binary Sing-box
    wget -q --show-progress -O /usr/bin/sing-box "${REPO_URL}/sing-box"
    chmod +x /usr/bin/sing-box
    log_message "INFO" "Binary sing-box berhasil diinstal."

    # 2. Download Service Sing-box
    log_message "INFO" "Mengunduh file service systemd..."
    wget -q -O /etc/systemd/system/sing-box.service "${REPO_URL}/sing-box.service"
    
    systemctl daemon-reload
    systemctl enable sing-box.service

    # 3. Download GeoIP & GeoSite
    if [ ! -f /usr/local/share/sing-box/geoip.dat ]; then
        log_message "INFO" "Mengunduh GeoIP & GeoSite rules..."
        curl -L -o /usr/local/share/sing-box/geoip.dat https://github.com/malikshi/v2ray-rules-dat/releases/latest/download/geoip.dat
        curl -L -o /usr/local/share/sing-box/geosite.dat https://github.com/malikshi/v2ray-rules-dat/releases/latest/download/geosite.dat
    fi
}

install_haproxy() {
    ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
    if ! is_pkg_installed "haproxy"; then
        log_message "INFO" "Menginstal HAProxy..."
        add-apt-repository ppa:vbernat/haproxy-2.8 -y
        apt-get update && apt-get install -y "haproxy=2.8.*"
    fi
    systemctl enable haproxy
}

configure_domain_and_ssl() {
    local domain_file="/etc/sing-box/domain"
    
    if [ -f "$domain_file" ] && [ -s "$domain_file" ]; then
        log_message "INFO" "Domain sudah ada: $(cat $domain_file)"
        return 0
    fi

    read -rp "$(echo -e "${WB}Masukkan domain/subdomain VPS Anda: ${NC}")" dns
    echo "$dns" > "$domain_file"
    log_message "INFO" "Domain disimpan."

    if [ ! -f /etc/sing-box/fullchain.crt ]; then
        log_message "INFO" "Menerbitkan SSL Certificate untuk domain ${dns}..."
        systemctl stop haproxy || true
        
        if [ ! -d ~/.acme.sh ]; then curl https://get.acme.sh | sh; fi
        ~/.acme.sh/acme.sh --issue -d "$dns" --server letsencrypt --keylength ec-256 \
            --fullchain-file /etc/sing-box/fullchain.crt \
            --key-file /etc/sing-box/private.key \
            --standalone --force

        # Gabungkan sertifikat untuk HAProxy
        cat /etc/sing-box/fullchain.crt /etc/sing-box/private.key > /etc/haproxy/certs/domain.pem
        log_message "INFO" "SSL Certificate berhasil dipasang."
    fi
}

download_configurations() {
    log_message "INFO" "Mengunduh file konfigurasi dari GitHub..."
    
    # Download Config Sing-box
    wget -q -O /etc/sing-box/config.json "${REPO_URL}/config.json"
    log_message "INFO" "config.json berhasil diunduh."

    # Download Config HAProxy
    wget -q -O /etc/haproxy/haproxy.cfg "${REPO_URL}/haproxy.cfg"
    log_message "INFO" "haproxy.cfg berhasil diunduh."
}

tune_system_performance() {
    log_message "INFO" "Melakukan tuning performa jaringan server..."
    cat > /etc/sysctl.conf << 'END'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.file-max=1000000
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_tw_reuse = 1
END
    sysctl -p > /dev/null 2>&1
}

finalize_installation() {
    log_message "INFO" "Menyelesaikan instalasi dan merestart layanan..."
    systemctl daemon-reload
    systemctl restart haproxy
    systemctl restart sing-box.service
    
    local total_secs="$(($(date +%s) - start_time))"
    local mins=$((total_secs / 60))
    local secs=$((total_secs % 60))
    log_message "INFO" "Instalasi selesai dalam ${mins} menit ${secs} detik!"
}

setup_tools() {
    log_message "INFO" "Menyiapkan tools tambahan..."
    # menu, auto ssl
    wget -q -O /usr/bin/menu "https://raw.githubusercontent.com/masjeho2/v1/refs/heads/sing-box/menu/menu.sh"
    chmod +x /usr/bin/menu
    wget -q -O /usr/bin/dns "https://raw.githubusercontent.com/masjeho2/v1/refs/heads/sing-box/other/dns.sh"
    chmod +x /usr/bin/dns
    wget -q -O /usr/bin/certsing-box "https://raw.githubusercontent.com/masjeho2/v1/refs/heads/sing-box/other/certsing-box.sh"
    chmod +x /usr/bin/certsing-box
    mkdir -p /root/protos/app/stats/command
    mkdir -p /root/protos/common/serial
    wget -q -O /root/protos/app/stats/config.proto "${REPO_URL}/protos/app/stats/config.proto"
    wget -q -O /root/protos/app/stats/command/command.proto "${REPO_URL}/protos/app/stats/command/command.proto"
    wget -q -O /root/protos/common/serial/typed_message.proto "${REPO_URL}/protos/common/serial/typed_message.proto"    

}

# --- [ EKSEKUSI UTAMA ] ---
main() {
    clear
    log_message "INFO" "=============================================="
    log_message "INFO" "    Auto Installer Sing-box + HAProxy         "
    log_message "INFO" "    Bahan dari: masjeho2/singbox-bot          "
    log_message "INFO" "=============================================="
    echo ""

    update_system
    install_dependencies
    setup_directories
    download_and_setup_singbox
    install_haproxy
    configure_domain_and_ssl
    download_configurations
    tune_system_performance
    finalize_installation
    setup_tools

    echo ""
    read -rp $'\e[33;1m[ INFO ]\e[0m \e[37;1mApakah Anda ingin me-reboot VPS sekarang? (Y/N): \e[0m' answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# Jalankan skrip
main