#!/usr/bin/env bash
site_delete() {
  local domain="${1:-}" no_prompt=false
  [[ -z "${domain}" ]] && log_fatal "Usage: fwp site delete <domain>"
  shift; [[ "${1:-}" == "--no-prompt" ]] && no_prompt=true
  _site_exists "${domain}" || log_fatal "Site '${domain}' not found."
  source "/etc/fwp/sites/${domain}.conf"
  if [[ "${no_prompt}" == "false" ]]; then
    echo -e "${RED}${BOLD}WARNING: This action is irreversible!${NC}"
    echo -e "  Deletes all files, database, and Caddyfile for: ${BOLD}${domain}${NC}"
    read -rp "  Type the domain name to confirm: " confirm
    [[ "${confirm}" != "${domain}" ]] && { echo "Cancelled."; exit 0; }
  fi
  log_step "Removing ${domain}..."
  source "${FWP_HOME}/src/stack/mariadb.sh"
  rm -f "/etc/frankenphp/sites-enabled/${domain}.conf"
  rm -f "/etc/frankenphp/sites-available/${domain}.conf"
  _frankenphp_reload
  [[ -n "${DB_NAME:-}" ]] && stack_mariadb_drop_db "${DB_NAME}" "${DB_USER:-}"
  rm -rf "/var/www/${domain}"
  rm -f "/etc/cron.d/fwp-${domain//./-}"
  rm -f "/etc/fwp/sites/${domain}.conf"
  
  # Remove from /etc/hosts
  sed -i "/127.0.0.1 ${domain} www.${domain}/d" /etc/hosts
  
  log_success "Site '${domain}' removed."
}
