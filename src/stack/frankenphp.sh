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
  mkdir -p "${CADDY_CONFIG_DIR}/sites-available" "${CADDY_CONFIG_DIR}/sites-enabled"
  cat > "${CADDY_CONFIG_DIR}/Caddyfile" << 'CADDY'
{
    # Enable FrankenPHP
    frankenphp

    order php_server before file_server
    admin off
}

# Import all enabled site configs (using glob that doesn't fail if empty)
import sites-enabled/*.conf
CADDY
  touch "${CADDY_CONFIG_DIR}/sites-enabled/.placeholder"
  log_success "Global Caddyfile written: ${CADDY_CONFIG_DIR}/Caddyfile"
}

stack_setup_systemd_service() {
  cat > /etc/systemd/system/frankenphp.service << 'SERVICE'
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
ExecStart=/usr/local/bin/frankenphp run --config /etc/frankenphp/Caddyfile
ExecReload=/bin/kill -USR1 $MAINPID
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
  log_success "frankenphp.service installed and enabled"
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
