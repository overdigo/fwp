#!/usr/bin/env bash
site_enable() {
  local domain="${1:-}"; [[ -z "${domain}" ]] && log_fatal "Usage: fwp site enable <domain>"
  _site_exists "${domain}" || log_fatal "Site '${domain}' not found."
  local avail="/etc/frankenphp/sites-available/${domain}.conf"
  [[ ! -f "${avail}" ]] && log_fatal "Caddyfile not found: ${avail}"
  ln -sf "${avail}" "/etc/frankenphp/sites-enabled/${domain}.conf"
  sed -i 's/^STATUS=.*/STATUS="enabled"/' "/etc/fwp/sites/${domain}.conf"
  _frankenphp_reload
  log_success "Site '${domain}' enabled."
}
