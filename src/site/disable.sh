#!/usr/bin/env bash
site_disable() {
  local domain="${1:-}"; [[ -z "${domain}" ]] && log_fatal "Usage: fwp site disable <domain>"
  _site_exists "${domain}" || log_fatal "Site '${domain}' not found."
  rm -f "/etc/frankenphp/sites-enabled/${domain}.conf"
  sed -i 's/^STATUS=.*/STATUS="disabled"/' "/etc/fwp/sites/${domain}.conf"
  _frankenphp_reload
  log_warn "Site '${domain}' disabled (files preserved)."
}
