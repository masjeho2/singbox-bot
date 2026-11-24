#!/bin/bash
# =================================================================
# Skrip Instalasi Server sing-box & HAProxy (TLS opsional)
# Sumber Bahan: https://github.com/masjeho2/singbox-bot
#
# PERUBAHAN:
#  - Prefix path (contoh: id-6) bisa diatur: lewat prompt, env PATH_ID,
#    atau argumen:  bash install.sh --path id-7
#  - config.json (sing-box) & haproxy.cfg ditulis langsung di skrip ini
#    (tidak lagi download dari GitHub). User dibiarkan kosong.
#  - TLS opsional di HAProxy (port 443). Kalau ON: minta domain, terbitkan
#    sertifikat Let's Encrypt (acme.sh, auto-renew) lalu buka port 443.
#    Kalau OFF: tidak minta domain & tidak menerbitkan sertifikat.
#    Opsi:  --tls --domain sub.domain.com   |   --no-tls
#    (atau env TLS_ENABLE=1/0 dan DOMAIN=...)
#  - Tipe VPS dipilih di awal:
#      NAT        -> frpc dipasang, gRPC di port 8081 (diteruskan frpc)
#      IP publik  -> TANPA frpc, port 8081 dihapus, gRPC (h2c) digabung ke
#                    port 80 bersama WebSocket; TLS otomatis ON (gRPC via 443).
#                    Opsi: --nat | --public
#                    (atau env VPS_TYPE=nat|public)
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
        --nat)             VPS_TYPE=nat; shift ;;
        --public)          VPS_TYPE=public; shift ;;
        --tls)             TLS_ENABLE=1; shift ;;
        --no-tls)          TLS_ENABLE=0; shift ;;
        --domain)          DOMAIN="$2"; shift 2 ;;
        --domain=*)        DOMAIN="${1#*=}"; shift ;;
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

# --- Tipe VPS (kosong = tanya): nat | public ---
VPS_TYPE="${VPS_TYPE:-}"

# --- TLS (kosong = tanya, 1 = aktif, 0 = nonaktif) ---
TLS_ENABLE="${TLS_ENABLE:-}"
DOMAIN="${DOMAIN:-}"
ACME_BIN="$HOME/.acme.sh/acme.sh"

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
    box_line "   Auto Installer - TLS opsional - custom path"
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

# --- [ TIPE VPS: NAT / IP PUBLIK ] ---
ask_vps_type() {
    case "${VPS_TYPE,,}" in
        nat|1)            VPS_TYPE="nat" ;;
        public|publik|2)  VPS_TYPE="public" ;;
        *)                VPS_TYPE="" ;;
    esac

    if [ -z "$VPS_TYPE" ]; then
        section "TIPE VPS"
        echo -e "  ${WB}1)${NC} ${YB}NAT${NC}        ${DM}- pakai frpc; gRPC di port 8081 (diteruskan frpc)${NC}"
        echo -e "  ${WB}2)${NC} ${GB}IP publik${NC}  ${DM}- tanpa frpc; port 8081 dihapus; TLS otomatis ON (gRPC via 443)${NC}"
        echo ""
        local ans=""
        have_tty && read -rp "$(echo -e "  ${CY}➜${NC} ${WB}Pilih tipe VPS${NC} ${DM}[1/2, default 1]${NC} : ")" ans < /dev/tty || ans=""
        case "$ans" in
            2) VPS_TYPE="public" ;;
            *) VPS_TYPE="nat" ;;
        esac
    fi

    if [ "$VPS_TYPE" = "public" ]; then
        FRP_SKIP=1   # IP publik: frpc tidak diperlukan
        log_message "OK" "Tipe VPS: IP publik (tanpa frpc, TLS otomatis, gRPC via 443)"
    else
        log_message "OK" "Tipe VPS: NAT (frpc, gRPC di port 8081)"
    fi
}

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

# --- [ TLS: PILIHAN & DOMAIN ] ---
is_domain() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; }

ask_tls() {
    # Normalisasi nilai env/argumen: y/yes/true/on/1 -> 1 ; n/no/false/off/0 -> 0
    case "${TLS_ENABLE,,}" in
        1|y|yes|true|on) TLS_ENABLE=1 ;;
        0|n|no|false|off) TLS_ENABLE=0 ;;
        *) TLS_ENABLE="" ;;
    esac

    # VPS IP publik: TLS otomatis aktif (gRPC lewat port 443), tanpa ditanya.
    # (--no-tls tetap dihormati kalau diberikan eksplisit)
    if [ "$VPS_TYPE" = "public" ]; then
        if [ -z "$TLS_ENABLE" ]; then
            TLS_ENABLE=1
            log_message "INFO" "VPS IP publik: TLS diaktifkan otomatis (gRPC lewat port 443)."
        elif [ "$TLS_ENABLE" = "0" ]; then
            log_message "WARN" "VPS IP publik tanpa TLS: gRPC hanya via h2c di port 80."
        fi
    fi

    # --domain tanpa --tls dianggap TLS aktif
    if [ -z "$TLS_ENABLE" ] && [ -n "$DOMAIN" ]; then
        TLS_ENABLE=1
    fi

    if [ -z "$TLS_ENABLE" ]; then
        section "TLS  ${DM}(HTTPS port 443)${NC}"
        echo -e "  ${GB}ON ${NC} : minta domain, terbitkan sertifikat (Let's Encrypt), buka port 443."
        echo -e "  ${RB}OFF${NC} : tanpa domain & sertifikat (hanya port 80 / 8081)."
        echo ""
        local ans=""
        have_tty && read -rp "$(echo -e "  ${CY}➜${NC} ${WB}Aktifkan TLS?${NC} ${DM}[y/N]${NC} : ")" ans < /dev/tty || ans=""
        if [[ "$ans" =~ ^[Yy]$ ]]; then TLS_ENABLE=1; else TLS_ENABLE=0; fi
    fi

    if [ "$TLS_ENABLE" != "1" ]; then
        TLS_ENABLE=0
        DOMAIN=""
        return 0
    fi

    DOMAIN="${DOMAIN,,}"
    until is_domain "$DOMAIN"; do
        if [ -n "$DOMAIN" ]; then
            log_message "WARN" "Domain '${DOMAIN}' tidak valid."
        fi
        if ! have_tty; then
            log_message "ERROR" "TLS aktif tapi domain tidak valid/kosong. Gunakan --domain sub.domain.com (atau --no-tls)"
            exit 1
        fi
        echo ""
        echo -e "  ${DM}Domain/subdomain harus sudah diarahkan (A record) ke VPS ini,${NC}"
        echo -e "  ${DM}dan port 80 harus bisa dijangkau dari internet untuk verifikasi.${NC}"
        read -rp "$(echo -e "  ${CY}➜${NC} ${WB}Domain/subdomain VPS${NC} : ")" DOMAIN < /dev/tty || DOMAIN=""
        DOMAIN="${DOMAIN,,}"
    done
    log_message "OK" "TLS aktif, domain: ${DOMAIN}"
}

acme_issue() {
    local rc=0
    "$ACME_BIN" --set-default-ca --server letsencrypt || true
    "$ACME_BIN" --issue -d "$DOMAIN" --server letsencrypt --keylength ec-256 --standalone \
        --pre-hook "systemctl stop haproxy 2>/dev/null || true" \
        --post-hook "systemctl start haproxy 2>/dev/null || true" || rc=$?
    # 2 = sertifikat masih berlaku (belum waktunya diperbarui) -> tetap sukses
    [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]
}

acme_install() {
    "$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file /etc/sing-box/fullchain.crt \
        --key-file /etc/sing-box/private.key \
        --reloadcmd "cat /etc/sing-box/fullchain.crt /etc/sing-box/private.key > /etc/haproxy/certs/domain.pem && chmod 600 /etc/haproxy/certs/domain.pem && (systemctl reload haproxy 2>/dev/null || true)"
}

install_acme() {
    curl -fsSL https://get.acme.sh | sh
}

# Jika ufw aktif: buka port 80 (dan 443 bila TLS) untuk VPS IP publik / TLS.
open_firewall() {
    [ "$VPS_TYPE" = "public" ] || [ "$TLS_ENABLE" = "1" ] || return 0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 80/tcp >/dev/null 2>&1 || true
        [ "$TLS_ENABLE" != "1" ] || ufw allow 443/tcp >/dev/null 2>&1 || true
        log_message "INFO" "ufw aktif: port 80$([ "$TLS_ENABLE" = "1" ] && echo " & 443") dibuka."
    fi
}

issue_tls_cert() {
    [ "$TLS_ENABLE" = "1" ] || return 0

    mkdir -p /etc/haproxy/certs /etc/sing-box

    # Port 80 harus bebas untuk verifikasi standalone
    systemctl stop haproxy 2>/dev/null || true

    local ok=1
    if [ ! -x "$ACME_BIN" ]; then
        run_quiet "Memasang acme.sh" install_acme || ok=0
    fi
    if [ "$ok" = "1" ]; then
        run_quiet "Menerbitkan sertifikat untuk ${DOMAIN}" acme_issue || ok=0
    fi
    if [ "$ok" = "1" ]; then
        run_quiet "Memasang sertifikat ke HAProxy" acme_install || ok=0
    fi
    if [ "$ok" = "1" ] && [ -s /etc/sing-box/fullchain.crt ] && [ -s /etc/sing-box/private.key ]; then
        cat /etc/sing-box/fullchain.crt /etc/sing-box/private.key > /etc/haproxy/certs/domain.pem
        chmod 600 /etc/haproxy/certs/domain.pem /etc/sing-box/private.key
        echo "$DOMAIN" > /etc/sing-box/domain
        log_message "OK" "Sertifikat siap: /etc/haproxy/certs/domain.pem (auto-renew aktif)"
    else
        TLS_ENABLE=0
        log_message "ERROR" "Gagal menerbitkan sertifikat untuk ${DOMAIN}."
        log_message "WARN"  "Cek: A record domain ke IP VPS & port 80 terbuka dari internet."
        log_message "WARN"  "Instalasi DILANJUTKAN tanpa TLS. Ulangi nanti dengan: --tls --domain ${DOMAIN}"
    fi
}

confirm_settings() {
    section "RINGKASAN PENGATURAN"
    if [ "$VPS_TYPE" = "public" ]; then
        printf "  ${DM}%-14s${NC} ${GB}IP publik${NC}  ${DM}(tanpa frpc, TLS otomatis, gRPC via 443)${NC}\n" "Tipe VPS"
    else
        printf "  ${DM}%-14s${NC} ${YB}NAT${NC}  ${DM}(frpc, gRPC di port 8081)${NC}\n" "Tipe VPS"
    fi
    printf "  ${DM}%-14s${NC} ${YB}%s${NC}\n" "Prefix path" "$PATH_ID"
    printf "  ${DM}%-14s${NC} /%s/vmess  /%s/vless-ws  /%s/trojan-ws\n" "WebSocket" "$PATH_ID" "$PATH_ID" "$PATH_ID"
    printf "  ${DM}%-14s${NC} %s-vmess-grpc  %s-vless-grpc  %s-trojan-grpc\n" "gRPC" "$PATH_ID" "$PATH_ID" "$PATH_ID"
    if [ "$TLS_ENABLE" = "1" ]; then
        printf "  ${DM}%-14s${NC} ${GB}ON${NC}  ·  domain ${YB}%s${NC}  ·  port 443\n" "TLS" "$DOMAIN"
    else
        printf "  ${DM}%-14s${NC} OFF  ${DM}(tanpa domain & sertifikat)${NC}\n" "TLS"
    fi
    if [ "$VPS_TYPE" = "public" ]; then
        printf "  ${DM}%-14s${NC} tidak dipasang (IP publik)\n" "frpc"
    elif [ "$FRP_SKIP" = "1" ]; then
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
    printf "  ${DM}%-8s %-22s %s${NC}\n" "Protokol" "WebSocket" "gRPC"
    printf "  %-8s %-22s %s\n" "VMess"  "/${PATH_ID}/vmess"     "${PATH_ID}-vmess-grpc"
    printf "  %-8s %-22s %s\n" "VLESS"  "/${PATH_ID}/vless-ws"  "${PATH_ID}-vless-grpc"
    printf "  %-8s %-22s %s\n" "Trojan" "/${PATH_ID}/trojan-ws" "${PATH_ID}-trojan-grpc"
    echo ""
    if [ "$VPS_TYPE" = "public" ]; then
        printf "  ${DM}%-8s${NC} 80  ${DM}(WS + gRPC h2c, tanpa TLS)${NC}\n" "Port"
    else
        printf "  ${DM}%-8s${NC} WS %s  ·  gRPC %s  ${DM}(tanpa TLS)${NC}\n" "Port" "80" "8081"
    fi
    if [ "$TLS_ENABLE" = "1" ]; then
        printf "  ${DM}%-8s${NC} WS + gRPC lewat ${GB}443${NC} (TLS)  ·  domain ${YB}%s${NC}\n" "TLS" "$DOMAIN"
    fi

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
    if [ "$TLS_ENABLE" = "1" ]; then
        printf "  ${DM}%-14s${NC} %s  ${DM}(auto-renew via acme.sh)${NC}\n" "sertifikat" "/etc/haproxy/certs/domain.pem"
    fi
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

fetch_singbox_files() {
    wget -q -O /usr/bin/sing-box "${REPO_URL}/sing-box"
    chmod +x /usr/bin/sing-box
    wget -q -O /etc/systemd/system/sing-box.service "${REPO_URL}/sing-box.service"
}

fetch_geo_files() {
    curl -fsSL -o /usr/local/share/sing-box/geoip.dat https://github.com/malikshi/v2ray-rules-dat/releases/latest/download/geoip.dat
    curl -fsSL -o /usr/local/share/sing-box/geosite.dat https://github.com/malikshi/v2ray-rules-dat/releases/latest/download/geosite.dat
}

download_and_setup_singbox() {
    run_quiet "Mengunduh binary & service sing-box" fetch_singbox_files
    systemctl daemon-reload
    systemctl enable sing-box.service >/dev/null 2>&1

    if [ ! -f /usr/local/share/sing-box/geoip.dat ]; then
        run_quiet "Mengunduh GeoIP & GeoSite rules" fetch_geo_files
    fi
}

fetch_grpcurl() {
    local url="$1" tarball="$2" tmp_dir rc=0
    tmp_dir="$(mktemp -d)"
    {
        curl -fsSL -o "${tmp_dir}/${tarball}" "$url" \
        && tar -xzf "${tmp_dir}/${tarball}" -C "$tmp_dir" \
        && mv "${tmp_dir}/grpcurl" /usr/local/bin/grpcurl \
        && chmod +x /usr/local/bin/grpcurl
    } || rc=$?
    rm -rf "$tmp_dir"
    return "$rc"
}

install_grpcurl() {
    # grpcurl WAJIB ada agar bot bisa query traffic stats Sing-box (V2Ray API / gRPC).
    if is_cmd_installed "grpcurl"; then
        log_message "OK" "grpcurl sudah terinstal, dilewati."
        return 0
    fi

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

    local tarball="grpcurl_${GRPCURL_VERSION}_linux_${arch}.tar.gz"
    local download_url="https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/${tarball}"

    if run_quiet "Memasang grpcurl v${GRPCURL_VERSION} (untuk tracking kuota)" fetch_grpcurl "$download_url" "$tarball"; then
        :
    else
        log_message "WARN" "Sistem kuota TIDAK akan berfungsi tanpa grpcurl."
        log_message "WARN" "Install manual nanti: ${download_url}"
    fi
}

add_haproxy_ppa() {
    add-apt-repository ppa:vbernat/haproxy-2.8 -y
    apt-get update
    apt-get install -y "haproxy=2.8.*"
}

install_haproxy() {
    ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
    if is_pkg_installed "haproxy"; then
        log_message "OK" "HAProxy sudah terinstal, dilewati."
        systemctl enable haproxy >/dev/null 2>&1
        return 0
    fi

    # --- [ FIX #2: SKIP PPA LAUNCHPAD JIKA REPO UDAH PUNYA HAPROXY ] ---
    # Repo Ubuntu 22.04/24.04 sudah punya HAProxy 2.4+/2.8+; PPA hanya fallback.
    if run_quiet "Memasang HAProxy (repo Ubuntu)" apt-get install -y haproxy && is_pkg_installed "haproxy"; then
        systemctl enable haproxy >/dev/null 2>&1
        return 0
    fi

    log_message "WARN" "Repo Ubuntu gagal, mencoba PPA vbernat/haproxy-2.8..."
    if run_quiet "Memasang HAProxy (PPA vbernat)" add_haproxy_ppa; then
        systemctl enable haproxy >/dev/null 2>&1
    else
        log_message "ERROR" "Gagal install HAProxy. Coba manual: apt-get install haproxy"
    fi
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

    # Thread & cpu-map mengikuti jumlah core CPU VPS (di VPS 4 core hasilnya sama
    # dengan config contoh: nbthread 4 + cpu-map 1..4). Aman untuk VPS 1-2 core.
    local cores i cpu_map=""
    cores="$(nproc 2>/dev/null || echo 1)"
    if [ "$cores" -gt 64 ]; then cores=64; fi
    for ((i = 1; i <= cores; i++)); do
        cpu_map+="    cpu-map ${i} $((i - 1))           # Thread ${i} -> CPU core $((i - 1))"$'\n'
    done

    # NAT       : gRPC di frontend terpisah (port 8081, h2c) -> diteruskan frpc
    # IP publik : tanpa port 8081; ACL gRPC digabung ke frontend http-in (port 80).
    #             HAProxy mendeteksi HTTP/2 cleartext (h2c) otomatis di port 80,
    #             jadi WebSocket (HTTP/1.1) dan gRPC (h2c) berbagi satu port.
    #             Dengan TLS (default utk IP publik), gRPC juga lewat port 443.
    local grpc_frontend="" http_grpc_rules=""
    if [ "$VPS_TYPE" = "public" ]; then
        http_grpc_rules="
    # ACL untuk routing gRPC (h2c) - digabung di port 80
    acl is_vless_grpc  path_beg /${PATH_ID}-vless-grpc
    acl is_trojan_grpc path_beg /${PATH_ID}-trojan-grpc
    acl is_vmess_grpc  path_beg /${PATH_ID}-vmess-grpc
    use_backend vless-grpc-backend  if is_vless_grpc
    use_backend trojan-grpc-backend if is_trojan_grpc
    use_backend vmess-grpc-backend  if is_vmess_grpc
"
    else
        grpc_frontend="# --- Frontend gRPC (h2c, tanpa TLS, port 8081) ---
frontend grpc-in
    bind *:8081 proto h2
    acl is_vless_grpc  path_beg /${PATH_ID}-vless-grpc
    acl is_trojan_grpc path_beg /${PATH_ID}-trojan-grpc
    acl is_vmess_grpc  path_beg /${PATH_ID}-vmess-grpc
    use_backend vless-grpc-backend  if is_vless_grpc
    use_backend trojan-grpc-backend if is_trojan_grpc
    use_backend vmess-grpc-backend  if is_vmess_grpc
"
    fi

    cat > /etc/haproxy/haproxy.cfg << EOF
global
    log /dev/log local0 notice
    maxconn 100000
    nbthread ${cores}            # sesuai jumlah core CPU (${cores} core terdeteksi)
${cpu_map}    tune.ssl.default-dh-param 2048
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode http
    timeout connect 5s
    timeout client 1h
    timeout server 1h
    timeout tunnel 1h
    timeout http-request 10s
    timeout http-keep-alive 10s
    option http-keep-alive
    option forwardfor

${grpc_frontend}
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
${http_grpc_rules}
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

    if [ "$TLS_ENABLE" = "1" ]; then
        log_message "INFO" "Menambahkan frontend HTTPS (port 443, domain ${DOMAIN})..."
        cat >> /etc/haproxy/haproxy.cfg << EOF

# --- Frontend HTTPS (TLS, port 443): WebSocket + gRPC + API ---
# gRPC butuh HTTP/2 -> ALPN h2; WebSocket memakai http/1.1 (dipilih otomatis klien)
frontend https-in
    bind *:443 ssl crt /etc/haproxy/certs/domain.pem alpn h2,http/1.1 ssl-min-ver TLSv1.2

    acl is_vmess       path_beg /${PATH_ID}/vmess
    acl is_vless       path_beg /${PATH_ID}/vless-ws
    acl is_trojan      path_beg /${PATH_ID}/trojan-ws
    acl is_vmess_grpc  path_beg /${PATH_ID}-vmess-grpc
    acl is_vless_grpc  path_beg /${PATH_ID}-vless-grpc
    acl is_trojan_grpc path_beg /${PATH_ID}-trojan-grpc
    acl is_bot_api     path_beg /api

    use_backend vmess-backend       if is_vmess
    use_backend vless-backend       if is_vless
    use_backend trojan-backend      if is_trojan
    use_backend vmess-grpc-backend  if is_vmess_grpc
    use_backend vless-grpc-backend  if is_vless_grpc
    use_backend trojan-grpc-backend if is_trojan_grpc
    use_backend api_backend         if is_bot_api
EOF
    fi

    if command -v haproxy >/dev/null 2>&1; then
        if haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
            log_message "INFO" "haproxy.cfg valid."
        else
            log_message "WARN" "haproxy -c melaporkan masalah . Cek: haproxy -c -f /etc/haproxy/haproxy.cfg"
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
        [ "$VPS_TYPE" = "public" ] || log_message "INFO" "frpc dilewati (--no-frp)."
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

fetch_frpc() {
    local url="$1" name="$2" tmp_dir rc=0
    tmp_dir="$(mktemp -d)"
    {
        curl -fsSL -o "${tmp_dir}/frp.tar.gz" "$url" \
        && tar -xzf "${tmp_dir}/frp.tar.gz" -C "$tmp_dir" \
        && cp "${tmp_dir}/${name}/frpc" /usr/local/bin/frpc \
        && chmod +x /usr/local/bin/frpc
    } || rc=$?
    rm -rf "$tmp_dir"
    return "$rc"
}

install_frpc() {
    [ "$FRP_SKIP" = "1" ] && return 0

    if is_cmd_installed "frpc"; then
        log_message "OK" "frpc sudah terinstal, dilewati."
    else
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

        if run_quiet "Memasang frpc v${FRP_VERSION}" fetch_frpc "$url" "$name"; then
            log_message "OK" "frpc terinstal: $(frpc -v 2>&1 | head -n1)"
        else
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
name = "websocket-${PATH_ID}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 80
remotePort = ${FRP_WS_REMOTE_PORT:-8443}

[[proxies]]
name = "grpc-${PATH_ID}"
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

install_node_nvm() {
    set +e
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    . "$NVM_DIR/nvm.sh"
    nvm install 24
}

install_nodejs() {
    if ! command -v node >/dev/null 2>&1; then
        run_quiet "Memasang Node.js 24 (via nvm, bisa beberapa menit)" install_node_nvm
    else
        log_message "OK" "Node.js sudah terinstal ($(node -v 2>/dev/null))."
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
        run_quiet "Memasang PM2" npm install -g pm2
        if [ -n "$NODE_BIN" ] && [ -x "$NODE_BIN/pm2" ]; then
            ln -sf "$NODE_BIN/pm2" /usr/local/bin/pm2
        fi
    else
        log_message "OK" "PM2 sudah terinstal."
    fi
}

fetch_tools() {
    # menu, dns, certsing-box
    wget -q -O /usr/bin/menu "https://raw.githubusercontent.com/masjeho2/v1/refs/heads/sing-box/menu/menu.sh"
    chmod +x /usr/bin/menu
    wget -q -O /usr/bin/dns "https://raw.githubusercontent.com/masjeho2/v1/refs/heads/sing-box/other/dns.sh"
    chmod +x /usr/bin/dns
    wget -q -O /usr/bin/certsing-box "https://raw.githubusercontent.com/masjeho2/v1/refs/heads/sing-box/other/certsing-box.sh"
    chmod +x /usr/bin/certsing-box
    # proto untuk statistik traffic (grpcurl)
    wget -q -O /root/protos/app/stats/config.proto "${REPO_URL}/protos/app/stats/config.proto"
    wget -q -O /root/protos/app/stats/command/command.proto "${REPO_URL}/protos/app/stats/command/command.proto"
    wget -q -O /root/protos/common/serial/typed_message.proto "${REPO_URL}/protos/common/serial/typed_message.proto"
    # API server
    wget -q -O /root/api/package.json "${REPO_URL}/package.json"
    wget -q -O /root/api/api-server.js "${REPO_URL}/api-server.js"
    chmod +x /root/api/api-server.js
}

install_api_deps() {
    cd /root/api && npm install --silent
}

setup_tools() {
    mkdir -p /root/protos/app/stats/command /root/protos/common/serial /root/api
    run_quiet "Mengunduh menu, proto & API server" fetch_tools

    if command -v node >/dev/null 2>&1; then
        run_quiet "Memasang dependensi API server (npm)" install_api_deps
    else
        log_message "WARN" "Node.js tidak ditemukan, npm install dilewati"
    fi
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

    if [ "$TLS_ENABLE" = "1" ]; then
        if [ -s /etc/haproxy/certs/domain.pem ]; then
            log_message "OK" "Sertifikat TLS ada (domain: ${DOMAIN})"
        else
            log_message "ERROR" "Sertifikat TLS tidak ditemukan di /etc/haproxy/certs/domain.pem"
            all_ok=false
        fi
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

start_api_pm2() {
    pm2 delete api >/dev/null 2>&1 || true
    cd /root/api
    pm2 start api-server.js --name api
    pm2 save
    pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true
}

finalize_installation() {
    log_message "INFO" "Menyelesaikan instalasi dan merestart layanan..."
    systemctl daemon-reload
    if systemctl restart haproxy; then
        log_message "OK" "HAProxy berjalan"
    else
        log_message "ERROR" "HAProxy gagal start. Detail:"
        haproxy -c -f /etc/haproxy/haproxy.cfg 2>&1 | head -n 8 | sed 's/^/      /' || true
    fi
    if systemctl restart sing-box.service; then
        log_message "OK" "sing-box berjalan"
    else
        log_message "ERROR" "sing-box gagal start. Detail:"
        sing-box check -c /etc/sing-box/config.json 2>&1 | head -n 8 | sed 's/^/      /' || true
        journalctl -u sing-box -n 8 --no-pager 2>/dev/null | sed 's/^/      /' || true
    fi
    start_frpc

    # Pastikan nvm + pm2 ke-source (installer jalan via setsid, non-login shell)
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    # Matikan systemd singbox-api lama kalau ada (konflik port 3030)
    systemctl stop singbox-api 2>/dev/null || true
    systemctl disable singbox-api 2>/dev/null || true

    if command -v pm2 >/dev/null 2>&1; then
        run_quiet "Menjalankan API server (PM2)" start_api_pm2
    else
        log_message "WARN" "PM2 tidak ditemukan, API server tidak di-start otomatis"
    fi
}

# --- [ EKSEKUSI UTAMA ] ---
main() {
    clear 2>/dev/null || true
    banner

    # Semua pertanyaan di awal, supaya sisanya jalan otomatis tanpa ditunggu
    ask_vps_type
    ask_path_id
    ask_tls
    ask_frpc_config
    confirm_settings
    # Sesuaikan jumlah langkah: +1 kalau TLS, -1 kalau frpc tidak dipasang
    if [ "$TLS_ENABLE" = "1" ]; then TOTAL_STEPS=$((TOTAL_STEPS + 1)); fi
    if [ "$FRP_SKIP" = "1" ]; then TOTAL_STEPS=$((TOTAL_STEPS - 1)); fi

    step "Memaksa koneksi IPv4";               force_ipv4
    step "Memperbarui sistem";                 update_system
    step "Memasang dependensi";                install_dependencies
    step "Menyiapkan direktori";               setup_directories; save_path_id
    step "Memasang sing-box";                  download_and_setup_singbox
    step "Memasang grpcurl";                   install_grpcurl
    step "Memasang HAProxy";                   install_haproxy; open_firewall
    if [ "$TLS_ENABLE" = "1" ]; then
        step "Menerbitkan sertifikat TLS";     issue_tls_cert
    fi
    step "Menulis config sing-box";            write_singbox_config
    step "Menulis config HAProxy";             write_haproxy_config
    if [ "$FRP_SKIP" != "1" ]; then
        step "Memasang frpc";                  install_frpc
    fi
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
