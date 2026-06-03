# =================================================================
# Skrip Instalasi Server sing-box, HAProxy, dan Bot (LOKAL CORE)
#
# Deskripsi:
# Skrip ini mengotomatiskan penyiapan server proxy menggunakan 
# binary sing-box, config, dan service langsung dari repo lokal.
# =================================================================

set -e

# --- [BAGIAN 1: PENGATURAN AWAL & VARIABEL] ---
NC='\e[0m'
GB='\e[32;1m'
YB='\e[33;1m'
RB='\e[31;1m'
WB='\e[37;1m'
BB='\e[34;1m'

# Dapatkan direktori repository lokal saat ini
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Variabel repo tambahan (opsional untuk menu/skrip bot jika masih diperlukan)
GITHUB_REPO="raw.githubusercontent.com/masjeho2"
CONF_REPO="${GITHUB_REPO}/conf/main"
MENU_REPO="${GITHUB_REPO}/v1/singbox-bot"

start_time=$(date +%s)

# --- [BAGIAN 2: FUNGSI UTILITAS] ---
log_message() {
    local type="$1"
    local message="$2"
    case "$type" in
        "INFO")  color="$GB" ;;
        "WARN")  color="$YB" ;;
        "ERROR") color="$RB" ;;
        "SKIP")  color="$BB" ;;
        *)       color="$NC" ;;
    esac
    echo -e "${color}[ ${type} ]${NC} ${WB}${message}${NC}"
}

secs_to_human() {
    local total_secs=$1
    local hours=$((total_secs / 3600))
    local minutes=$(((total_secs / 60) % 60))
    local seconds=$((total_secs % 60))
    log_message "INFO" "Total waktu instalasi: ${hours} jam, ${minutes} menit, ${seconds} detik."
}

is_pkg_installed() { dpkg -l "$1" 2>/dev/null | grep -q "^ii"; }
is_cmd_installed() { command -v "$1" &>/dev/null; }

# --- [BAGIAN 3: FUNGSI-FUNGSI INSTALASI] ---

update_system() {
    log_message "INFO" "Memperbarui daftar paket sistem..."
    apt-get update -y
    apt-get full-upgrade -y
    apt-get autoremove -y
}

install_dependencies() {
    log_message "INFO" "Memeriksa dependensi..."
    local pkgs=(socat curl screen cron screenfetch netfilter-persistent vnstat lsof fail2ban sysstat jq gnupg software-properties-common)
    for pkg in "${pkgs[@]}"; do
        if ! is_pkg_installed "$pkg"; then
            apt-get install -y "$pkg"
        fi
    done
}

setup_directories() {
    log_message "INFO" "Memastikan direktori..."
    mkdir -p /backup /user /etc/haproxy/certs /var/log/sing-box /usr/local/share/sing-box
    mkdir -p /etc/sing-box /var/lib/sing-box /usr/local/etc/sing-box/{adminenv,agenenv}
}

setup_sing-box() {
    log_message "INFO" "Menyiapkan sing-box Core dari repository lokal..."
    
    # 1. Install Binary
    if [ -f "$DIR/sing-box" ]; then
        cp "$DIR/sing-box" /usr/bin/sing-box
        chmod +x /usr/bin/sing-box
        log_message "INFO" "Binary sing-box lokal berhasil disalin ke /usr/bin/sing-box"
    else
        log_message "ERROR" "File binary 'sing-box' tidak ditemukan di $DIR!"
        exit 1
    fi

    # 2. Install Service Systemd
    if [ -f "$DIR/sing-box.service" ]; then
        cp "$DIR/sing-box.service" /etc/systemd/system/sing-box.service
        log_message "INFO" "Service sing-box.service lokal berhasil dipasang."
    else
        log_message "ERROR" "File 'sing-box.service' tidak ditemukan di $DIR!"
        exit 1
    fi

    systemctl daemon-reload
    systemctl enable sing-box.service

    # GeoIP & GeoSite
    if [ ! -f /usr/local/share/sing-box/geoip.dat ]; then
        log_message "INFO" "Mengunduh file GeoIP/GeoSite..."
        curl -L -o /usr/local/share/sing-box/geoip.dat https://github.com/malikshi/v2ray-rules-dat/releases/latest/download/geoip.dat
        curl -L -o /usr/local/share/sing-box/geosite.dat https://github.com/malikshi/v2ray-rules-dat/releases/latest/download/geosite.dat
    fi
}

install_haproxy() {
    ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
    if ! is_pkg_installed "haproxy"; then
        add-apt-repository ppa:vbernat/haproxy-2.8 -y
        apt-get update && apt-get install -y "haproxy=2.8.*"
    fi
    systemctl enable haproxy
}

configure_domain_and_ssl() {
    local domain_file="/etc/sing-box/domain"
    
    if [ -f "$domain_file" ] && [ -s "$domain_file" ]; then
        log_message "SKIP" "Domain sudah ada: $(cat $domain_file)"
        return 0
    fi

    read -rp "$(echo -e "${WB}Masukkan domain Anda: ${NC}")" dns
    echo "$dns" > "$domain_file"
    log_message "INFO" "Domain disimpan."

    if [ ! -f /etc/sing-box/fullchain.crt ]; then
        systemctl stop haproxy || true
        if [ ! -d ~/.acme.sh ]; then curl https://get.acme.sh | sh; fi
        ~/.acme.sh/acme.sh --issue -d "$dns" --server letsencrypt --keylength ec-256 \
            --fullchain-file /etc/sing-box/fullchain.crt \
            --key-file /etc/sing-box/private.key \
            --standalone --force

        cat /etc/sing-box/fullchain.crt /etc/sing-box/private.key > /etc/haproxy/certs/domain.pem
    fi
}

download_configurations() {
    log_message "INFO" "Menyalin file konfigurasi lokal..."
    
    # Copy Config Sing-box Lokal
    if [ -f "$DIR/config.json" ]; then
        cp "$DIR/config.json" /etc/sing-box/config.json
        log_message "INFO" "config.json berhasil dipasang."
    else
        log_message "ERROR" "File config.json tidak ditemukan di $DIR!"
        exit 1
    fi

    # Copy Config HAProxy Lokal
    if [ -f "$DIR/haproxy.cfg" ]; then
        cp "$DIR/haproxy.cfg" /etc/haproxy/haproxy.cfg
        log_message "INFO" "haproxy.cfg berhasil dipasang."
    else
        log_message "WARN" "File haproxy.cfg lokal tidak ditemukan! Anda harus memasangnya manual jika perlu."
    fi
}

tune_system_performance() {
    log_message "INFO" "Tuning performa jaringan..."
    cat > /etc/sysctl.conf << 'END'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.file-max=1000000
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_tw_reuse = 1
END
    sysctl -p
}

install_nodejs() {
    if ! is_cmd_installed "node"; then
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
        apt-get install -y nodejs
    fi
}

finalize_installation() {
    log_message "INFO" "Menyelesaikan tahap akhir..."
    systemctl daemon-reload
    systemctl enable cron haproxy sing-box
    systemctl restart cron haproxy sing-box
    log_message "INFO" "Instalasi selesai!"
}

# --- [BAGIAN 4: EKSEKUSI UTAMA] ---
main() {
    clear
    log_message "INFO" "=============================================="
    log_message "INFO" "  Instalasi Server sing-box (Lokal Mode)      "
    log_message "INFO" "=============================================="
    echo ""

    update_system
    install_dependencies
    setup_directories
    setup_sing-box
    install_haproxy
    install_nodejs
    configure_domain_and_ssl
    download_configurations
    tune_system_performance
    finalize_installation

    secs_to_human "$(($(date +%s) - start_time))"

    echo ""
    read -rp $'\e[33;1m[ INFO ]\e[0m \e[37;1mApakah Anda ingin me-reboot server sekarang? (Y/N): \e[0m' answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

main