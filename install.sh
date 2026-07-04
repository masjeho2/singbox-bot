# =================================================================
# Skrip Instalasi Server sing-box & HAProxy
# Sumber Bahan: https://github.com/masjeho2/singbox-bot
#
# DIPERBARUI: Menambahkan instalasi grpcurl.
# Tanpa grpcurl, bot Telegram (xray-singbox-monggodb) TIDAK BISA
# membaca statistik traffic per-user dari Sing-box — akibatnya
# sistem kuota akan selalu terbaca 0 Bytes meski user sudah
# memakai traffic, dan auto-expired-by-quota tidak akan jalan.
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

# Versi grpcurl yang dipasang (cek rilis terbaru di
# https://github.com/fullstorydev/grpcurl/releases jika perlu update)
GRPCURL_VERSION="1.9.1"

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

# --- [ FIX #1: PAKSA IPv4 UNTUK WGET/CURL/APT ] ---
# Penting: beberapa VPS (terutama yg punya IPv6 address tapi route-nya mati)
# akan bikin wget/curl default ke IPv6 (SYN-SENT timeout). Paksa IPv4.
force_ipv4() {
    log_message "INFO" "Memaksa IPv4 untuk wget/curl/apt (fix koneksi IPv6)..."
    mkdir -p /etc/apt/apt.conf.d
    cat > /etc/apt/apt.conf.d/99-force-ipv4 << 'EOF'
Acquire::ForceIPv4 "true";
EOF
    cat > /root/.wgetrc << 'EOF'
prefer_family = IPv4
EOF
    cat > /root/.curlrc << 'EOF'
-4
EOF
    chmod 644 /root/.wgetrc /root/.curlrc
    log_message "INFO" "IPv4 forced."
}

# --- [ PROSES INSTALASI ] ---

update_system() {
    log_message "INFO" "Memperbarui daftar paket sistem..."
    apt-get update -y
    apt-get full-upgrade -y
    apt-get autoremove -y
}

install_dependencies() {
    log_message "INFO" "Menginstal dependensi yang dibutuhkan..."
    local pkgs=(socat curl wget screen cron netfilter-persistent vnstat fail2ban sysstat jq gnupg software-properties-common tar)
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

install_grpcurl() {
    # FIX KRITIS: grpcurl WAJIB ada agar bot bisa query traffic stats
    # Sing-box lewat V2Ray API (gRPC). Tanpa ini, sistem kuota tidak
    # akan pernah berfungsi — kuota akan selalu terbaca 0 Bytes.
    if is_cmd_installed "grpcurl"; then
        log_message "INFO" "grpcurl sudah terinstal, dilewati."
        return 0
    fi

    log_message "INFO" "Menginstal grpcurl v${GRPCURL_VERSION} (dibutuhkan untuk tracking kuota)..."

    local arch
    case "$(uname -m)" in
        x86_64)  arch="x86_64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *)
            log_message "WARN" "Arsitektur $(uname -m) tidak dikenal, mencoba x86_64..."
            arch="x86_64"
            ;;
    esac

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local tarball="grpcurl_${GRPCURL_VERSION}_linux_${arch}.tar.gz"
    local download_url="https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/${tarball}"

    if curl -fsSL -o "${tmp_dir}/${tarball}" "${download_url}"; then
        tar -xzf "${tmp_dir}/${tarball}" -C "${tmp_dir}"
        mv "${tmp_dir}/grpcurl" /usr/local/bin/grpcurl
        chmod +x /usr/local/bin/grpcurl
        rm -rf "${tmp_dir}"

        if is_cmd_installed "grpcurl"; then
            log_message "INFO" "grpcurl berhasil diinstal: $(grpcurl -version 2>&1)"
        else
            log_message "ERROR" "grpcurl gagal terdeteksi setelah instalasi. Cek manual nanti."
        fi
    else
        rm -rf "${tmp_dir}"
        log_message "ERROR" "Gagal download grpcurl dari ${download_url}."
        log_message "WARN"  "Sistem kuota TIDAK akan berfungsi tanpa grpcurl."
        log_message "WARN"  "Install manual nanti dengan:"
        log_message "WARN"  "  curl -fsSL -o grpcurl.tar.gz ${download_url}"
        log_message "WARN"  "  tar -xzf grpcurl.tar.gz && mv grpcurl /usr/local/bin/"
    fi
}

install_haproxy() {
    ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
    if is_pkg_installed "haproxy"; then
        log_message "INFO" "HAProxy sudah terinstal, lewati."
        systemctl enable haproxy
        return 0
    fi

    # --- [ FIX #2: SKIP PPA LAUNCHPAD JIKA REPO UDAH PUNYA HAPROXY ] ---
    # Launchpad (PPA host) sering tidak reachable di VPS tertentu.
    # Ubuntu 22.04/24.04 sudah menyediakan HAProxy 2.4+/2.8+ di repo utama,
    # jadi kita coba repo utama dulu, baru fallback ke PPA kalau perlu.
    log_message "INFO" "Mencoba install HAProxy dari repo Ubuntu (tanpa PPA)..."
    if apt-get install -y haproxy 2>&1 | tail -3; then
        if is_pkg_installed "haproxy"; then
            log_message "INFO" "HAProxy terinstal dari repo Ubuntu."
            systemctl enable haproxy
            return 0
        fi
    fi

    # Fallback: coba PPA (mungkin gagal di VPS tanpa akses ke launchpad)
    log_message "WARN" "Repo Ubuntu tidak menyediakan haproxy, mencoba PPA vbernat/haproxy-2.8..."
    if add-apt-repository ppa:vbernat/haproxy-2.8 -y 2>/dev/null; then
        apt-get update && apt-get install -y "haproxy=2.8.*"
    else
        log_message "ERROR" "Gagal install haproxy (PPA launchpad tidak reachable)."
        log_message "WARN"  "Coba manual: apt-get install haproxy"
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

    # --- [ FIX #3: REPLACE '::' KE '0.0.0.0' DI INBOUNDS ] ---
    # config.json dari repo pakai "listen": "::" (IPv6 wildcard).
    # Jika VPS disable IPv6, sing-box akan crash karena tidak bisa bind ke '::'.
    # Ganti ke "0.0.0.0" supaya kompatibel dengan VPS IPv4-only / IPv6-disabled.
    if grep -q '"listen": "::"' /etc/sing-box/config.json 2>/dev/null; then
        sed -i 's/"listen": "::"/"listen": "0.0.0.0"/g' /etc/sing-box/config.json
        local count
        count=$(grep -c '"listen": "0.0.0.0"' /etc/sing-box/config.json)
        log_message "INFO" "FIX #3: Mengganti '::' → '0.0.0.0' di ${count} inbounds (IPv6-safe)."
    fi
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

install_nodejs() {
    # Cek apakah Node.js sudah terinstal menggunakan command -v
    if ! command -v node >/dev/null 2>&1; then
        log_message "INFO" "Node.js belum terinstal. Menginstal Node.js..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
        \. "$HOME/.nvm/nvm.sh"
        nvm install 24
        npm -v
        log_message "INFO" "Node.js berhasil diinstal."
    else
        # Hanya dieksekusi jika Node.js sedari awal sudah ada
        log_message "INFO" "Node.js sudah terinstal."
    fi
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
    mkdir -p /root/api
    wget -q -O /root/api/package.json "${REPO_URL}/package.json"
    wget -q -O /root/api/api-server.js "${REPO_URL}/api-server.js"
    chmod +x /root/api/api-server.js
    log_message "INFO" "API server di-download ke /root/api/api-server.js"
    
    # Install npm dependencies untuk API server
    log_message "INFO" "Menginstal npm dependencies API server..."
    if command -v node >/dev/null 2>&1; then
        cd /root/api && npm install --silent 2>&1 | tail -3
    else
        log_message "WARN" "Node.js tidak ditemukan, npm install dilewati"
    fi
    cd - >/dev/null
}

verify_installation() {
    log_message "INFO" "Memverifikasi instalasi komponen kritis..."
    local all_ok=true

    if is_cmd_installed "sing-box"; then
        log_message "INFO" "✓ sing-box terinstal: $(sing-box version 2>&1 | head -n1)"
    else
        log_message "ERROR" "✗ sing-box TIDAK terinstal."
        all_ok=false
    fi

    if is_cmd_installed "grpcurl"; then
        log_message "INFO" "✓ grpcurl terinstal: $(grpcurl -version 2>&1)"
    else
        log_message "ERROR" "✗ grpcurl TIDAK terinstal — kuota tidak akan berfungsi!"
        all_ok=false
    fi

    if is_cmd_installed "haproxy"; then
        log_message "INFO" "✓ haproxy terinstal."
    else
        log_message "ERROR" "✗ haproxy TIDAK terinstal."
        all_ok=false
    fi

    if [ -d /root/protos/app/stats/command ] && [ -f /root/protos/app/stats/command/command.proto ]; then
        log_message "INFO" "✓ Proto file untuk stats sudah ada."
    else
        log_message "ERROR" "✗ Proto file TIDAK lengkap di /root/protos."
        all_ok=false
    fi

if [ -f "/root/api/api-server.js" ]; then
        log_message "INFO" "✓ API server terinstal di /root/api/"
    else
        log_message "ERROR" "✗ API server TIDAK terinstal."
        all_ok=false
    fi

    if [ -d "/root/api/node_modules" ]; then
        log_message "INFO" "✓ API npm dependencies terinstall"
    else
        log_message "WARN" "✗ API npm dependencies belum terinstall"
    fi

    if [ "$all_ok" = false ]; then
        log_message "WARN" "Beberapa komponen gagal terinstal. Cek log di atas sebelum lanjut."
    fi
}

finalize_installation() {
    log_message "INFO" "Menyelesaikan instalasi dan merestart layanan..."
    systemctl daemon-reload
    systemctl restart haproxy
    systemctl restart sing-box.service
    
# Start API server via PM2
    if command -v pm2 >/dev/null 2>&1; then
        log_message "INFO" "Memulai API server via PM2..."
        cd /root/api && pm2 start api-server.js --name api 2>&1 | tail -5
        pm2 save 2>/dev/null
        log_message "INFO" "✓ API server berjalan via PM2"
    else
        log_message "WARN" "PM2 tidak ditemukan, API server tidak di-start otomatis"
    fi

    local total_secs="$(($(date +%s) - start_time))"
    local mins=$((total_secs / 60))
    local secs=$((total_secs % 60))
    log_message "INFO" "Instalasi selesai dalam ${mins} menit ${secs} detik!"
}

# --- [ EKSEKUSI UTAMA ] ---
main() {
    clear
    log_message "INFO" "=============================================="
    log_message "INFO" "    Auto Installer Sing-box + HAProxy         "
    log_message "INFO" "    Bahan dari: masjeho2/singbox-bot          "
    log_message "INFO" "=============================================="
    echo ""

    force_ipv4
    update_system
    install_dependencies
    setup_directories
    download_and_setup_singbox
    install_grpcurl
    install_haproxy
    configure_domain_and_ssl
    download_configurations
    tune_system_performance
    install_nodejs
    setup_tools
    verify_installation
    finalize_installation
    

    echo ""
    read -rp $'\e[33;1m[ INFO ]\e[0m \e[37;1mApakah Anda ingin me-reboot VPS sekarang? (Y/N): \e[0m' answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# Jalankan skrip
main
