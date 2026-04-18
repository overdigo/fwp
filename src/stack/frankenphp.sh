#!/usr/bin/env bash
# MODULE: frankenphp.sh — FrankenPHP installation and management
FRANKENPHP_BIN="${FWP_FRANKENPHP_BIN:-/usr/local/bin/frankenphp}"
CADDY_CONFIG_DIR="${FWP_CADDY_CONFIG_DIR:-/etc/frankenphp}"

stack_frankenphp_install() {
  if command -v frankenphp &>/dev/null; then
    log_warn "Already installed: $(frankenphp version 2>&1 | head -1)"; return 0
  fi
  fwp_os_check_arch
  log_info "Fetching latest FrankenPHP release..."
  local url
  url=$(curl -sSL https://api.github.com/repos/dunglas/frankenphp/releases/latest \
    | grep "browser_download_url" \
    | grep "frankenphp-linux-${FPH_ARCH}\"" \
    | grep -v ".sha256" | head -1 | cut -d '"' -f 4 || true)
  if [[ -z "${url}" ]]; then
    log_fatal "Could not fetch FrankenPHP download URL."
  fi
  log_info "Downloading: ${url}"
  curl -sSL --progress-bar -o "${FRANKENPHP_BIN}" "${url}"
  chmod +x "${FRANKENPHP_BIN}"
  # Allow binding to privileged ports without running as root
  setcap 'cap_net_bind_service=+ep' "${FRANKENPHP_BIN}" 2>/dev/null || \
    log_warn "setcap failed — ensure www-data can bind ports 80/443"
  log_success "FrankenPHP installed: $(frankenphp version 2>&1 | head -1)"
}

stack_frankenphp_upgrade() {
  log_step "Upgrading FrankenPHP..."
  local current; current=$(frankenphp version 2>&1 | grep -oP 'v[\d.]+' | head -1 || echo "?")
  log_info "Current version: ${current}"
  systemctl stop frankenphp 2>/dev/null || true
  rm -f "${FRANKENPHP_BIN}"
  stack_frankenphp_install
  systemctl start frankenphp
  log_success "FrankenPHP upgraded: $(frankenphp version 2>&1 | head -1)"
}

stack_setup_global_caddyfile() {
  local cpus; cpus=$(nproc)
  local num_threads=$(( (cpus * 8) + 1 ))
  local max_threads=$(( (cpus * 32) + 1 ))
  
  log_info "FrankenPHP Tuning: ${cpus} CPUs detected -> ${num_threads} initial / ${max_threads} max threads"

  mkdir -p "${CADDY_CONFIG_DIR}/sites-available" "${CADDY_CONFIG_DIR}/sites-enabled"
  cat > "${CADDY_CONFIG_DIR}/Caddyfile" << CADDY
{
    # Enable FrankenPHP with dynamic thread scaling
    frankenphp {
        num_threads ${num_threads}
        max_threads ${max_threads}
        max_wait_time 45s
    }

    order php_server before file_server
    admin off
}

# Import all enabled site configs
import sites-enabled/*.conf
CADDY
  touch "${CADDY_CONFIG_DIR}/sites-enabled/.placeholder"
  log_success "Global Caddyfile written: ${CADDY_CONFIG_DIR}/Caddyfile"
}

stack_setup_php_config() {
  log_info "Configuring PHP ZTS for maximum performance..."
  mkdir -p /etc/frankenphp/conf.d
  cat > /etc/frankenphp/conf.d/99-frankenwp.ini << EOF
[PHP]
engine = On
short_open_tag = Off
precision = 14
output_buffering = 4096
zlib.output_compression = Off
implicit_flush = Off
unserialize_max_depth = 4096
serialize_precision = -1
disable_functions = pcntl_alarm,pcntl_fork,pcntl_waitpid,pcntl_wait,pcntl_wifexited,pcntl_wifstopped,pcntl_wifsignaled,pcntl_wifcontinued,pcntl_wexitstatus,pcntl_wtermsig,pcntl_wstopsig,pcntl_signal,pcntl_signal_get_handler,pcntl_signal_dispatch,pcntl_get_last_error,pcntl_strerror,pcntl_sigprocmask,pcntl_sigwaitinfo,pcntl_sigtimedwait,pcntl_exec,pcntl_getpriority,pcntl_setpriority,pcntl_async_signals,pcntl_unshare,
zend.enable_gc = On
expose_php = Off
max_execution_time = 300
max_input_time = 120
max_input_vars = 5000
memory_limit = 512M
upload_max_filesize = 128M
post_max_size = 128M
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
display_errors = Off
log_errors = On
variables_order = "GPCS"
request_order = "GPC"
register_argc_argv = Off
auto_globals_jit = On
default_charset = "UTF-8"
sys_temp_dir = "/tmp"
file_uploads = On
allow_url_fopen = On
allow_url_include = Off
default_socket_timeout = 60

# Performance
realpath_cache_size = 4096k
realpath_cache_ttl = 600

[Date]
date.timezone = America/Sao_Paulo

[MySQLi]
mysqli.allow_persistent = On
mysqli.max_persistent = 0
mysqli.reconnect = Off

[opcache]
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=36
opcache.max_accelerated_files=20000
opcache.jit=1255
opcache.jit_buffer_size=32M
opcache.validate_timestamps=0

[Session]
session.use_strict_mode = 1
session.use_cookies = 1
session.cookie_secure = 1
session.use_only_cookies = 1
session.cookie_httponly = 1
session.cookie_samesite = Strict
session.gc_probability = 0
EOF
  log_success "PHP config written: /etc/frankenphp/conf.d/99-frankenwp.ini"
}

stack_setup_systemd_service() {
  local ram_bytes; ram_bytes=$(free -b | grep Mem | awk '{print $2}')
  # Set GOMEMLIMIT to 90% of total RAM to leave room for the OS
  local gomemlimit=$(( ram_bytes * 9 / 10 ))

  cat > /etc/systemd/system/frankenphp.service << SERVICE
[Unit]
Description=FrankenPHP Server
Documentation=https://frankenphp.dev
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=notify
User=www-data
Group=www-data
WorkingDirectory=/etc/frankenphp
Environment=XDG_DATA_HOME=/var/lib/frankenphp/data
Environment=XDG_CONFIG_HOME=/var/lib/frankenphp/config
Environment=PHP_INI_SCAN_DIR=/etc/frankenphp/conf.d
Environment=GODEBUG=cgocheck=0
Environment=GOMEMLIMIT=${gomemlimit}
ExecStart=/usr/local/bin/frankenphp run --config /etc/frankenphp/Caddyfile
ExecReload=/bin/kill -USR1 \$MAINPID
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=65535
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE
  mkdir -p /var/lib/frankenphp/data /var/lib/frankenphp/config
  chown -R www-data:www-data /var/lib/frankenphp
  systemctl daemon-reload
  systemctl enable frankenphp
  log_success "frankenphp.service installed with GOMEMLIMIT=${gomemlimit}B"
}

stack_status() {
  echo ""
  echo -e "  ${BOLD}FrankenWP Service Status${NC}"
  echo "  ─────────────────────────────────────────────"
  for svc in frankenphp mysql redis-server; do
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
      echo -e "  ${GREEN}●${NC} ${svc:-service}  ${GREEN}(active)${NC}"
    elif systemctl list-unit-files --quiet "${svc}.service" &>/dev/null; then
      echo -e "  ${RED}●${NC} ${svc:-service}  ${RED}(inactive)${NC}"
    else
      echo -e "  ${YELLOW}○${NC} ${svc:-service}  ${YELLOW}(not installed)${NC}"
    fi
  done

  echo ""
  echo -e "  ${BOLD}Network Listeners${NC}"
  echo "  ─────────────────────────────────────────────"
  local ports=(80 443 3306 6379)
  for port in "${ports[@]}"; do
    if ss -tln | grep -q ":${port} "; then
      echo -e "  ${GREEN}✓${NC} Port ${port} is listening"
    else
      echo -e "  ${RED}✗${NC} Port ${port} is NOT listening"
    fi
  done

  if ! ss -tln | grep -qE ":80 |:443 "; then
    echo ""
    echo -e "  ${YELLOW}Tip: FrankenPHP is active but ports 80/443 are closed.${NC}"
    echo -e "  Check logs: ${BOLD}journalctl -u frankenphp --no-pager -n 20${NC}"
  fi

  source "${FWP_HOME}/src/stack/kernel.sh"
  stack_kernel_status
}
