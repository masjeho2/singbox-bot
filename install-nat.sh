#!/bin/bash
# =================================================================
# Skrip Instalasi Server sing-box & HAProxy (tanpa TLS)
# Sumber Bahan: https://github.com/masjeho2/singbox-bot
#
# PERUBAHAN:
#  - Prefix path (contoh: id-6) bisa diatur: lewat prompt, env PATH_ID,
#    atau argumen:  bash install.sh --path id-7
#  - config.json (sing-box) & haproxy.cfg ditulis langsung di skrip ini
#    (tidak lagi download dari GitHub). User dibiarkan kosong.
#  - Input domain & penerbitan SSL (acme.sh) dihapus karena tanpa TLS.
#  - grpcurl tetap dipasang (wajib untuk statistik kuota bot).
#  - frpc ikut dipasang (/etc/frp/frpc.toml). Isian: serverAddr, serverPort,
#    authToken, remotePort WS & gRPC (bisa lewat prompt, env, atau argumen).
#
# Pola path yang dihasilkan dari PATH_ID (contoh id-6):
#   WebSocket : /id-6/vmess , /id-6/vless-ws , /id-6/trojan-ws
#   gRPC      : id-6-vmess-grpc , id-6-vless-grpc , id-6-trojan-grpc
# =================================================================

set -e

# --- [ PENGATURAN AWAL ] ---
NC='\e[0m'
GB='\e[32;1m'
YB='\e[33;1m'
RB='\e[31;1m'
WB='\e[37;1m'
CY='\e[36;1m'
MG='\e[35;1m'
DM='\e[2m'

# URL Raw dari repositori GitHub (masih dipakai utk binary, service, proto, API)
REPO_URL="https://raw.githubusercontent.com/masjeho2/singbox-bot/main"

# Versi grpcurl yang dipasang
GRPCURL_VERSION="1.9.1"

# Prefix path default (bisa diubah lewat prompt / env / argumen)
DEFAULT_PATH_ID="id-6"
PATH_ID="${PATH_ID:-}"
PATH_ID_FILE="/etc/sing-box/path_id"

# Parse argumen:  --path <nama>
while [ $# -gt 0 ]; do
    case "$1" in
        --path|-p) PATH_ID="$2"; shift 2 ;;
        --path=*)  PATH_ID="${1#*=}"; shift ;;
        --frp-addr)        FRP_SERVER_ADDR="$2"; shift 2 ;;
        --frp-port)        FRP_SERVER_PORT="$2"; shift 2 ;;
        --frp-token)       FRP_TOKEN="$2"; shift 2 ;;
        --frp-ws-port)     FRP_WS_REMOTE_PORT="$2"; shift 2 ;;
        --frp-grpc-port)   FRP_GRPC_REMOTE_PORT="$2"; shift 2 ;;
        --no-frp)          FRP_SKIP=1; shift ;;
        *) shift ;;
    esac
done

# --- frpc ---
FRP_VERSION="0.60.0"
FRP_SERVER_ADDR="${FRP_SERVER_ADDR:-}"
FRP_SERVER_PORT="${FRP_SERVER_PORT:-}"
FRP_TOKEN="${FRP_TOKEN:-}"
FRP_WS_REMOTE_PORT="${FRP_WS_REMOTE_PORT:-}"
FRP_GRPC_REMOTE_PORT="${FRP_GRPC_REMOTE_PORT:-}"
FRP_SKIP="${FRP_SKIP:-0}"

start_time=$(date +%s)

LOG_FILE="/var/log/singbox-installer.log"
TOTAL_STEPS=16
STEP_NO=0

log_message() {
    local type="$1"
    local message="$2"
    local icon color
    case "$type" in
        "INFO")  icon="•"; color="$CY" ;;
        "OK")    icon="✔"; color="$GB" ;;
        "WARN")  icon="!"; color="$YB" ;;
        "ERROR") icon="✘"; color="$RB" ;;
        *)       icon=" "; color="$NC" ;;
    esac
    echo -e "  ${color}${icon}${NC} ${message}"
}

hr() { printf "${DM}  "; printf '─%.0s' {1..54}; printf "${NC}\n"; }

# Judul langkah bernomor: [3/16] Judul
step() {
    STEP_NO=$((STEP_NO + 1))
    echo ""
    echo -e "${CY}[${STEP_NO}/${TOTAL_STEPS}]${NC} ${WB}$1${NC}"
    hr
}

# Judul bagian tanpa nomor (untuk pengaturan awal)
section() {
    echo ""
    echo -e "${MG}▌${NC} ${WB}$1${NC}"
    hr
}

box_line() { printf "${CY}║${NC} %-54s ${CY}║${NC}\n" "$1"; }

banner() {
    echo ""
    echo -e "${CY}╔$(printf '═%.0s' {1..56})╗${NC}"
    box_line ""
    box_line "   SING-BOX  +  HAPROXY  +  FRPC"
    box_line "   Auto Installer - tanpa TLS - custom path"
    box_line ""
    box_line "   Bahan dari: masjeho2/singbox-bot"
    echo -e "${CY}╚$(printf '═%.0s' {1..56})╝${NC}"
}

# Jalankan perintah senyap (output ke log) dengan spinner.
run_quiet() {
    local desc="$1"; shift
    local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    local i=0 rc=0
    "$@" >> "$LOG_FILE" 2>&1 &
    local pid=$!
    if [ -t 1 ]; then
        while kill -0 "$pid" 2>/dev/null; do
            printf "\r  ${CY}%s${NC} %s" "${frames[i % 10]}" "$desc"
            i=$((i + 1))
            sleep 0.1
        done
    fi
    wait "$pid" || rc=$?
    printf "\r\033[K"
    if [ "$rc" -eq 0 ]; then
        log_message "OK" "$desc"
    else
        log_message "ERROR" "${desc} — GAGAL (log: ${LOG_FILE})"
        tail -n 15 "$LOG_FILE" | sed 's/^/      /'
        return "$rc"
    fi
}

svc_status() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        echo -e "${GB}● aktif${NC}"
    else
        echo -e "${RB}● tidak aktif${NC}"
    fi
}

is_pkg_installed() { dpkg -l "$1" 2>/dev/null | grep -q "^ii"; }
is_cmd_installed() { command -v "$1" &>/dev/null; }

# Cek apakah ada terminal untuk input interaktif (stderr TIDAK boleh dibuang di
# perintah read, karena teks prompt dikirim lewat stderr).
have_tty() { { : < /dev/tty; } 2>/dev/null; }

# --- [ INPUT PREFIX PATH ] ---
ask_path_id() {
    # Jika belum diberikan lewat env/argumen, tanyakan ke user.
    if [ -z "$PATH_ID" ]; then
        local saved="$DEFAULT_PATH_ID"
        [ -s "$PATH_ID_FILE" ] && saved="$(cat "$PATH_ID_FILE")"

        local input=""
        section "PENGATURAN"
        echo -e "  ${WB}Prefix path${NC} menentukan URL endpoint semua protokol."
        echo -e "  ${DM}Contoh prefix${NC} ${YB}id-6${NC}  →  ${DM}/id-6/vmess   ·   id-6-vmess-grpc${NC}"
        echo ""
        have_tty && read -rp "$(echo -e "  ${CY}➜${NC} ${WB}Prefix path${NC} ${DM}[${saved}]${NC} : ")" input < /dev/tty || input=""
        PATH_ID="${input:-$saved}"
    fi

    # Bersihkan slash di awal/akhir
    PATH_ID="${PATH_ID#/}"
    PATH_ID="${PATH_ID%/}"

    # Validasi: huruf/angka/_/- saja (aman untuk JSON, haproxy, dan URL)
    if ! [[ "$PATH_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
        log_message "ERROR" "Prefix path '${PATH_ID}' tidak valid. Gunakan huruf, angka, '-' atau '_' saja."
        exit 1
    fi

    log_message "OK" "Prefix path: ${PATH_ID}"
}

mask_token() {
    local t="$1"
    if [ -z "$t" ]; then echo "(belum diisi)"; return; fi
    [ "${#t}" -le 4 ] && { echo "****"; return; }
    echo "${t:0:2}$(printf '*%.0s' $(seq 1 $((${#t} - 4))))${t: -2}"
}

confirm_settings() {
    section "RINGKASAN PENGATURAN"
    printf "  ${DM}%-14s${NC} ${YB}%s${NC}\n" "Prefix path" "$PATH_ID"
    printf "  ${DM}%-14s${NC} /%s/vmess  /%s/vless-ws  /%s/trojan-ws\n" "WebSocket" "$PATH_ID" "$PATH_ID" "$PATH_ID"
    printf "  ${DM}%-14s${NC} %s-vmess-grpc  %s-vless-grpc  %s-trojan-grpc\n" "gRPC" "$PATH_ID" "$PATH_ID" "$PATH_ID"
    if [ "$FRP_SKIP" = "1" ]; then
        printf "  ${DM}%-14s${NC} dilewati\n" "frpc"
    else
        printf "  ${DM}%-14s${NC} %s:%s\n" "frp server" "${FRP_SERVER_ADDR:-(belum diisi)}" "$FRP_SERVER_PORT"
        printf "  ${DM}%-14s${NC} %s\n" "frp token" "$(mask_token "$FRP_TOKEN")"
        printf "  ${DM}%-14s${NC} WS %s  ·  gRPC %s\n" "remote port" "$FRP_WS_REMOTE_PORT" "$FRP_GRPC_REMOTE_PORT"
    fi
    echo ""
    local ans=""
    have_tty && read -rp "$(echo -e "  ${CY}➜${NC} ${WB}Lanjutkan instalasi?${NC} ${DM}[Y/n]${NC} : ")" ans < /dev/tty || ans=""
    if [[ "$ans" =~ ^[Nn]$ ]]; then
        log_message "WARN" "Instalasi dibatalkan."
        exit 0
    fi
}

print_summary() {
    local total_secs="$(($(date +%s) - start_time))"
    echo ""
    echo -e "${GB}╔$(printf '═%.0s' {1..56})╗${NC}"
    printf "${GB}║${NC} %-54s ${GB}║${NC}\n" "   INSTALASI SELESAI  ($((total_secs / 60)) menit $((total_secs % 60)) detik)"
    echo -e "${GB}╚$(printf '═%.0s' {1..56})╝${NC}"

    section "ENDPOINT  ${DM}(prefix: ${PATH_ID})${NC}"
    printf "  ${DM}%-8s %-22s %s${NC}\n" "Protokol" "WebSocket (port 80)" "gRPC (port 8081)"
    printf "  %-8s %-22s %s\n" "VMess"  "/${PATH_ID}/vmess"     "${PATH_ID}-vmess-grpc"
    printf "  %-8s %-22s %s\n" "VLESS"  "/${PATH_ID}/vless-ws"  "${PATH_ID}-vless-grpc"
    printf "  %-8s %-22s %s\n" "Trojan" "/${PATH_ID}/trojan-ws" "${PATH_ID}-trojan-grpc"

    section "STATUS LAYANAN"
    printf "  %-12s %b\n" "sing-box" "$(svc_status sing-box)"
    printf "  %-12s %b\n" "haproxy"  "$(svc_status haproxy)"
    if [ "$FRP_SKIP" != "1" ]; then
        printf "  %-12s %b\n" "frpc" "$(svc_status frpc)"
    fi
    if ss -ltn 2>/dev/null | grep -q ':3030 '; then
        printf "  %-12s %b\n" "api (pm2)" "${GB}● aktif${NC}"
    else
        printf "  %-12s %b\n" "api (pm2)" "${RB}● tidak aktif${NC}"
    fi

    section "FILE PENTING"
    printf "  ${DM}%-14s${NC} %s\n" "sing-box" "/etc/sing-box/config.json"
    printf "  ${DM}%-14s${NC} %s\n" "haproxy" "/etc/haproxy/haproxy.cfg"
    [ "$FRP_SKIP" = "1" ] || printf "  ${DM}%-14s${NC} %s  ${DM}(edit lalu: systemctl restart frpc)${NC}\n" "frpc" "/etc/frp/frpc.toml"
    printf "  ${DM}%-14s${NC} %s\n" "log installer" "$LOG_FILE"
    echo ""
}

# --- [ FIX #1: PAKSA IPv4 UNTUK WGET/CURL/APT ] ---
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
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    : > "$LOG_FILE"
    run_quiet "Memperbarui daftar paket" apt-get update -y
    run_quiet "Upgrade paket sistem (bisa beberapa menit)" \
        apt-get -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef full-upgrade -y
    run_quiet "Membersihkan paket tak terpakai" apt-get autoremove -y
}

install_dependencies() {
    local pkgs=(socat curl wget screen cron netfilter-persistent vnstat fail2ban sysstat jq gnupg software-properties-common tar)
    local missing=() pkg
    for pkg in "${pkgs[@]}"; do
        is_pkg_installed "$pkg" || missing+=("$pkg")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        log_message "OK" "Semua dependensi sudah terpasang"
    else
        run_quiet "Memasang ${#missing[@]} paket: ${missing[*]}" apt-get install -y "${missing[@]}"
    fi
}

setup_directories() {
    log_message "INFO" "Membuat direktori sistem..."
    mkdir -p /etc/haproxy /var/log/sing-box /usr/local/share/sing-box
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
        curl -sSL -o /usr/local/share/sing-box/geoip.dat https://github.com/malikshi/v2ray-rules-dat/releases/latest/download/geoip.dat
        curl -sSL -o /usr/local/share/sing-box/geosite.dat https://github.com/malikshi/v2ray-rules-dat/releases/latest/download/geosite.dat
    fi
}

install_grpcurl() {
    # grpcurl WAJIB ada agar bot bisa query traffic stats Sing-box (V2Ray API / gRPC).
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
    log_message "INFO" "Mencoba install HAProxy dari repo Ubuntu (tanpa PPA)..."
    if apt-get install -y haproxy 2>&1 | tail -3; then
        if is_pkg_installed "haproxy"; then
            log_message "INFO" "HAProxy terinstal dari repo Ubuntu."
            systemctl enable haproxy
            return 0
        fi
    fi

    # Fallback: coba PPA
    log_message "WARN" "Repo Ubuntu tidak menyediakan haproxy, mencoba PPA vbernat/haproxy-2.8..."
    if add-apt-repository ppa:vbernat/haproxy-2.8 -y 2>/dev/null; then
        apt-get update && apt-get install -y "haproxy=2.8.*"
    else
        log_message "ERROR" "Gagal install haproxy (PPA launchpad tidak reachable)."
        log_message "WARN"  "Coba manual: apt-get install haproxy"
    fi
    systemctl enable haproxy
}

# --- [ TULIS CONFIG SING-BOX (user dikosongkan) ] ---
write_singbox_config() {
    log_message "INFO" "Menulis /etc/sing-box/config.json (prefix: ${PATH_ID})..."

    # Backup config lama supaya user yang sudah ada tidak hilang saat install ulang
    if [ -f /etc/sing-box/config.json ]; then
        cp -f /etc/sing-box/config.json "/etc/sing-box/config.json.bak.$(date +%s)"
        log_message "WARN" "Config lama di-backup ke /etc/sing-box/config.json.bak.*"
    fi

    # 'listen' memakai 0.0.0.0 (bukan '::') supaya aman di VPS IPv4-only / IPv6 mati.
    cat > /etc/sing-box/config.json << EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "/var/log/sing-box/access.log",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "dns-local"
      },
      {
        "type": "tcp",
        "tag": "google-tcp",
        "server": "8.8.8.8",
        "server_port": 53
      },
      {
        "type": "udp",
        "tag": "google-udp",
        "server": "8.8.8.8",
        "server_port": 53
      }
    ],
    "strategy": "prefer_ipv4",
    "disable_cache": false,
    "disable_expire": false
  },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "0.0.0.0",
      "listen_port": 10001,
      "users": [],
      "transport": {
        "type": "ws",
        "path": "/${PATH_ID}/vmess",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "vmess",
      "tag": "vmessgrpc-in",
      "listen": "0.0.0.0",
      "listen_port": 20001,
      "users": [],
      "transport": {
        "type": "grpc",
        "service_name": "${PATH_ID}-vmess-grpc",
        "permit_without_stream": false
      }
    },
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "0.0.0.0",
      "listen_port": 10003,
      "users": [],
      "transport": {
        "type": "ws",
        "path": "/${PATH_ID}/trojan-ws"
      }
    },
    {
      "type": "trojan",
      "tag": "trojangrpc-in",
      "listen": "0.0.0.0",
      "listen_port": 20003,
      "users": [],
      "transport": {
        "type": "grpc",
        "service_name": "${PATH_ID}-trojan-grpc",
        "permit_without_stream": false
      }
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": 10002,
      "users": [],
      "transport": {
        "type": "ws",
        "path": "/${PATH_ID}/vless-ws"
      }
    },
    {
      "type": "vless",
      "tag": "vlessgrpc-in",
      "listen": "0.0.0.0",
      "listen_port": 20002,
      "users": [],
      "transport": {
        "type": "grpc",
        "service_name": "${PATH_ID}-vless-grpc",
        "permit_without_stream": false
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "domain": "pagead2.googlesyndication.com",
        "action": "route-options",
        "override_address": "1.1.1.1",
        "override_port": 443
      }
    ],
    "default_domain_resolver": "google-udp",
    "final": "direct",
    "auto_detect_interface": true
  },
  "experimental": {
    "v2ray_api": {
      "listen": "127.0.0.1:8080",
      "stats": {
        "enabled": true,
        "inbounds": [
          "vmess-in",
          "vmessgrpc-in",
          "trojan-in",
          "trojangrpc-in",
          "vless-in",
          "vlessgrpc-in"
        ],
        "outbounds": [
          "direct"
        ],
        "users": []
      }
    },
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "secret": ""
    }
  }
}
EOF

    # Validasi JSON
    if jq empty /etc/sing-box/config.json 2>/dev/null; then
        log_message "INFO" "config.json valid."
    else
        log_message "ERROR" "config.json TIDAK valid JSON! Cek /etc/sing-box/config.json"
        exit 1
    fi
}

# --- [ TULIS CONFIG HAPROXY ] ---
write_haproxy_config() {
    log_message "INFO" "Menulis /etc/haproxy/haproxy.cfg (prefix: ${PATH_ID})..."

    if [ -f /etc/haproxy/haproxy.cfg ]; then
        cp -f /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.bak.$(date +%s)"
    fi

    cat > /etc/haproxy/haproxy.cfg << EOF
global
    log /dev/log local0 notice
    maxconn 100000
    nbthread 4            # 4 thread (sesuai jumlah core CPU)
    cpu-map 1 0           # Thread 1 -> CPU core 0
    cpu-map 2 1           # Thread 2 -> CPU core 1
    cpu-map 3 2           # Thread 3 -> CPU core 2
    cpu-map 4 3           # Thread 4 -> CPU core 3
    tune.ssl.default-dh-param 2048
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode http             # Gunakan mode http untuk WebSocket dan gRPC
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    option http-server-close
    option forwardfor

# --- Frontend gRPC (h2c, tanpa TLS) ---
frontend grpc-in
    bind *:8081 proto h2
    acl is_vless_grpc  path_beg /${PATH_ID}-vless-grpc
    acl is_trojan_grpc path_beg /${PATH_ID}-trojan-grpc
    acl is_vmess_grpc  path_beg /${PATH_ID}-vmess-grpc
    use_backend vless-grpc-backend  if is_vless_grpc
    use_backend trojan-grpc-backend if is_trojan_grpc
    use_backend vmess-grpc-backend  if is_vmess_grpc

# --- Frontend WebSocket + API (HTTP port 80, tanpa TLS) ---
frontend http-in
    bind *:80

    # ACL untuk routing WebSocket
    acl is_vmess path_beg /${PATH_ID}/vmess
    use_backend vmess-backend if is_vmess

    acl is_vless path_beg /${PATH_ID}/vless-ws
    use_backend vless-backend if is_vless

    acl is_trojan path_beg /${PATH_ID}/trojan-ws
    use_backend trojan-backend if is_trojan

    # ACL untuk routing Bot Management API
    acl is_bot_api path_beg /api
    use_backend api_backend if is_bot_api

# --- Backend untuk WebSocket ---
backend vmess-backend
    server vmess-server 127.0.0.1:10001 check

backend vless-backend
    server vless-server 127.0.0.1:10002 check

backend trojan-backend
    server trojan-server 127.0.0.1:10003 check

# --- Backend untuk Bot Management API ---
backend api_backend
    mode http
    server api_server_1 127.0.0.1:3030 check

# --- Backend untuk gRPC ---
backend vmess-grpc-backend
    mode http
    server vmess-grpc-server 127.0.0.1:20001 proto h2 check

backend vless-grpc-backend
    mode http
    server vless-grpc-server 127.0.0.1:20002 proto h2 check

backend trojan-grpc-backend
    mode http
    server trojan-grpc-server 127.0.0.1:20003 proto h2 check
EOF

    if command -v haproxy >/dev/null 2>&1; then
        if haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
            log_message "INFO" "haproxy.cfg valid."
        else
            log_message "WARN" "haproxy -c melaporkan masalah (mis. nbthread/cpu-map > jumlah core CPU). Cek: haproxy -c -f /etc/haproxy/haproxy.cfg"
        fi
    fi
}

# --- [ FRPC ] ---
prompt_value() {
    # prompt_value <var_name> <label> <default>
    local __var="$1" __label="$2" __def="$3" __in="" __hint
    if [ -n "${!__var}" ]; then return 0; fi
    if [ -n "$__def" ]; then
        __hint="${DM}[${__def}]${NC}"
    else
        __hint="${DM}(Enter = isi nanti)${NC}"
    fi
    have_tty && read -rp "$(echo -e "  ${CY}➜${NC} ${WB}$(printf '%-28s' "$__label")${NC} ${__hint} : ")" __in < /dev/tty || __in=""
    printf -v "$__var" '%s' "${__in:-$__def}"
}

is_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

ask_frpc_config() {
    if [ "$FRP_SKIP" = "1" ]; then
        log_message "INFO" "frpc dilewati (--no-frp)."
        return 0
    fi

    section "KONFIGURASI FRPC  ${DM}(tunnel ke server FRP)${NC}"
    prompt_value FRP_SERVER_ADDR      "Server address (IP/domain)" ""
    prompt_value FRP_SERVER_PORT      "Server port"                "7000"
    prompt_value FRP_TOKEN            "Auth token"                 ""
    prompt_value FRP_WS_REMOTE_PORT   "Remote port WebSocket"      "8443"
    prompt_value FRP_GRPC_REMOTE_PORT "Remote port gRPC"           "8445"
    echo -e "  ${DM}(WebSocket → lokal :80  ·  gRPC → lokal :8081, mengikuti HAProxy)${NC}"

    local v
    for v in FRP_SERVER_PORT FRP_WS_REMOTE_PORT FRP_GRPC_REMOTE_PORT; do
        if ! is_port "${!v}"; then
            log_message "ERROR" "${v}='${!v}' bukan port valid (1-65535)."
            exit 1
        fi
    done
}

install_frpc() {
    [ "$FRP_SKIP" = "1" ] && return 0

    if is_cmd_installed "frpc"; then
        log_message "INFO" "frpc sudah terinstal, dilewati."
    else
        log_message "INFO" "Menginstal frpc v${FRP_VERSION}..."
        local arch
        case "$(uname -m)" in
            x86_64)  arch="amd64" ;;
            aarch64) arch="arm64" ;;
            armv7l)  arch="arm" ;;
            *)
                log_message "WARN" "Arsitektur $(uname -m) tidak dikenal, mencoba amd64..."
                arch="amd64"
                ;;
        esac

        local name="frp_${FRP_VERSION}_linux_${arch}"
        local url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${name}.tar.gz"
        local tmp_dir
        tmp_dir="$(mktemp -d)"

        if curl -fsSL -o "${tmp_dir}/frp.tar.gz" "$url" \
           && tar -xzf "${tmp_dir}/frp.tar.gz" -C "$tmp_dir" \
           && [ -f "${tmp_dir}/${name}/frpc" ]; then
            cp "${tmp_dir}/${name}/frpc" /usr/local/bin/frpc
            chmod +x /usr/local/bin/frpc
            rm -rf "$tmp_dir"
            log_message "INFO" "frpc terinstal: $(frpc -v 2>&1 | head -n1)"
        else
            rm -rf "$tmp_dir"
            log_message "ERROR" "Gagal download/ekstrak frpc dari ${url}"
            return 0
        fi
    fi

    mkdir -p /etc/frp
    write_frpc_config

    cat > /etc/systemd/system/frpc.service << 'EOF'
[Unit]
Description=frp client (frpc)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.toml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable frpc.service >/dev/null 2>&1 || true
}

write_frpc_config() {
    local addr="${FRP_SERVER_ADDR:-IP_SERVER_FRP}"
    local token="${FRP_TOKEN:-GANTI_TOKEN}"
    # escape \ dan " untuk string TOML
    addr="${addr//\\/\\\\}";   addr="${addr//\"/\\\"}"
    token="${token//\\/\\\\}"; token="${token//\"/\\\"}"

    if [ -f /etc/frp/frpc.toml ]; then
        cp -f /etc/frp/frpc.toml "/etc/frp/frpc.toml.bak.$(date +%s)"
    fi

    cat > /etc/frp/frpc.toml << EOF
serverAddr = "${addr}"
serverPort = ${FRP_SERVER_PORT:-7000}
auth.method = "token"
auth.token = "${token}"

# Mengikuti HAProxy: WS di :80, gRPC di :8081
[[proxies]]
name = "websocket"
type = "tcp"
localIP = "127.0.0.1"
localPort = 80
remotePort = ${FRP_WS_REMOTE_PORT:-8443}

[[proxies]]
name = "grpc"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8081
remotePort = ${FRP_GRPC_REMOTE_PORT:-8445}
EOF
    chmod 600 /etc/frp/frpc.toml
    log_message "INFO" "Config frpc ditulis di /etc/frp/frpc.toml"
}

start_frpc() {
    [ "$FRP_SKIP" = "1" ] && return 0
    is_cmd_installed "frpc" || return 0

    if [ -z "$FRP_SERVER_ADDR" ] || [ -z "$FRP_TOKEN" ]; then
        log_message "WARN" "serverAddr/token frpc belum diisi — frpc TIDAK dijalankan."
        log_message "WARN" "Edit /etc/frp/frpc.toml lalu: systemctl restart frpc"
        return 0
    fi
    systemctl restart frpc.service
    sleep 1
    if systemctl is-active --quiet frpc.service; then
        log_message "OK" "frpc berjalan (WS remote:${FRP_WS_REMOTE_PORT}, gRPC remote:${FRP_GRPC_REMOTE_PORT})"
    else
        log_message "ERROR" "frpc gagal start. Cek: journalctl -u frpc -n 30"
    fi
}

save_path_id() {
    # Simpan prefix supaya install ulang / tool lain bisa membacanya
    echo "$PATH_ID" > "$PATH_ID_FILE"
    log_message "INFO" "Prefix path disimpan di ${PATH_ID_FILE}"
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
    if ! command -v node >/dev/null 2>&1; then
        log_message "INFO" "Node.js belum terinstal. Menginstal Node.js..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
        \. "$HOME/.nvm/nvm.sh"
        nvm install 24
        npm -v
        log_message "INFO" "Node.js berhasil diinstal."
    else
        log_message "INFO" "Node.js sudah terinstal."
    fi

    # Pastikan nvm ter-source di shell non-login (installer jalan via setsid)
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    # Symlink node/npm ke global PATH supaya systemd/PM2/panel-bot bisa nemu
    local NODE_BIN
    NODE_BIN="$(dirname "$(command -v node 2>/dev/null)")"
    if [ -n "$NODE_BIN" ] && [ -x "$NODE_BIN/node" ]; then
        ln -sf "$NODE_BIN/node" /usr/local/bin/node
        ln -sf "$NODE_BIN/npm"  /usr/local/bin/npm
    fi

    # Install PM2 global kalau belum ada
    if ! command -v pm2 >/dev/null 2>&1; then
        log_message "INFO" "PM2 belum terinstal. Menginstal PM2..."
        npm install -g pm2
        if [ -n "$NODE_BIN" ] && [ -x "$NODE_BIN/pm2" ]; then
            ln -sf "$NODE_BIN/pm2" /usr/local/bin/pm2
        fi
        log_message "INFO" "PM2 berhasil diinstal."
    else
        log_message "INFO" "PM2 sudah terinstal."
    fi
}

setup_tools() {
    log_message "INFO" "Menyiapkan tools tambahan..."
    # menu, dns, certsing-box
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

setup_cronjobs() {
    log_message "INFO" "Menambahkan cron job untuk membersihkan log..."
    # Hindari duplikat saat install ulang
    if ! grep -q "truncate -s 0 /var/log/sing-box/access.log" /etc/crontab 2>/dev/null; then
        echo "*/10 * * * * root truncate -s 0 /var/log/sing-box/access.log" >> /etc/crontab
    fi
    log_message "INFO" "Cron job untuk log berhasil ditambahkan."
}

verify_installation() {
    log_message "INFO" "Memverifikasi instalasi komponen kritis..."
    local all_ok=true

    if is_cmd_installed "sing-box"; then
        log_message "OK" "sing-box terinstal: $(sing-box version 2>&1 | head -n1)"
    else
        log_message "ERROR" "sing-box TIDAK terinstal."
        all_ok=false
    fi

    if is_cmd_installed "grpcurl"; then
        log_message "OK" "grpcurl terinstal: $(grpcurl -version 2>&1)"
    else
        log_message "ERROR" "grpcurl TIDAK terinstal — kuota tidak akan berfungsi!"
        all_ok=false
    fi

    if is_cmd_installed "haproxy"; then
        log_message "OK" "haproxy terinstal."
    else
        log_message "ERROR" "haproxy TIDAK terinstal."
        all_ok=false
    fi

    if [ "$FRP_SKIP" != "1" ]; then
        if is_cmd_installed "frpc"; then
            log_message "OK" "frpc terinstal."
        else
            log_message "WARN" "frpc belum terinstal."
        fi
    fi

    if [ -f /root/protos/app/stats/command/command.proto ]; then
        log_message "OK" "Proto file untuk stats sudah ada."
    else
        log_message "ERROR" "Proto file TIDAK lengkap di /root/protos."
        all_ok=false
    fi

    if [ -f "/root/api/api-server.js" ]; then
        log_message "OK" "API server terinstal di /root/api/"
    else
        log_message "ERROR" "API server TIDAK terinstal."
        all_ok=false
    fi

    if [ -d "/root/api/node_modules" ]; then
        log_message "OK" "API npm dependencies terinstall"
    else
        log_message "WARN" "API npm dependencies belum terinstall"
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
    start_frpc

    # Pastikan nvm + pm2 ke-source (installer jalan via setsid, non-login shell)
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    # Matikan systemd singbox-api lama kalau ada (konflik port 3030)
    systemctl stop singbox-api 2>/dev/null || true
    systemctl disable singbox-api 2>/dev/null || true

    if command -v pm2 >/dev/null 2>&1; then
        log_message "INFO" "Memulai API server via PM2..."
        pm2 delete api >/dev/null 2>&1 || true
        cd /root/api && pm2 start api-server.js --name api 2>&1 | tail -5
        pm2 save 2>/dev/null
        pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true
        log_message "OK" "API server berjalan via PM2"
    else
        log_message "WARN" "PM2 tidak ditemukan, API server tidak di-start otomatis"
    fi

}

# --- [ EKSEKUSI UTAMA ] ---
main() {
    clear 2>/dev/null || true
    banner

    # Semua pertanyaan di awal, supaya sisanya jalan otomatis tanpa ditunggu
    ask_path_id
    ask_frpc_config
    confirm_settings

    step "Memaksa koneksi IPv4";               force_ipv4
    step "Memperbarui sistem";                 update_system
    step "Memasang dependensi";                install_dependencies
    step "Menyiapkan direktori";               setup_directories; save_path_id
    step "Memasang sing-box";                  download_and_setup_singbox
    step "Memasang grpcurl";                   install_grpcurl
    step "Memasang HAProxy";                   install_haproxy
    step "Menulis config sing-box";            write_singbox_config
    step "Menulis config HAProxy";             write_haproxy_config
    step "Memasang frpc";                      install_frpc
    step "Tuning jaringan (BBR)";              tune_system_performance
    step "Memasang Node.js & PM2";             install_nodejs
    step "Menyiapkan tools & API server";      setup_tools
    step "Menambahkan cron job";               setup_cronjobs
    step "Verifikasi komponen";                verify_installation
    step "Menjalankan layanan";                finalize_installation

    print_summary

    local answer=""
    have_tty && read -rp "$(echo -e "  ${CY}➜${NC} ${WB}Reboot VPS sekarang?${NC} ${DM}[y/N]${NC} : ")" answer < /dev/tty || answer=""
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# Jalankan skrip (set INSTALL_SOURCE_ONLY=1 untuk hanya me-load fungsi, mis. untuk testing)
if [ -z "${INSTALL_SOURCE_ONLY:-}" ]; then
    main
fi
