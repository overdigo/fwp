#!/usr/bin/env bash
# MODULE: mariadb.sh — MariaDB installation and database management
stack_mariadb_install() {
  if systemctl is-active --quiet mysql 2>/dev/null; then
    log_warn "MySQL already running. Skipping."; return 0
  fi
  # Core packages are already installed via install_base_deps
  log_step "Initializing MySQL 8.4 Server..."
  _mariadb_optimize_config
  log_success "MySQL 8.4 installed and running"
}

_mariadb_optimize_config() {
  local sys_ram_mb; sys_ram_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
  
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

  mkdir -p /etc/mysql/mysql.conf.d
  cat > /etc/mysql/mysql.conf.d/99-frankenwp.cnf << CNF
# FrankenWP — MySQL 8.4 Performance Tuning (Dynamic Profile: ~${sys_ram_mb}MB RAM)
[mysqld]
skip_name_resolve       = 1
max_connections         = ${mc}
innodb_buffer_pool_size = ${i_bp}
innodb_redo_log_capacity = ${i_rlc}
innodb_flush_method     = O_DIRECT
innodb_file_per_table   = 1
thread_cache_size       = ${tcs}
table_definition_cache  = ${tdc}
tmp_table_size          = ${tmp}
max_heap_table_size     = ${tmp}
table_open_cache        = ${toc}
character-set-server    = utf8mb4
collation-server        = utf8mb4_unicode_ci
log_error_verbosity     = 1
general_log             = 0
slow_query_log          = 0
performance_schema      = OFF
CNF
  systemctl restart mysql
  log_success "MySQL optimized for ~${sys_ram_mb}MB RAM (InnoDB buffer ${i_bp})"
}

stack_mariadb_create_db() {
  local dbname="$1" dbuser="$2" dbpass="$3"
  log_info "Creating database '${dbname}'..."
  local retry=0
  while ! mysql --defaults-file=/etc/mysql/debian.cnf -e "SELECT 1" >/dev/null 2>&1 && ! mysql -u root -e "SELECT 1" >/dev/null 2>&1; do
    if [ "${retry}" -ge 10 ]; then
      log_warn "MySQL not ready after 20 seconds..."
      break
    fi
    sleep 2
    retry=$((retry+1))
  done

  local q="CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
           CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';
           CREATE USER IF NOT EXISTS '${dbuser}'@'127.0.0.1' IDENTIFIED BY '${dbpass}';
           GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
           GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'127.0.0.1';
           FLUSH PRIVILEGES;"
  mysql --defaults-file=/etc/mysql/debian.cnf -e "$q" || mysql -u root -e "$q"
  log_success "Database '${dbname}' created"
}

stack_mariadb_drop_db() {
  local dbname="$1" dbuser="$2"
  local q="DROP DATABASE IF EXISTS \`${dbname}\`;
           DROP USER IF EXISTS '${dbuser}'@'localhost';
           DROP USER IF EXISTS '${dbuser}'@'127.0.0.1';
           FLUSH PRIVILEGES;"
  mysql --defaults-file=/etc/mysql/debian.cnf -e "$q" 2>/dev/null || mysql -u root -e "$q" 2>/dev/null || true
  log_success "Database '${dbname}' dropped"
}
