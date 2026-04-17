#!/usr/bin/env bash
# MODULE: redis.sh — Redis installation and optimization
stack_redis_install() {
  if systemctl is-active --quiet redis-server 2>/dev/null; then
    log_warn "Redis already running. Skipping."; return 0
  fi
  # Core packages are already installed via install_base_deps
  log_step "Initializing Redis 8 Server..."
  _redis_optimize_config
  log_success "Redis installed and running (Official Repo)"
}

_redis_optimize_config() {
  local conf; conf=$(find /etc/redis -name "redis.conf" 2>/dev/null | head -1 || true)
  [[ -z "${conf}" ]] && conf="/etc/redis/redis.conf"
  [[ ! -f "${conf}" ]] && return 0

  local maxmem="${FWP_REDIS_MAXMEM:-128mb}"

  # Apend optimizations at EOF (Redis overrides earlier directives with the last one defined)
  cat >> "${conf}" << EOF

# FrankenWP — Advanced Redis Tuning
io-threads 4
io-threads-do-reads yes
appendonly no
maxmemory ${maxmem}
maxmemory-policy allkeys-lru
activedefrag yes
active-defrag-ignore-bytes 50mb
active-defrag-threshold-lower 10
active-defrag-threshold-upper 100
active-defrag-cycle-min 1
active-defrag-cycle-max 25
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
activerehashing yes
tcp-keepalive 60
hz 5
protected-mode no
loglevel warning
EOF

  systemctl restart redis-server 2>/dev/null || true
  log_success "Redis optimized (IO threads, Defag, MaxMem=${maxmem})"
}
