# AGENTS.md — FrankenWP Development Guide

This document describes the project architecture, module contracts, coding conventions,
and contribution guidelines for FrankenWP.

---

## Project Goal

FrankenWP (`fwp`) is a CLI tool to install and manage WordPress sites using FrankenPHP
as the PHP server. Inspired by EasyEngine v3 / WordOps, but:

- **Pure Bash** — no Python runtime dependency
- **FrankenPHP** instead of Nginx + PHP-FPM
- **HTTP/3 (QUIC)** enabled by default
- Supports: Debian 12/13, Ubuntu 24.04/26.04

---

## Technology Stack

| Layer | Technology |
|---|---|
| PHP Server | FrankenPHP (latest binary from GitHub Releases) |
| Web config | Caddyfile (per-site, imported by global config) |
| Database | MariaDB (via apt) |
| Cache | Redis + WP Redis Object Cache plugin |
| WordPress | Installed via WP-CLI |
| SSL / HTTPS | Automatic Let's Encrypt via FrankenPHP/Caddy |
| HTTP compression | Zstandard → Brotli → Gzip |
| CLI language | Bash 5+ (no external runtime) |
| Package manager | apt (Debian/Ubuntu only) |

---

## Directory Layout

```
frankenwp/
├── bin/fwp                    CLI entrypoint — parses commands, loads modules
├── install.sh                 Bootstrap script — full stack installer
├── src/
│   ├── core/
│   │   ├── log.sh             Logging: log_info / log_success / log_warn / log_fatal / log_step
│   │   ├── os.sh              OS detection (fwp_os_detect) + apt helpers
│   │   ├── utils.sh           Shared helpers: _generate_password, _validate_domain, _frankenphp_reload
│   │   └── banner.sh          ASCII art banner
│   └── stack/
│       ├── frankenphp.sh      FrankenPHP binary install, global Caddyfile, systemd service
│       ├── mariadb.sh         MariaDB install, optimized config, DB create/drop
│       ├── redis.sh           Redis install, maxmemory/policy config
│       ├── wpcli.sh           WP-CLI install, WordPress download/install/config
│       ├── kernel.sh          sysctl tuning + open file limits (WordOps-based)
│       └── firewall.sh        UFW + Fail2Ban (WordOps-based rules)
├── src/site/
│   ├── create.sh              8-step site creation flow
│   ├── delete.sh              Site removal with confirmation
│   ├── enable.sh              Symlink site in sites-enabled + reload
│   ├── disable.sh             Remove symlink + reload
│   ├── list.sh                Table view of all sites
│   └── info.sh                Detailed site info from registry
├── templates/
│   ├── Caddyfile.tpl          (reference template)
│   └── frankenphp.service.tpl (reference template)
├── completions/
│   └── fwp.bash               Bash tab-completion
├── README.md
└── AGENTS.md                  ← You are here
```

---

## Module Contracts

### `src/core/log.sh`
Every module sources this. Provides:
- `log_info`, `log_success`, `log_warn`, `log_error`, `log_fatal`, `log_step`
- `log_fatal` exits with code 1
- All output goes to stdout/stderr AND `${FWP_LOG_FILE}`

### `src/core/os.sh`
- `fwp_os_detect` → sets `OS_ID`, `OS_VERSION`, `OS_NAME` (exits on unsupported OS)
- `fwp_os_check_arch` → sets `SYS_ARCH`, `FPH_ARCH` (exits on unsupported arch)
- `fwp_os_pkg_install <pkg>...` → wraps `apt-get install -y -qq`

### `src/core/utils.sh`
- `_generate_password <length>` → random password from `/dev/urandom`
- `_generate_db_name <domain>` → safe DB name string
- `_validate_domain <domain>` → exits if invalid
- `_site_exists <domain>` → returns 0 if `/etc/fwp/sites/<domain>.conf` exists
- `_frankenphp_reload` → reload or start the frankenphp systemd service

### `src/stack/kernel.sh`
- `stack_kernel_tune` → writes sysctl config + limits, applies immediately
- `stack_kernel_status` → prints current kernel parameters

### `src/stack/firewall.sh`
- `stack_firewall_setup` → installs UFW/Fail2Ban, applies all rules, enables
- `stack_firewall_status` → shows `ufw status verbose` + fail2ban-client status
- `stack_firewall_allow <port>` / `stack_firewall_deny <port>` → CLI subcommands
- Auto-detects SSH port from `/etc/ssh/sshd_config` to avoid lockouts

### `src/site/create.sh` — 8-step flow
1. Validate domain, check for duplicate
2. Generate passwords (DB + WP admin)
3. Create `/var/www/<domain>/{htdocs,logs,conf}`
4. Create MariaDB database + user
5. Generate per-site Caddyfile → symlink → reload FrankenPHP
6. WP-CLI: download WordPress + create wp-config.php
7. WP-CLI: install WordPress + set locale
8. WP-CLI: install Redis Object Cache plugin

Registry saved to `/etc/fwp/sites/<domain>.conf` (chmod 600).

---

## Firewall Rules Reference

| Rule | Protocol | Purpose |
|---|---|---|
| `ufw limit <SSH_PORT>/tcp` | TCP | SSH, rate-limited (anti brute-force) |
| `ufw allow 80/tcp` | TCP | HTTP |
| `ufw allow 443/tcp` | TCP | HTTPS / TLS |
| `ufw allow 443/udp` | **UDP** | **HTTP/3 via QUIC** ← required for FrankenPHP |

> `443/udp` is mandatory. Without it, the QUIC handshake fails and clients
> silently fall back to HTTP/2, losing all HTTP/3 performance benefits.

---

## Kernel Tuning Reference

Written to `/etc/sysctl.d/99-frankenwp.conf`:

| Parameter | Value | Notes |
|---|---|---|
| `fs.file-max` | `2097152` | Max open file handles |
| `vm.swappiness` | `10` | Prefer RAM over swap |
| `net.core.somaxconn` | `65535` | Max listen backlog |
| `net.core.default_qdisc` | `fq` | Required for BBR |
| `net.ipv4.tcp_congestion_control` | `bbr` / `cubic` | BBR if available |
| `net.ipv4.tcp_syncookies` | `1` | SYN flood protection |
| `net.ipv4.tcp_fin_timeout` | `15` | Reduce TIME_WAIT duration |
| `net.core.rmem_max` / `wmem_max` | `33554432` | 32 MB socket buffers |

Open file limits in `/etc/security/limits.d/99-frankenwp.conf`:
- `*  soft/hard nofile  1048576`
- `*  soft/hard nproc   65535`

systemd override in `/etc/systemd/system/frankenphp.service.d/limits.conf`:
- `LimitNOFILE=1048576`

---

## Coding Conventions

- **Bash 5+**, `set -euo pipefail` in all scripts
- **`snake_case`** for all function names
- Module-specific functions prefixed: `stack_`, `site_`, `wpcli_`, `_private`
- All user-visible output goes through `log_*` functions — never raw `echo` for status
- Never hardcode paths — use variables from `fwp.conf` or module constants
- Every `fwp site *` command validates its arguments before doing any work
- Passwords always generated from `/dev/urandom`, never hardcoded

---

## Security & Stability Patterns (v0.4.0)

### 1. Bash Completion
- **Never** modify `/etc/bash.bashrc` (global).
- Configuration is strictly appended to `/root/.bashrc`.
- Ensures shell security and avoids interference with non-root users.

### 2. Configuration Permissions
- All per-site Caddyfiles in `/etc/frankenphp/sites-available/` **must** have `644` permissions.
- This allows the `www-data` user (which runs the FrankenPHP service) to read the configuration while keeping it owned by `root`.

### 3. Directory Ownership
- The `/var/www/` directory and its subfolders **must** be owned by `www-data:www-data`.
- This prevents "Permission Denied" errors when FrankenPHP/Caddy attempts to create log files or manage site-specific directories.

---

## Contributing

1. Fork → branch (`feat/my-feature` or `fix/bug-name`)
2. Test on a clean Debian 12 VM first (most stable baseline)
3. Test on Ubuntu 24.04 before submitting
4. Run shellcheck on modified files: `shellcheck src/**/*.sh`
5. Open a pull request — describe what was changed and why

---

## Roadmap

- [ ] `fwp site wp <domain> <args>` — run WP-CLI in site context
- [ ] `fwp site backup <domain>` — tar + mysqldump to `/var/backups/fwp/`
- [ ] `fwp site restore <domain> <file>` — restore from backup
- [ ] `fwp stack install --skip-kernel` / `--skip-firewall` — opt-out flags
- [ ] `fwp monitor` — real-time tail of site access logs
- [ ] Multisite WordPress support
- [ ] Ansible playbook / cloud-init bootstrap
