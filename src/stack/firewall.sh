#!/usr/bin/env bash
# ==============================================================================
# MODULE: firewall.sh — UFW + Fail2Ban hardening
# Based on WordOps firewall configuration
# REFS: https://gist.github.com/VirtuBox/ec0ec0a55261456dc8da4b5cb55ede3c
#       WordOps/wo/cli/plugins/stack_pref.py
# ==============================================================================
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/frankenwp.conf"

stack_firewall_setup() {
  log_step "Configuring UFW firewall (WordOps-based rules)..."
  _firewall_install_deps
  _firewall_detect_ssh_port
  _firewall_apply_rules
  _firewall_setup_fail2ban
  log_success "Firewall configured and active"
}

_firewall_install_deps() {
  command -v ufw          &>/dev/null || fwp_os_pkg_install ufw
  command -v fail2ban-client &>/dev/null || fwp_os_pkg_install fail2ban
}

_firewall_detect_ssh_port() {
  # Read first uncommented Port directive from sshd_config
  SSH_PORT=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null \
    | awk '{print $2}' | head -1 || true)
  SSH_PORT="${SSH_PORT:-22}"
  log_info "Detected SSH port: ${SSH_PORT}"
}

_firewall_apply_rules() {
  log_info "Applying UFW rules..."

  ufw logging low
  ufw default allow outgoing
  ufw default deny incoming

  # SSH — rate-limited (max 6 connections per 30s per IP)
  ufw limit "${SSH_PORT}/tcp" comment 'SSH (rate-limited)'
  # Also limit default port 22 if using a custom SSH port
  if [[ "${SSH_PORT}" != "22" ]]; then
    ufw limit 22/tcp comment 'SSH default (rate-limited)'
  fi

  # HTTP — TCP only
  ufw allow 80/tcp comment 'HTTP'

  # HTTPS — TCP (TLS 1.2/1.3) + UDP (HTTP/3 via QUIC)
  # 443/udp is mandatory for FrankenPHP HTTP/3 support
  ufw allow 443/tcp comment 'HTTPS'
  ufw allow 443/udp comment 'HTTPS/3 QUIC'

  ufw --force enable

  log_success "UFW enabled"
  _firewall_print_summary
}

_firewall_print_summary() {
  echo ""
  echo -e "  ${BOLD}Active Firewall Rules${NC}"
  echo "  ────────────────────────────────────────────────"
  echo -e "  ${GREEN}ALLOW OUT${NC}  all"
  echo -e "  ${RED}DENY  IN${NC}   all (default)"
  echo -e "  ${YELLOW}LIMIT IN${NC}   ${SSH_PORT}/tcp  (SSH, rate-limited)"
  [[ "${SSH_PORT}" != "22" ]] && \
    echo -e "  ${YELLOW}LIMIT IN${NC}   22/tcp    (SSH default, rate-limited)"
  echo -e "  ${GREEN}ALLOW IN${NC}   80/tcp    (HTTP)"
  echo -e "  ${GREEN}ALLOW IN${NC}   443/tcp   (HTTPS / TLS)"
  echo -e "  ${GREEN}ALLOW IN${NC}   443/udp   (HTTP/3 QUIC)  ← required for FrankenPHP"
  echo ""
}

_firewall_setup_fail2ban() {
  log_info "Configuring Fail2Ban SSH jail..."
  mkdir -p /etc/fail2ban/jail.d
  cat > "${FAIL2BAN_JAIL}" << JAIL
# ==============================================================================
# FrankenWP — Fail2Ban Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# ==============================================================================

[DEFAULT]
bantime  = 3600
findtime = 300
maxretry = 5
banaction = ufw

[sshd]
enabled  = true
port     = ssh,${SSH_PORT}
filter   = sshd
logpath  = %(sshd_log)s
maxretry = 5
findtime = 300
bantime  = 3600
JAIL
  systemctl enable --now fail2ban 2>/dev/null || true
  systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true
  log_success "Fail2Ban: max 5 SSH retries / 5 min window / 1h ban"
}

stack_firewall_status() {
  echo ""
  echo -e "  ${BOLD}UFW Status${NC}"
  ufw status verbose 2>/dev/null || log_warn "UFW not active"
  echo ""
  echo -e "  ${BOLD}Fail2Ban — SSH Jail${NC}"
  fail2ban-client status sshd 2>/dev/null || log_warn "Fail2Ban not active"
  echo ""
}

stack_firewall_allow() {
  local port="${1:-}"
  [[ -z "${port}" ]] && log_fatal "Usage: fwp firewall allow <port>[/tcp|udp] [comment]"
  local comment="${2:-custom rule}"
  ufw allow "${port}" comment "${comment}"
  log_success "Rule added: ALLOW ${port}"
}

stack_firewall_deny() {
  local port="${1:-}"
  [[ -z "${port}" ]] && log_fatal "Usage: fwp firewall deny <port>[/tcp|udp]"
  ufw deny "${port}"
  log_success "Rule added: DENY ${port}"
}
