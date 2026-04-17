# FrankenWP

> WordPress + FrankenPHP — automated CLI installer in 2 commands

**FrankenWP** (`fwp`) installs and manages WordPress sites using [FrankenPHP](https://frankenphp.dev) — a modern PHP server with HTTP/3 (QUIC), automatic HTTPS, and Zstandard compression built-in. Kernel tuning and firewall hardening are based on [WordOps](https://github.com/WordOps/WordOps).

## Supported Operating Systems

| OS | Version | Arch |
|---|---|---|
| Debian | 12 (Bookworm) | x86_64, aarch64 |
| Debian | 13 (Trixie) | x86_64, aarch64 |
| Ubuntu | 24.04 LTS (Noble) | x86_64, aarch64 |
| Ubuntu | 26.04 LTS | x86_64, aarch64 |

## 2-Command Install

```bash
# 1 — Download and install the full stack
wget -qO fwp https://raw.githubusercontent.com/YOUR_USER/frankenwp/main/install.sh
sudo bash fwp

# 2 — Spin up a WordPress site
sudo fwp site create example.com
```

## What Gets Installed

| Component | Notes |
|---|---|
| **FrankenPHP** | Latest release, auto-detects x86_64 / aarch64 |
| **MariaDB** | `utf8mb4`, InnoDB buffer 256 MB, slow query log |
| **Redis** | 128 MB max memory, `allkeys-lru` eviction |
| **WP-CLI** | Latest phar |
| **WordPress** | Any locale, fully automated via WP-CLI |
| **Let's Encrypt HTTPS** | Automatic via FrankenPHP / Caddy |
| **HTTP/3 + QUIC** | Enabled by default (`443/tcp` + `443/udp`) |
| **Zstandard compression** | `zstd` → `br` → `gzip` in Caddyfile |
| **Image Optimization** | Automatic AVIF / WebP negotiation via `Accept` header |
| **Security Headers** | HSTS, CSP, XSS protection, hidden server signatures |
| **Rate Limiting** | Anti-bruteforce for wp-login, XML-RPC block, API limits |
| **Kernel tuning** | BBR, sysctl, open file limits |
| **UFW + Fail2Ban** | Hardened rules |

## Commands

```bash
# Site management
sudo fwp site create example.com
sudo fwp site create dev.local --skip-ssl --locale=pt_BR --title="Dev Site"
sudo fwp site list
sudo fwp site info example.com
sudo fwp site disable example.com
sudo fwp site enable example.com
sudo fwp site delete example.com

# Stack
sudo fwp stack status          # Services + kernel parameters
sudo fwp stack upgrade         # Upgrade FrankenPHP binary

# Firewall
sudo fwp firewall status       # UFW rules + Fail2Ban status
sudo fwp firewall allow 8080/tcp
sudo fwp firewall deny 3306/tcp

# General
fwp version
fwp --help
```

## File Layout

```
/opt/fwp/                         ← FrankenWP source
├── bin/fwp                       ← CLI entrypoint (symlinked to /usr/local/bin/fwp)
├── src/core/                     ← log.sh  os.sh  utils.sh  banner.sh
├── src/stack/                    ← frankenphp.sh  mariadb.sh  redis.sh
│                                   wpcli.sh  kernel.sh  firewall.sh
├── src/site/                     ← create.sh  delete.sh  enable.sh
│                                   disable.sh  list.sh   info.sh
└── templates/                    ← Caddyfile.tpl  frankenphp.service.tpl

/etc/fwp/
├── fwp.conf                      ← Global configuration
└── sites/<domain>.conf           ← Per-site registry (chmod 600)

/etc/frankenphp/
├── Caddyfile                     ← Global Caddy config
├── sites-available/<domain>.conf ← Per-site Caddyfile
└── sites-enabled/<domain>.conf   ← Symlink when active

/var/www/<domain>/
├── htdocs/                       ← WordPress web root
├── logs/access.log               ← Per-site access log
└── conf/                         ← Reserved for extra config

/etc/sysctl.d/99-frankenwp.conf   ← Kernel tuning
/etc/security/limits.d/99-frankenwp.conf  ← Open file limits
/etc/fail2ban/jail.d/frankenwp.conf       ← Fail2Ban SSH jail
```

## Kernel Tuning (WordOps-based)

Applied automatically during `install.sh`:

| Parameter | Value | Purpose |
|---|---|---|
| `net.ipv4.tcp_congestion_control` | `bbr` | Google BBR — better throughput |
| `net.core.default_qdisc` | `fq` | Required for BBR |
| `net.core.somaxconn` | `65535` | Max queued connections |
| `net.ipv4.tcp_syncookies` | `1` | SYN flood protection |
| `net.ipv4.tcp_fin_timeout` | `15` | Reduce TIME_WAIT |
| `fs.file-max` | `2097152` | Max open file handles |
| `vm.swappiness` | `10` | Keep data in RAM |
| Open file limit (`nofile`) | `1048576` | Per-process and system |

## Firewall Rules (WordOps-based)

```
ALLOW OUT  all
DENY  IN   all (default)
LIMIT IN   22/tcp     SSH (rate-limited — max 6 conn/30s)
ALLOW IN   53         DNS
ALLOW IN   80/tcp     HTTP
ALLOW IN   443/tcp    HTTPS / TLS
ALLOW IN   443/udp    HTTP/3 QUIC  ← required for FrankenPHP HTTP/3
ALLOW IN   123        NTP
```

Fail2Ban: 5 max SSH retries per 5-minute window → 1-hour ban. Action: `ufw`.

## Development

See [AGENTS.md](./AGENTS.md) for architecture decisions, module contracts, and contribution guide.
