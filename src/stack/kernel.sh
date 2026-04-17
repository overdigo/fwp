#!/usr/bin/env bash
# ==============================================================================
# MODULE: kernel.sh — Kernel tuning and system limits
# Based on WordOps high-performance stack configuration
# REFS: https://github.com/WordOps/WordOps
#       https://gist.github.com/techgaun/958e117b730634fa8128
# ==============================================================================
SYSCTL_CONF="/etc/sysctl.d/99-frankenwp.conf"
LIMITS_CONF="/etc/security/limits.d/99-frankenwp.conf"
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/frankenphp.service.d"

stack_kernel_tune() {
  log_step "Applying kernel and network tuning (WordOps-based)..."
  _kernel_check_bbr
  _kernel_write_sysctl
  _kernel_apply_sysctl
  _kernel_write_limits
  _kernel_write_systemd_limits
  log_success "Kernel tuning applied"
}

_kernel_check_bbr() {
  if modprobe tcp_bbr 2>/dev/null; then
    BBR_AVAILABLE=true
    log_info "BBR TCP congestion control available"
  else
    BBR_AVAILABLE=false
    log_warn "BBR unavailable on this kernel — falling back to 'cubic'"
  fi
}

_kernel_write_sysctl() {
  log_info "Writing ${SYSCTL_CONF}..."
  local bbr_cc="cubic"
  [[ "${BBR_AVAILABLE:-false}" == "true" ]] && bbr_cc="bbr"

  cat > "${SYSCTL_CONF}" << SYSCTL
# ==============================================================================
# FrankenWP — Kernel Tuning (WordOps-based)
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# ==============================================================================

# --- FILE SYSTEM ---
# Maximum number of open file handles and inode cache entries
fs.file-max = 2097152

# --- VIRTUAL MEMORY ---
# Minimize swapping — keep data in RAM as long as possible
vm.swappiness = 10
vm.dirty_ratio = 60
vm.dirty_background_ratio = 2

# --- KERNEL SCHEDULER ---
# Delay process migration across CPU cores (improves cache locality)
kernel.sched_migration_cost_ns = 5000000

# --- NETWORK CORE ---
# Maximum incoming connection queue length
net.core.somaxconn = 65535
# Incoming packet backlog queue
net.core.netdev_max_backlog = 65536
# Socket receive buffers: default (30MB) / max (32MB)
net.core.rmem_default = 31457280
net.core.rmem_max = 33554432
# Socket send buffers: default (30MB) / max (32MB)
net.core.wmem_default = 31457280
net.core.wmem_max = 33554432
# Maximum option memory buffers
net.core.optmem_max = 25165824
# Fair Queue scheduler — required for BBR to function correctly
net.core.default_qdisc = fq

# --- TCP/IP ---
# Congestion control algorithm (BBR preferred, cubic fallback)
net.ipv4.tcp_congestion_control = ${bbr_cc}
# SYN flood protection
net.ipv4.tcp_syncookies = 1
# Reduce TIME_WAIT duration
net.ipv4.tcp_fin_timeout = 15
# Reuse TIME_WAIT sockets for new connections
net.ipv4.tcp_tw_reuse = 1
# Increase SYN backlog queue
net.ipv4.tcp_max_syn_backlog = 65536
# Extend local port range for outgoing connections
net.ipv4.ip_local_port_range = 1024 65535
# TCP memory: min / pressure / max (pages)
net.ipv4.tcp_mem = 786432 1048576 26777216
# Per-socket TCP read buffer: min / default / max
net.ipv4.tcp_rmem = 8192 87380 33554432
# Per-socket TCP write buffer: min / default / max
net.ipv4.tcp_wmem = 8192 65536 33554432
# UDP memory
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
SYSCTL
}

_kernel_apply_sysctl() {
  log_info "Applying sysctl parameters..."
  sysctl -e -q -p "${SYSCTL_CONF}" 2>/dev/null || \
    log_warn "Some sysctl params were skipped (containerized environment or unsupported)"
}

_kernel_write_limits() {
  log_info "Writing open file limits to ${LIMITS_CONF}..."
  cat > "${LIMITS_CONF}" << LIMITS
# FrankenWP — Open File Descriptor Limits
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
*    soft nproc  65535
*    hard nproc  65535
root soft nproc  65535
root hard nproc  65535
LIMITS
}

_kernel_write_systemd_limits() {
  # Raise limits for the FrankenPHP service unit
  mkdir -p "${SYSTEMD_OVERRIDE_DIR}"
  cat > "${SYSTEMD_OVERRIDE_DIR}/limits.conf" << UNIT
[Service]
LimitNOFILE=1048576
LimitNPROC=65535
UNIT
  systemctl daemon-reload
  log_success "systemd service limits updated"
}

stack_kernel_status() {
  echo ""
  echo -e "  ${BOLD}Kernel Tuning Status${NC}"
  echo "  ─────────────────────────────────────────────────"
  printf "  %-40s %s\n" "fs.file-max"                     "$(sysctl -n fs.file-max 2>/dev/null || echo '?')"
  printf "  %-40s %s\n" "vm.swappiness"                   "$(sysctl -n vm.swappiness 2>/dev/null || echo '?')"
  printf "  %-40s %s\n" "net.core.somaxconn"              "$(sysctl -n net.core.somaxconn 2>/dev/null || echo '?')"
  printf "  %-40s %s\n" "net.ipv4.tcp_congestion_control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  printf "  %-40s %s\n" "net.core.default_qdisc"          "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  printf "  %-40s %s\n" "Open file limit (ulimit -n)"     "$(ulimit -n 2>/dev/null || echo '?')"
  echo ""
}
