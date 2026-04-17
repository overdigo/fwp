#!/usr/bin/env bash
# ==============================================================================
# FrankenWP — Bootstrap Installer
# Usage:
#   wget -qO fwp https://cdn.jsdelivr.net/gh/overdigo/fwp@main/install.sh
#   sudo bash fwp
# Supported: Debian 12/13 | Ubuntu 24.04 / 26.04
# ==============================================================================
set -euo pipefail

FWP_VERSION="0.1.0"
FWP_REPO_RAW="https://cdn.jsdelivr.net/gh/overdigo/fwp@main"
FWP_HOME="/opt/fwp"
FWP_BIN="/usr/local/bin/fwp"
FWP_CONFIG_DIR="/etc/fwp"
FWP_LOG_DIR="/var/log/fwp"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[✓]${NC}      $*"; }
log_warn()    { echo -e "${YELLOW}[!]${NC}      $*"; }
log_fatal()   { echo -e "${RED}[FATAL]${NC}  $*" >&2; exit 1; }
log_step()    { echo -e "\n${CYAN}${BOLD}━━ $* ${NC}"; }

print_banner() {
  echo -e "${CYAN}${BOLD}"
  printf '%s\n' '  ___              _            __      ______'
  printf '%s\n' ' / __\_  _ _ __ _ _| | _____ _ _\ \    / /  _ \'
  printf '%s\n' '/ _\| '"'"'_/ _` | '"'"' \ |/ / -_) '"'"' \\ \/\/ /| |_) |'
  printf '%s\n' '\/___|_| \__,_|_||_|_\_\___|_||_|\__  / |  __/'
  printf '%s\n' '                                      \/  |_|'
  echo -e "${NC}${BOLD}  FrankenWP v${FWP_VERSION} — WordPress + FrankenPHP${NC}"
  echo -e "  ${YELLOW}Stack Installer${NC}\n"
}

check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log_fatal "Run as root: sudo bash $0"
  fi
}

detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    log_fatal "Cannot detect OS: /etc/os-release not found"
  fi
  source /etc/os-release
  OS_ID="${ID:-}"; OS_VERSION="${VERSION_ID:-}"
  case "${OS_ID}" in
    debian)
      case "${OS_VERSION}" in
        12) OS_NAME="Debian 12 (Bookworm)" ;;
        13) OS_NAME="Debian 13 (Trixie)" ;;
        *)  log_fatal "Unsupported Debian ${OS_VERSION}. Supported: 12, 13" ;;
      esac ;;
    ubuntu)
      case "${OS_VERSION}" in
        24.04*) OS_NAME="Ubuntu 24.04 LTS (Noble)" ;;
        25.10*|26.04*) OS_NAME="Ubuntu 26.04 LTS" ;;
        *)     log_fatal "Unsupported Ubuntu ${OS_VERSION}. Supported: 24.04, 26.04" ;;
      esac ;;
    *) log_fatal "Unsupported OS '${OS_ID}'. Supported: Debian 12/13, Ubuntu 24.04/26.04" ;;
  esac
  log_info "OS detected: ${OS_NAME}"
}

detect_arch() {
  ARCH=$(uname -m)
  case "${ARCH}" in
    x86_64)  FPH_ARCH="x86_64" ;;
    aarch64) FPH_ARCH="aarch64" ;;
    *) log_fatal "Unsupported architecture: ${ARCH}. Supported: x86_64, aarch64" ;;
  esac
  log_info "Architecture: ${ARCH}"
}

install_base_deps() {
  log_step "Adding repositories & installing dependencies (optimized)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || apt-get update -qq || true
  apt-get install -y -qq curl wget gnupg lsb-release debconf-utils ca-certificates >/dev/null 2>&1

  # Add MySQL 8.4 repo (Updated to .36 for newer GPG keys and Debian 13 support)
  wget -qO /tmp/mysql-apt-config.deb https://dev.mysql.com/get/mysql-apt-config_0.8.36-1_all.deb
  echo "mysql-apt-config mysql-apt-config/select-server select mysql-8.4-lts" | debconf-set-selections
  echo "mysql-apt-config mysql-apt-config/select-product select Ok" | debconf-set-selections
  dpkg -i /tmp/mysql-apt-config.deb >/dev/null 2>&1
  # Force trust to prevent 'sqv' strict expiration blocks on Debian 13
  sed -i 's/deb http/deb [trusted=yes] http/g' /etc/apt/sources.list.d/mysql.list 2>/dev/null || true

  # Add Redis 8 repo
  curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg --yes
  chmod 644 /usr/share/keyrings/redis-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list

  # Fast, bulk installation
  apt-get update -qq || apt-get update -qq || true
  apt-get install -y -qq \
    git unzip tar ufw fail2ban logrotate \
    mysql-server mysql-client redis \
    >/dev/null 2>&1

  log_success "All stack dependencies installed in bulk"
}

install_frankenphp() {
  log_step "Installing FrankenPHP..."
  if command -v frankenphp &>/dev/null; then
    log_warn "Already installed: $(frankenphp version 2>&1 | head -1)"; return 0
  fi
  local url
  url=$(curl -sSL https://api.github.com/repos/dunglas/frankenphp/releases/latest \
    | grep "browser_download_url" \
    | grep "frankenphp-linux-${FPH_ARCH}\"" \
    | grep -v ".sha256" | head -1 | cut -d '"' -f 4 || true)
  if [[ -z "${url}" ]]; then
    log_fatal "Could not resolve FrankenPHP download URL"
  fi
  log_info "Downloading: ${url}"
  curl -sSL --progress-bar -o /usr/local/bin/frankenphp "${url}"
  chmod +x /usr/local/bin/frankenphp
  # Configure global CLI PHP settings (memory limit for WP-CLI)
  mkdir -p /etc/frankenphp/conf.d
  echo "memory_limit=512M" > /etc/frankenphp/conf.d/cli.ini
  echo "error_reporting=E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED" >> /etc/frankenphp/conf.d/cli.ini

  # Create a wrapper so 'php' executes via FrankenPHP's php-cli subsystem natively
  cat > /usr/local/bin/php << 'EOF'
#!/bin/sh
export PHP_INI_SCAN_DIR=/etc/frankenphp/conf.d
exec frankenphp php-cli "$@"
EOF
  chmod +x /usr/local/bin/php
  setcap 'cap_net_bind_service=+ep' /usr/local/bin/frankenphp 2>/dev/null || \
    log_warn "setcap failed — www-data may not bind privileged ports"
  log_success "FrankenPHP installed: $(frankenphp version 2>&1 | head -1)"
}

install_wpcli() {
  log_step "Installing WP-CLI..."
  if command -v wp &>/dev/null; then log_warn "Already installed."; return 0; fi
  curl -sSL "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar" \
    -o /usr/local/bin/wp
  chmod +x /usr/local/bin/wp
  log_success "WP-CLI installed"
}

setup_dirs() {
  log_step "Creating directories..."
  mkdir -p "${FWP_HOME}"/{src/core,src/stack,src/site,templates,completions}
  mkdir -p "${FWP_CONFIG_DIR}/sites" "${FWP_LOG_DIR}"
  mkdir -p /etc/frankenphp/sites-{available,enabled} /var/www/.wp-cli/cache
  id www-data &>/dev/null || useradd -r -s /usr/sbin/nologin www-data
  chown -R www-data:www-data /var/www/.wp-cli
  log_success "Directories created"
}

install_fwp_files() {
  log_step "Installing FrankenWP files..."
  local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${script_dir}/bin/fwp" ]]; then
    cp -r "${script_dir}/." "${FWP_HOME}/"
    log_info "Installed from local checkout: ${script_dir}"
  else
    local modules=(
      "src/core/log.sh"   "src/core/os.sh"    "src/core/utils.sh" "src/core/banner.sh"
      "src/stack/frankenphp.sh" "src/stack/mariadb.sh" "src/stack/redis.sh"
      "src/stack/wpcli.sh"  "src/stack/kernel.sh"   "src/stack/firewall.sh"
      "src/site/create.sh"  "src/site/delete.sh"    "src/site/enable.sh"
      "src/site/disable.sh" "src/site/list.sh"      "src/site/info.sh"
      "bin/fwp"
    )
    for mod in "${modules[@]}"; do
      mkdir -p "${FWP_HOME}/$(dirname "${mod}")"
      curl -sSfL "${FWP_REPO_RAW}/${mod}" -o "${FWP_HOME}/${mod}" || \
        log_warn "Could not download ${mod}"
    done
  fi
  chmod +x "${FWP_HOME}/bin/fwp"
  ln -sf "${FWP_HOME}/bin/fwp" "${FWP_BIN}"
  log_success "fwp installed at ${FWP_BIN}"
}

apply_kernel_tuning() {
  log_step "Applying kernel tuning (WordOps-based)..."
  source "${FWP_HOME}/src/core/log.sh"
  source "${FWP_HOME}/src/stack/kernel.sh"
  stack_kernel_tune
}

setup_firewall() {
  log_step "Configuring firewall (WordOps-based rules)..."
  source "${FWP_HOME}/src/core/log.sh"
  source "${FWP_HOME}/src/core/os.sh"
  source "${FWP_HOME}/src/stack/firewall.sh"
  stack_firewall_setup
}

setup_services() {
  log_step "Configuring services..."
  source "${FWP_HOME}/src/core/log.sh"
  source "${FWP_HOME}/src/stack/frankenphp.sh"
  source "${FWP_HOME}/src/stack/mariadb.sh"
  source "${FWP_HOME}/src/stack/redis.sh"
  stack_setup_global_caddyfile
  stack_setup_systemd_service
  
  stack_mariadb_install
  stack_redis_install
  
  systemctl enable --now frankenphp mysql redis-server 2>/dev/null || true
  log_success "All services enabled and started"
}

write_config() {
  log_step "Writing global configuration..."
  cat > "${FWP_CONFIG_DIR}/fwp.conf" << CONF
FWP_VERSION="${FWP_VERSION}"
FWP_HOME="${FWP_HOME}"
FWP_SITES_DIR="/var/www"
FWP_FRANKENPHP_BIN="/usr/local/bin/frankenphp"
FWP_CADDY_CONFIG_DIR="/etc/frankenphp"
FWP_LOG_FILE="${FWP_LOG_DIR}/fwp.log"
FWP_DEFAULT_LOCALE="en_US"
FWP_REDIS_ENABLED="true"
FWP_REDIS_MAXMEM="128mb"
CONF
  log_success "Config: ${FWP_CONFIG_DIR}/fwp.conf"
}

print_success() {
  echo ""
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}${BOLD}  ✓ FrankenWP installed successfully!${NC}"
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}Create your first site:${NC}"
  echo -e "  ${CYAN}sudo fwp site create yourdomain.com${NC}"
  echo ""
  echo -e "  ${YELLOW}fwp site list${NC}          List sites"
  echo -e "  ${YELLOW}fwp stack status${NC}       Services + kernel status"
  echo -e "  ${YELLOW}fwp firewall status${NC}    Active firewall rules"
  echo -e "  ${YELLOW}fwp --help${NC}             Full help"
  echo ""
}

main() {
  print_banner
  check_root
  detect_os
  detect_arch
  install_base_deps
  install_frankenphp
  install_wpcli
  setup_dirs
  install_fwp_files
  apply_kernel_tuning
  setup_firewall
  setup_services
  write_config
  print_success
}
main "$@"
