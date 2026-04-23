#!/usr/bin/env bash
# ==============================================================================
# FrankenWP — Bootstrap Installer
# Usage:
#   wget -qO fwp https://cdn.jsdelivr.net/gh/overdigo/fwp@main/install.sh
#   sudo bash fwp
# Supported: Debian 12/13 | Ubuntu 22.04 / 24.04 / 26.04
# ==============================================================================
set -euo pipefail

FWP_VERSION="0.5.0"
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

setup_dns() {
  log_step "Configuring DNS (Cloudflare/Google)..."
  # Try systemd-resolved first
  if [[ -d /etc/systemd/resolved.conf.d ]] || [[ -f /etc/systemd/resolved.conf ]]; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/fwp-dns.conf << EOF
[Resolve]
DNS=1.1.1.1 8.8.8.8 9.9.9.9
FallbackDNS=1.0.0.1 8.8.4.4 149.112.112.112
EOF
    systemctl restart systemd-resolved 2>/dev/null || true
  fi
  
  # Also force /etc/resolv.conf just in case (may fail in some containers, that's okay)
  echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9" > /etc/resolv.conf 2>/dev/null || true
  log_success "DNS configured"
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
        22.04*) OS_NAME="Ubuntu 22.04 LTS (Jammy)" ;;
        24.04*) OS_NAME="Ubuntu 24.04 LTS (Noble)" ;;
        25.10*|26.04*) OS_NAME="Ubuntu 26.04 LTS" ;;
        *)     log_fatal "Unsupported Ubuntu ${OS_VERSION}. Supported: 22.04, 24.04, 26.04" ;;
      esac ;;
    *) log_fatal "Unsupported OS '${OS_ID}'. Supported: Debian 12/13, Ubuntu 22.04/24.04/26.04" ;;
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
  log_step "Installing base dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || true
  apt-get install -y -qq curl wget gnupg lsb-release debconf-utils ca-certificates \
    git unzip tar ufw fail2ban logrotate cron sudo bash-completion nano >/dev/null 2>&1
  log_success "Base dependencies installed"

  # Avançado: scopatz/nanorc (Syntax Highlighting)
  log_step "Installing advanced nano syntax highlighting..."
  wget https://raw.githubusercontent.com/scopatz/nanorc/master/install.sh -O- | sh >/dev/null 2>&1
  log_success "Advanced nanorc installed"

  # Ativar Bash Completion apenas para o Root
  log_step "Enabling bash-completion for root user..."
  # Limpa qualquer tentativa anterior no global (segurança)
  sed -i '/# Enable bash completion in interactive shells/,/fi/d' /etc/bash.bashrc 2>/dev/null || true
  
  # Busca específica para o anexo real (evita bater nos comentários padrão do bashrc)
  if ! grep -q "Enable bash completion for root" ~/.bashrc; then
    cat >> ~/.bashrc << 'EOF'

# Enable bash completion for root
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi
EOF
  fi
  log_success "Bash completion enabled for root"

  # Configurar Aliases
  log_step "Configuring aliases..."
  local ALIAS_FILE="/tmp/fwp_aliases"
  cat > "${ALIAS_FILE}" << 'EOF'

# --- FrankenWP Aliases ---
alias fpre='systemctl restart frankenphp'
alias fpst='systemctl status frankenphp'

# --- Listagens Rápidas ---
alias l='ls -CF'             # Lista simples em colunas, com tipos de arquivo.
alias ll='ls -alFh'          # A lista mais completa: todos os arquivos, detalhes, legível.
alias la='ls -Alh'           # Alternativa mais limpa ao 'll' (sem '.' e '..').

# --- Listagens Ordenadas ---
alias ltr='ls -alFht'        # Lista por tempo (mais recentes primeiro).
alias lt='ls -alFhtr'        # Lista por tempo, do mais ANTIGO para o mais recente (Reverse).
alias lkr='ls -lSh'          # Lista por tamanho, MAIORES primeiro.
alias lk='ls -lShr'          # Lista por tamanho, MENORES primeiro (reverso).

# --- Rede e IP ---
alias ip4='echo -e "\e[1;93m$(wget -qO- ipinfo.io/ip || curl -sL ipinfo.io/ip)\e[0m"'
alias ip6='echo -e "\e[1;93m$(wget -qO- v6.ipinfo.io/ip || curl -sL v6.ipinfo.io/ip)\e[0m"'
alias ip='ip -c'

# --- Utilitários ---
alias systemctl='nice -n -15 systemctl'
EOF

  # Aplicar no .bashrc do root e do usuário (se invocado via sudo)
  local TARGETS=("/root/.bashrc")
  if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    local USER_HOME
    USER_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
    [[ -f "${USER_HOME}/.bashrc" ]] && TARGETS+=("${USER_HOME}/.bashrc")
  fi

  for target in "${TARGETS[@]}"; do
    if ! grep -q "FrankenWP Aliases" "${target}"; then
      cat "${ALIAS_FILE}" >> "${target}"
    fi
  done
  rm -f "${ALIAS_FILE}"
  log_success "Aliases configured for root and ${SUDO_USER:-user}"

  # Configurações Adicionais do Nano
  log_step "Configuring nano settings..."
  cat > /etc/nanorc << 'EOF'
set linenumbers
set mouse
set softwrap
set tabsize 4
set tabstospaces
# Syntax highlighting from scopatz/nanorc
include "~/.nano/*.nanorc"
EOF
  log_success "Nano settings configured"
}

install_mariadb() {
  local db_type="${FWP_DB_TYPE:-mariadb}"
  local db_version="${FWP_DB_VERSION:-default}"
  log_step "Installing ${db_type^} server..."

  case "${db_type}" in
    mysql)
      _db_setup_mysql_repo "${db_version}"
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-server
      ;;
    mariadb)
      if [[ "${db_version}" != "default" ]]; then
        _db_setup_mariadb_repo "${db_version}"
      fi
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mariadb-server
      ;;
  esac

  _db_optimize_config "${db_type}"
  log_success "${db_type^} installed and optimized"
}

_db_setup_mysql_repo() {
  local version="$1"
  log_info "Adding official MySQL repository (Version: ${version})..."
  local select_version="mysql-8.4-lts"
  [[ "${version}" == "8.0" ]] && select_version="mysql-8.0"
  [[ "${version}" == "9.0" ]] && select_version="mysql-innovation"
  local repo_url="https://dev.mysql.com/get/mysql-apt-config_0.8.32-1_all.deb"
  local tmp_deb="/tmp/mysql-repo.deb"
  curl -sSL -o "${tmp_deb}" "${repo_url}"
  echo "mysql-apt-config mysql-apt-config/select-server select ${select_version}" | debconf-set-selections
  echo "mysql-apt-config mysql-apt-config/select-product select Ok" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${tmp_deb}"
  apt-get update -qq || true
  rm -f "${tmp_deb}"
}

_db_setup_mariadb_repo() {
  local version="$1"
  log_info "Adding official MariaDB Foundation repository (Version: ${version})..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL -o /etc/apt/keyrings/mariadb-keyring.pgp 'https://mariadb.org/mariadb_release_signing_key.pgp'
  cat > /etc/apt/sources.list.d/mariadb.sources << EOF
X-Repolib-Name: MariaDB
Types: deb
URIs: https://mirrors.layeronline.com/mariadb/repo/${version}/${OS_ID}
Suites: ${OS_CODENAME}
Components: main
Signed-By: /etc/apt/keyrings/mariadb-keyring.pgp
EOF
  apt-get update -qq || true
}

_db_optimize_config() {
  local type="$1"
  local sys_ram_mb; sys_ram_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
  local i_bp="128M" i_rlc="64M" tcs="16" tdc="1000" toc="1000" tmp="16M" mc="20"
  if [ "$sys_ram_mb" -ge 15000 ]; then i_bp="4G" i_rlc="1G" tcs="128" tdc="8000" toc="8000" tmp="128M" mc="150"
  elif [ "$sys_ram_mb" -ge 7500 ]; then i_bp="2G" i_rlc="512M" tcs="64" tdc="4000" toc="4000" tmp="64M" mc="100"
  elif [ "$sys_ram_mb" -ge 3500 ]; then i_bp="1G" i_rlc="256M" tcs="40" tdc="2500" toc="2500" tmp="48M" mc="60"
  elif [ "$sys_ram_mb" -ge 1500 ]; then i_bp="512M" i_rlc="128M" tcs="24" tdc="1500" toc="1500" tmp="24M" mc="30"
  fi
  local conf_file="/etc/mysql/mariadb.conf.d/99-frankenwp.cnf"
  [[ "${type}" == "mysql" ]] && conf_file="/etc/mysql/mysql.conf.d/99-frankenwp.cnf"
  mkdir -p "$(dirname "${conf_file}")"
  cat > "${conf_file}" << CNF
[mysqld]
skip_name_resolve       = 1
max_connections         = ${mc}
innodb_buffer_pool_size = ${i_bp}
innodb_flush_method     = O_DIRECT
innodb_file_per_table   = 1
thread_cache_size       = ${tcs}
table_definition_cache  = ${tdc}
tmp_table_size          = ${tmp}
max_heap_table_size     = ${tmp}
table_open_cache        = ${toc}
character-set-server    = utf8mb4
collation-server        = utf8mb4_unicode_ci
skip_networking         = ON
socket                  = /run/mysqld/mysqld.sock
performance_schema      = OFF
CNF
  if [[ "${type}" == "mysql" ]]; then echo "innodb_redo_log_capacity = ${i_rlc}" >> "${conf_file}"
  else echo "innodb_log_file_size = ${i_rlc}" >> "${conf_file}"
  fi
  systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null || true
}

install_redis() {
  log_step "Installing Redis Server..."
  curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg --yes
  echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list
  apt-get update -qq || true
  apt-get install -y -qq redis >/dev/null 2>&1
  _redis_optimize_config
  log_success "Redis installed and optimized"
}

_redis_optimize_config() {
  local conf="/etc/redis/redis.conf"
  local sys_ram_mb; sys_ram_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
  local maxmem="128mb" io_threads="1"
  if [ "$sys_ram_mb" -ge 7500 ]; then maxmem="512mb"; io_threads="3"
  elif [ "$sys_ram_mb" -ge 3500 ]; then maxmem="384mb"; io_threads="2"
  elif [ "$sys_ram_mb" -ge 1500 ]; then maxmem="256mb"; io_threads="1"
  fi
  cat > "${conf}" << EOF
# --- TCP (descomentado para trocar para TCP) ---
# bind 127.0.0.1 ::1
# port 6379
# protected-mode yes
# tcp-backlog 4096
# tcp-keepalive 60
#
# --- Unix Socket ---
port 0
unixsocket /var/run/redis/redis-server.sock
unixsocketperm 770
# --- Common configs ---
timeout 0
daemonize yes
supervised systemd
pidfile /var/run/redis/redis-server.pid
loglevel warning
logfile /var/log/redis/redis-server.log
databases 16
io-threads ${io_threads}
io-threads-do-reads yes
maxmemory ${maxmem}
maxmemory-policy allkeys-lru
maxmemory-samples 10
appendonly no
save ""
activedefrag yes
active-defrag-ignore-bytes 100mb
active-defrag-threshold-lower 10
active-defrag-threshold-upper 75
active-defrag-cycle-min 1
active-defrag-cycle-max 15
activerehashing yes
hz 10
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
lazyfree-lazy-user-del yes
EOF
  usermod -aG redis www-data 2>/dev/null || true
  systemctl restart redis-server 2>/dev/null || true
}

install_php_cli() {
  log_step "Installing PHP-CLI for stack automation..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq php-cli php-mysql php-xml php-curl php-mbstring php-zip php-gd php-intl php-redis
  
  # Configure memory limit for WP-CLI
  local php_ver; php_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
  local php_conf_dir="/etc/php/${php_ver}/cli/conf.d"
  mkdir -p "${php_conf_dir}"
  echo "memory_limit=1024M" > "${php_conf_dir}/99-frankenwp.ini"
  
  log_success "PHP-CLI installed: $(php -v | head -n1)"
}

install_frankenphp() {
  log_step "Installing FrankenPHP..."
  if command -v frankenphp &>/dev/null; then
    log_warn "Already installed: $(frankenphp version 2>&1 | head -1)"; return 0
  fi
  detect_arch
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
  
  # Configure global PHP settings (for web server)
  mkdir -p /etc/frankenphp/conf.d
  echo "memory_limit=1024M" > /etc/frankenphp/conf.d/99-frankenwp.ini

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
  log_success "WP-CLI installed: $(wp --version --allow-root 2>/dev/null)"
}

setup_dirs() {
  log_step "Creating directories..."
  mkdir -p "${FWP_HOME}"/{src/core,src/stack,src/site,templates,completions}
  mkdir -p "${FWP_CONFIG_DIR}/sites" "${FWP_LOG_DIR}"
  mkdir -p /etc/frankenphp/sites-{available,enabled} /var/www/.wp-cli/cache
  id www-data &>/dev/null || useradd -r -s /usr/sbin/nologin www-data
  chown -R www-data:www-data /var/www
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
      "src/stack/systemd-limits.sh"
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

install_autoxdp() {
  if [[ "${FWP_AUTO_XDP:-false}" == "true" ]]; then
    log_step "Installing Auto XDP (DDoS Protection & Port Whitelisting)..."
    curl --proto '=https' --tlsv1.2 -sSfL https://raw.githubusercontent.com/Kookiejarz/Auto_XDP/refs/heads/main/setup_xdp.sh | bash -s -- --force
    log_success "Auto XDP installed and active"
  fi
}

setup_firewall() {
  log_step "Configuring firewall (WordOps-based rules)..."
  source "${FWP_HOME}/src/core/log.sh"
  source "${FWP_HOME}/src/core/os.sh"
  source "${FWP_HOME}/src/stack/firewall.sh"
  stack_firewall_setup
  install_autoxdp
}

setup_services() {
  log_step "Configuring stack..."
  source "${FWP_HOME}/src/core/log.sh"
  source "${FWP_HOME}/src/core/os.sh"
  source "${FWP_HOME}/src/stack/frankenphp.sh"
  source "${FWP_HOME}/src/stack/mariadb.sh"
  source "${FWP_HOME}/src/stack/redis.sh"
  
  stack_setup_global_caddyfile
  stack_setup_php_config
  stack_setup_systemd_service
  
  stack_mariadb_install
  stack_redis_install
  
  systemctl enable --now frankenphp redis-server 2>/dev/null || true
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
FWP_DB_TYPE="${FWP_DB_TYPE}"
FWP_DB_VERSION="${FWP_DB_VERSION}"
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
}

main() {
  local db_type="mariadb"
  local db_version="default"
  
  # Simple arg parsing
  for arg in "$@"; do
    case "${arg}" in
      --mysql)     db_type="mysql" ;;
      --mariadb)   db_type="mariadb" ;;
      --db-version=*) db_version="${arg#*=}" ;;
      --autoxdp)   autoxdp_choice="yes" ;;
    esac
  done

  print_banner
  check_root
  setup_dns
  detect_os
  detect_arch

  # Interactive selection if not provided and not in silent mode
  if [[ "$*" != *"--mysql"* ]] && [[ "$*" != *"--mariadb"* ]]; then
    echo -e "\n${BOLD}Database Selection:${NC}"
    echo -e "  1) Use Distro Default (Recommended for stability)"
    echo -e "  2) MariaDB Foundation (Official Repository)"
    echo -e "  3) MySQL Oracle (Official Repository)"
    read -p "Select provider [1]: " db_provider_choice

    case "${db_provider_choice}" in
      2)
        db_type="mariadb"
        echo -e "\n  ${CYAN}Select MariaDB Version:${NC}"
        echo -e "    1) 10.11 (LTS)"
        echo -e "    2) 11.4"
        echo -e "    3) 11.8"
        read -p "    Choice [1]: " v_choice
        case "${v_choice}" in
          2) db_version="11.4" ;;
          3) db_version="11.8" ;;
          *) db_version="10.11" ;;
        esac
        ;;
      3)
        db_type="mysql"
        echo -e "\n  ${CYAN}Select MySQL Version:${NC}"
        echo -e "    1) 8.0"
        echo -e "    2) 8.4 (LTS)"
        echo -e "    3) 9.0 (Innovation)"
        read -p "    Choice [2]: " v_choice
        case "${v_choice}" in
          1) db_version="8.0" ;;
          3) db_version="9.0" ;;
          *) db_version="8.4" ;;
        esac
        ;;
      *)
        db_type="mariadb"
        db_version="default"
        # On Ubuntu 26.04, mysql-server is the default
        [[ "${OS_ID}" == "ubuntu" ]] && [[ "${OS_VERSION}" == "26.04" ]] && db_type="mysql"
        ;;
    esac
  fi

  if [[ -z "${autoxdp_choice:-}" ]]; then
    echo -e "\n${BOLD}DDoS Protection:${NC}"
    echo -e "  Do you want to install Auto XDP? (High-performance eBPF firewall)"
    read -p "  Install Auto XDP? [y/N]: " autoxdp_ans
    case "${autoxdp_ans}" in
      [Yy]* ) autoxdp_choice="yes" ;;
      * ) autoxdp_choice="no" ;;
    esac
  fi

  export FWP_DB_TYPE="${db_type}"
  export FWP_DB_VERSION="${db_version}"
  [[ "${autoxdp_choice}" == "yes" ]] && export FWP_AUTO_XDP="true" || export FWP_AUTO_XDP="false"

  install_base_deps
  install_mariadb
  install_redis
  install_php_cli
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
