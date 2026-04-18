#!/usr/bin/env bash
# MODULE: mariadb.sh — MariaDB/MySQL installation and management

stack_mariadb_install() {
  local db_type="${FWP_DB_TYPE:-mariadb}"
  local db_version="${FWP_DB_VERSION:-default}"

  if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
    log_warn "Database server already running. Ensuring optimization..."
    _db_optimize_config "${db_type}"
    return 0
  fi

  log_step "Installing ${db_type^} (${db_version})..."

  case "${db_type}" in
    mysql)
      _db_setup_mysql_repo "${db_version}"
      fwp_os_pkg_install mysql-server
      ;;
    mariadb)
      if [[ "${db_version}" != "default" ]]; then
        _db_setup_mariadb_repo "${db_version}"
      fi
      fwp_os_pkg_install mariadb-server
      ;;
  esac

  _db_optimize_config "${db_type}"
  log_success "${db_type^} installed and optimized"
}

_db_setup_mysql_repo() {
  local version="$1"
  log_info "Adding official MySQL repository (Version: ${version})..."
  
  # Map version to mysql-apt-config selection
  local select_version="mysql-8.4-lts"
  [[ "${version}" == "8.0" ]] && select_version="mysql-8.0"
  [[ "${version}" == "9.0" ]] && select_version="mysql-innovation"

  local repo_url="https://dev.mysql.com/get/mysql-apt-config_0.8.32-1_all.deb"
  local tmp_deb="/tmp/mysql-repo.deb"
  curl -sSL -o "${tmp_deb}" "${repo_url}"
  
  echo "mysql-apt-config mysql-apt-config/select-server select ${select_version}" | debconf-set-selections
  echo "mysql-apt-config mysql-apt-config/select-product select Ok" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive fwp_os_pkg_install "${tmp_deb}"
  fwp_os_pkg_update
  rm -f "${tmp_deb}"
}

_db_setup_mariadb_repo() {
  local version="$1"
  log_info "Adding official MariaDB Foundation repository (Version: ${version})..."
  fwp_os_pkg_install curl apt-transport-https
  mkdir -p /etc/apt/keyrings
  curl -o /etc/apt/keyrings/mariadb-keyring.pgp 'https://mariadb.org/mariadb_release_signing_key.pgp'
  cat > /etc/apt/sources.list.d/mariadb.sources << EOF
X-Repolib-Name: MariaDB
Types: deb
URIs: https://mirrors.layeronline.com/mariadb/repo/${version}/${OS_ID}
Suites: ${OS_CODENAME}
Components: main
Signed-By: /etc/apt/keyrings/mariadb-keyring.pgp
EOF
  fwp_os_pkg_update
}

_db_optimize_config() {
  local type="$1"
  local sys_ram_mb; sys_ram_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
  
  # Advanced Tuning Profiles based on available RAM
  local i_bp="128M" i_rlc="64M" tcs="16" tdc="1000" toc="1000" tmp="16M" mc="20"
  
  if [ "$sys_ram_mb" -ge 15000 ]; then       # ~16GB
    i_bp="4G" i_rlc="1G" tcs="128" tdc="8000" toc="8000" tmp="128M" mc="150"
  elif [ "$sys_ram_mb" -ge 7500 ]; then      # ~8GB
    i_bp="2G" i_rlc="512M" tcs="64" tdc="4000" toc="4000" tmp="64M" mc="100"
  elif [ "$sys_ram_mb" -ge 5500 ]; then      # ~6GB
    i_bp="1536M" i_rlc="512M" tcs="48" tdc="3000" toc="3000" tmp="48M" mc="80"
  elif [ "$sys_ram_mb" -ge 3500 ]; then      # ~4GB
    i_bp="1G" i_rlc="256M" tcs="40" tdc="2500" toc="2500" tmp="48M" mc="60"
  elif [ "$sys_ram_mb" -ge 2500 ]; then      # ~3GB
    i_bp="768M" i_rlc="256M" tcs="32" tdc="2000" toc="2000" tmp="32M" mc="40"
  elif [ "$sys_ram_mb" -ge 1500 ]; then      # ~2GB
    i_bp="512M" i_rlc="128M" tcs="24" tdc="1500" toc="1500" tmp="24M" mc="30"
  fi

  local conf_file="/etc/mysql/mariadb.conf.d/99-frankenwp.cnf"
  [[ "${type}" == "mysql" ]] && conf_file="/etc/mysql/mysql.conf.d/99-frankenwp.cnf"
  mkdir -p "$(dirname "${conf_file}")"

  cat > "${conf_file}" << CNF
# FrankenWP — ${type^} Tuning (Profile: ~${sys_ram_mb}MB RAM)
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
# Networking — Disable TCP, use Socket only
skip_networking         = ON
socket                  = /run/mysqld/mysqld.sock

# Performance
performance_schema      = OFF
CNF

  # Redo Log / Log File Size handling
  if [[ "${type}" == "mysql" ]]; then
    # MySQL 8.0.30+ uses innodb_redo_log_capacity
    echo "innodb_redo_log_capacity = ${i_rlc}" >> "${conf_file}"
  else
    # MariaDB still uses innodb_log_file_size
    echo "innodb_log_file_size = ${i_rlc}" >> "${conf_file}"
  fi

  systemctl restart mysql 2>/dev/null || systemctl restart mariadb
  log_success "${type^} optimized for ~${sys_ram_mb}MB RAM (InnoDB buffer ${i_bp})"
}

stack_mariadb_create_db() {
  local dbname="$1" dbuser="$2" dbpass="$3"
  log_info "Creating database '${dbname}'..."
  
  local q="CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
           CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';
           CREATE USER IF NOT EXISTS '${dbuser}'@'127.0.0.1' IDENTIFIED BY '${dbpass}';
           GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
           GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'127.0.0.1';
           FLUSH PRIVILEGES;"
  
  if [[ -f /etc/mysql/debian.cnf ]]; then
    mysql --defaults-file=/etc/mysql/debian.cnf -e "$q"
  else
    mysql -u root -e "$q"
  fi
  log_success "Database '${dbname}' created"
}

stack_mariadb_drop_db() {
  local dbname="$1" dbuser="$2"
  local q="DROP DATABASE IF EXISTS \`${dbname}\`;
           DROP USER IF EXISTS '${dbuser}'@'localhost';
           DROP USER IF EXISTS '${dbuser}'@'127.0.0.1';
           FLUSH PRIVILEGES;"
  if [[ -f /etc/mysql/debian.cnf ]]; then
    mysql --defaults-file=/etc/mysql/debian.cnf -e "$q" 2>/dev/null || true
  else
    mysql -u root -e "$q" 2>/dev/null || true
  fi
  log_success "Database '${dbname}' dropped"
}

