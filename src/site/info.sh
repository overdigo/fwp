#!/usr/bin/env bash
site_info() {
  local domain="${1:-}"; [[ -z "${domain}" ]] && log_fatal "Usage: fwp site info <domain>"
  local conf="/etc/fwp/sites/${domain}.conf"
  [[ ! -f "${conf}" ]] && log_fatal "Site '${domain}' not found."
  unset DOMAIN STATUS WEBROOT DB_NAME DB_USER DB_PASS WP_ADMIN_USER \
        WP_ADMIN_EMAIL SSL_ENABLED REDIS_ENABLED CREATED_AT
  source "${conf}"
  local proto="https"; [[ "${SSL_ENABLED:-}" != "true" ]] && proto="http"
  echo ""
  echo -e "  ${BOLD}Site: ${CYAN}${DOMAIN}${NC}"
  echo "  ─────────────────────────────────────────────"
  echo -e "  URL:       ${proto}://${DOMAIN}"
  echo -e "  Admin:     ${proto}://${DOMAIN}/wp-admin"
  echo -e "  Status:    ${STATUS:-?}"
  echo -e "  SSL:       ${SSL_ENABLED:-?}"
  echo -e "  Redis:     ${REDIS_ENABLED:-?}"
  echo -e "  Webroot:   ${WEBROOT:-?}"
  echo -e "  Database:  ${DB_NAME:-?}  (user: ${DB_USER:-?})"
  echo -e "  WP Admin:  ${WP_ADMIN_USER:-?}  (${WP_ADMIN_EMAIL:-?})"
  echo -e "  Created:   ${CREATED_AT:-?}"
  [[ -d "${WEBROOT:-}" ]] && echo -e "  Disk use:  $(du -sh "${WEBROOT}" 2>/dev/null | cut -f1)"
  echo ""
}
