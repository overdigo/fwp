#!/usr/bin/env bash
# MODULE: utils.sh — Shared utility functions
_generate_password() {
  local length="${1:-24}"
  tr -dc 'A-Za-z0-9!@#%^&*' < /dev/urandom 2>/dev/null | head -c "${length}" || true
  echo
}
_generate_table_prefix() {
  local prefix; prefix=$(tr -dc 'a-z' < /dev/urandom | head -c 1)
  prefix+=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 3)
  echo "${prefix}_"
}
_generate_db_name() {
  echo "wp_${1//[.-]/_}" | cut -c1-64
}
_validate_domain() {
  local regex='^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
  if [[ ! "${1}" =~ ${regex} ]]; then
    log_fatal "Invalid domain: '${1}'. Example: mysite.com"
  fi
}
_site_exists()        { [[ -f "/etc/fwp/sites/${1}.conf" ]]; }
_frankenphp_reload() {
  if systemctl is-active --quiet frankenphp 2>/dev/null; then
    log_info "Reloading FrankenPHP..."
    systemctl reload frankenphp 2>/dev/null || systemctl restart frankenphp
    log_success "FrankenPHP reloaded"
  else
    log_info "Starting FrankenPHP..."
    systemctl start frankenphp
    log_success "FrankenPHP started"
  fi
}
_get_server_ip() {
  curl -sSf --max-time 5 https://api.ipify.org 2>/dev/null || \
  curl -sSf --max-time 5 https://ipinfo.io/ip  2>/dev/null || \
  hostname -I | awk '{print $1}'
}
