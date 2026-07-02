# 🚀 singbox-bot

> **One-line installer** untuk **Sing-box + HAProxy** di VPS Ubuntu 22.04/24.04 — langsung jalan, lengkap dengan SSL Let's Encrypt, V2Ray API stats, dan Node.js management API.

```bash
bash -c "$(curl -sL https://raw.githubusercontent.com/masjeho2/singbox-bot/refs/heads/main/install.sh)"
```

Jalankan sebagai `root`, tunggu 3–5 menit, server langsung siap dipake. Domain diminta interaktif (subdomain VPS lo), SSL auto-issue.

---

## ✨ Apa yang di-install?

| Komponen | Versi | Fungsi |
|---|---|---|
| **sing-box** | latest binary | Core VPN/proxy (VMess, VLESS, Trojan, Shadowsocks) |
| **HAProxy** | 2.4+ (22.04) / 2.8+ (24.04) | TLS terminator + load balancer untuk traffic HTTPS |
| **grpcurl** | 1.9.1 | gRPC client untuk query V2Ray API (statistik kuota per-user) |
| **acme.sh** | latest | Issuance & auto-renewal SSL Let's Encrypt (EC-256) |
| **Node.js** | 24.x LTS (via nvm) | Runtime untuk `api.js` (management endpoint) |
| **PM2** | 7.x (post-install) | Process manager untuk `singbox-api` (auto-start on boot) |
| **haproxy** | enabled systemd | Service manager |
| **sing-box** | enabled systemd | Service manager |
| **fail2ban** | latest | Brute-force protection |
| **vnstat** | latest | Network traffic monitor |

Tools kecil:
- `menu` — menu interaktif untuk manage user/inbound
- `dns` — ganti domain tanpa reinstall
- `certsing-box` — reissue SSL manual

---

## 🔌 Port yang dipakai

### Public (di-firewall, boleh dari internet)

| Port | Protocol | Tujuan |
|---|---|---|
| **80/tcp** | HTTP | ACME challenge + redirect ke HTTPS |
| **443/tcp** | HTTPS | TLS terminator HAProxy → forward ke sing-box (ws/grpc) |

### Internal (127.0.0.1 only — aman)

| Port | Service | Tujuan |
|---|---|---|
| `127.0.0.1:8080` | sing-box v2ray_api | Statistik traffic (gRPC) — dipakai `grpcurl` |
| `127.0.0.1:9090` | sing-box clash_api | Dashboard clash-compatible |
| `127.0.0.1:3030` | `api.js` (Node + PM2) | Management endpoint: file I/O, service control, exec whitelist |

### Inbound VPN (didengarkan oleh sing-box)

Semua inbound default cuma listen di `0.0.0.0` (IPv4). Ganti sesuai kebutuhan.

| Port | Protocol | Transport | Path / Service |
|---|---|---|---|
| `10001` | VMess | WebSocket | `/vmess` |
| `20001` | VMess | gRPC | `vmess-grpc` |
| `10002` | VLESS | WebSocket | `/vless-ws` |
| `20002` | VLESS | gRPC | `vless-grpc` |
| `10003` | Trojan | WebSocket | `/trojan-ws` |
| `20003` | Trojan | gRPC | `trojan-grpc` |

> **Default user (Trojan, contoh):** di-seed otomatis di `config.json`. Hapus sebelum deploy production!

---

## 🔐 Management API (api.js)

Node.js HTTP server di port `3030` (localhost only). Auth via header `X-API-Key`.

### Endpoint

| Method | Path | Body | Fungsi |
|---|---|---|---|
| `GET` | `/api/ping` | — | Health check |
| `GET` | `/api/file?path=...` | — | Baca file (config, log) |
| `POST` | `/api/file` | `{path, content}` | Tulis file (auto-backup `.bak.<ts>`) |
| `POST` | `/api/service` | `{service, action}` | `restart` / `status` (systemd) |
| `POST` | `/api/system/reboot` | — | Reboot VPS |
| `POST` | `/api/monitoring/online-ips` | `{logPath, type}` | Parse IP user yang online (Xray/sing-box log) |
| `POST` | `/api/exec` | `{command}` | Exec whitelist: `xray api statsquery`, `grpcurl ...` |

### Contoh pakai

```bash
# Health check
curl -H "X-API-Key: YOUR_KEY" http://127.0.0.1:3030/api/ping

# Restart sing-box
curl -X POST -H "X-API-Key: YOUR_KEY" -H "Content-Type: application/json" \
  -d '{"service":"sing-box","action":"restart"}' \
  http://127.0.0.1:3030/api/service

# Query traffic stats
curl -X POST -H "X-API-Key: YOUR_KEY" -H "Content-Type: application/json" \
  -d '{"command":"grpcurl -plaintext -import-path /root/protos -proto app/stats/command/command.proto 127.0.0.1:8080 list"}' \
  http://127.0.0.1:3030/api/exec
```

> ⚠️ **Ganti `API_KEY` di `api.js` sebelum deploy production!**

### PM2 commands

```bash
pm2 list                # status
pm2 logs singbox-api    # live logs
pm2 restart singbox-api
pm2 save                # freeze process list (untuk auto-resurrect)
pm2 startup             # generate systemd init
```

---

## 📂 Struktur file

```
/etc/sing-box/
  ├── config.json           # konfigurasi utama sing-box
  ├── domain                # simpan domain aktif (plain text)
  ├── fullchain.crt         # SSL cert (Let's Encrypt)
  └── private.key           # SSL private key (EC-256)

/etc/haproxy/
  ├── haproxy.cfg           # konfigurasi haproxy
  └── certs/domain.pem      # gabungan cert + key (buat haproxy)

/root/protos/               # .proto files (untuk grpcurl)
  ├── app/stats/config.proto
  ├── app/stats/command/command.proto
  └── common/serial/typed_message.proto

/root/api/
  ├── api.js                # management API
  ├── package.json
  └── node_modules/

/usr/bin/
  ├── sing-box              # binary
  ├── menu                  # menu interaktif
  ├── dns                   # ganti domain
  └── certsing-box          # reissue SSL
```

---

## 🔧 Persyaratan

- **OS**: Ubuntu 22.04 LTS atau 24.04 LTS (Debian-based lain mungkin jalan, belum tested)
- **Akses**: root (script pakai `apt`, `systemctl`, `wget`)
- **Domain**: subdomain yang udah pointing ke IP VPS (A record, bukan CNAME)
- **Port 80 free**: untuk ACME challenge (script auto-stop haproxy saat issue cert)

---

## 🛠️ Quick start

```bash
# 1. Login sebagai root
ssh root@your-vps

# 2. Jalankan installer
bash -c "$(curl -sL https://raw.githubusercontent.com/masjeho2/singbox-bot/refs/heads/main/install.sh)"

# 3. Masukin subdomain lo saat diminta (mis. vpn.example.com)

# 4. Tunggu ~5 menit. SSL auto-issue, services auto-start.

# 5. Verify
curl -I https://your-domain
systemctl status sing-box haproxy
```

---

## 🐛 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Install hang di "Mengunduh binary sing-box" | IPv6 route mati, wget SYN-SENT | ✅ Fixed: script auto-force IPv4 |
| Install fail di `add-apt-repository` | Launchpad gak reachable | ✅ Fixed: coba repo Ubuntu dulu |
| `sing-box` crash on start, `start-limit-hit` | `config.json` masih `::` | ✅ Fixed: script sed-replace ke `0.0.0.0` |
| `grpcurl` not found | (sebelumnya belum di-install) | ✅ Fixed: included di installer |
| Kuota user selalu 0 Bytes | grpcurl gak bisa connect ke V2Ray API | Cek firewall port `127.0.0.1:8080` (internal only) |
| SSL gak ke-issue | Port 80 ke-block / domain belum pointing | `dig +short your.domain` harus return IP VPS |

---

## 🗑️ Uninstall

Script `uninstall.sh` sudah tersedia untuk remove semua komponen dengan bersih.

### Mode

| Mode | Flag | Yang dihapus | Yang di-keep |
|---|---|---|---|
| **Full** | `--full` | sing-box, haproxy, api.js, protos, tools, grpcurl, acme.sh, node/nvm, PM2, certs, config, logs | — |
| **Keep tools** | `--keep` | sing-box, haproxy, api.js, PM2 | node, grpcurl, tools, acme.sh, protos |

### Cara pakai

```bash
# Full uninstall (hapus semua)
bash -c "$(curl -sL https://raw.githubusercontent.com/masjeho2/singbox-bot/main/uninstall.sh)" --full

# Keep tools, cuma remove services
bash -c "$(curl -sL https://raw.githubusercontent.com/masjeho2/singbox-bot/main/uninstall.sh)" --keep

# Interactive (tanya mode dulu)
bash -c "$(curl -sL https://raw.githubusercontent.com/masjeho2/singbox-bot/main/uninstall.sh)"
```

> ⚠️ Uninstall akan minta **konfirmasi `y/N`** sebelum hapus apa pun.
> Setelah selesai, **reboot disarankan** untuk bersihkan semua service.

---

## 📜 Lisensi

MIT — bebas dipake, modifikasi, distribusi. **Tanggung jawab sendiri** untuk legalitas penggunaan di negara lo.

---

## 🙏 Credits

- [SagerNet/sing-box](https://github.com/SagerNet/sing-box) — core proxy engine
- [acmesh-official/acme.sh](https://github.com/acmesh-official/acme.sh) — SSL issuance
- [fullstorydev/grpcurl](https://github.com/fullstorydev/grpcurl) — gRPC client
- [HAProxy](https://www.haproxy.org/) — TLS terminator

---

<p align="center">
  <sub>Dibuat dengan ❤️ untuk komunitas self-hosted Indonesia</sub>
</p>
