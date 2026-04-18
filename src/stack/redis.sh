#!/usr/bin/env bash
# MODULE: redis.sh — Redis installation and optimization
stack_redis_install() {
  if systemctl is-active --quiet redis-server 2>/dev/null; then
    log_warn "Redis already running. Ensuring optimization..."
    _redis_optimize_config
    return 0
  fi
  # Core packages are already installed via install_base_deps
  log_step "Initializing Redis 8 Server..."
  _redis_optimize_config
  log_success "Redis installed and running (Official Repo)"
}

_redis_optimize_config() {
  local conf="/etc/redis/redis.conf"
  
  # Backup original if not already done
  if [[ -f "${conf}" && ! -f "${conf}.backup" ]]; then
    cp "${conf}" "${conf}.backup"
    log_info "Backup created: ${conf}.backup"
  fi

  local sys_ram_mb; sys_ram_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
  local maxmem="128mb"
  local io_threads="2"

  # Dynamic calculation based on RAM
  if [ "$sys_ram_mb" -ge 15000 ]; then      # ~16GB
    maxmem="768mb"; io_threads="5"
  elif [ "$sys_ram_mb" -ge 7500 ]; then     # ~8GB
    maxmem="512mb"; io_threads="4"
  elif [ "$sys_ram_mb" -ge 3500 ]; then     # ~4GB
    maxmem="384mb"; io_threads="3"
  elif [ "$sys_ram_mb" -ge 1500 ]; then     # ~2GB
    maxmem="256mb"; io_threads="2"
  fi

  log_info "Creating clean Redis config (Memory: ${maxmem}, IO Threads: ${io_threads})"

  # Create clean, optimized config from scratch
  cat > "${conf}" << EOF
# FrankenWP — Optimized Redis Config (Profile: ~${sys_ram_mb}MB RAM)
# Generated on $(date)

# Network & Security
port 0
unixsocket /var/run/redis/redis-server.sock
unixsocketperm 770
timeout 0
tcp-keepalive 60
daemonize yes
supervised systemd
pidfile /var/run/redis/redis-server.pid
loglevel warning
logfile /var/log/redis/redis-server.log
databases 16
always-show-logo no

# Performance & Threads
io-threads ${io_threads}
io-threads-do-reads yes
hz 5
activerehashing yes

# Memory Management
maxmemory ${maxmem}
maxmemory-policy allkeys-lru

# Persistence (Disabled for Object Cache performance)
appendonly no
save ""

# Lazy Freeing
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
replica-lazy-flush yes

# Active Defrag
activedefrag yes
active-defrag-ignore-bytes 50mb
active-defrag-threshold-lower 10
active-defrag-threshold-upper 100
active-defrag-cycle-min 1
active-defrag-cycle-max 25
EOF

  # Ensure www-data can access the socket
  usermod -aG redis www-data
  mkdir -p /var/run/redis
  chown redis:redis /var/run/redis
  chmod 755 /var/run/redis

  systemctl restart redis-server 2>/dev/null || true
  log_success "Redis config recreated and optimized."
}
