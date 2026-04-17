#!/usr/bin/env bash
site_list() {
  local d="/etc/fwp/sites"
  if [[ ! -d "${d}" ]] || [[ -z "$(ls -A "${d}" 2>/dev/null)" ]]; then
    echo -e "\n  ${YELLOW}No sites configured yet.${NC}"
    echo -e "  Run: ${CYAN}sudo fwp site create example.com${NC}\n"
    return 0
  fi
  echo ""
  echo -e "  ${BOLD}FrankenWP — Managed Sites${NC}"
  printf "  %-35s %-10s %-5s %-5s %s\n" "DOMAIN" "STATUS" "SSL" "REDIS" "CREATED"
  echo "  ──────────────────────────────────────────────────────────────────"
  for conf in "${d}"/*.conf; do
    [[ -f "${conf}" ]] || continue
    unset DOMAIN STATUS SSL_ENABLED REDIS_ENABLED CREATED_AT
    source "${conf}"
    local sc="${GREEN}"; [[ "${STATUS:-}" != "enabled" ]] && sc="${RED}"
    local ssl="✓"; [[ "${SSL_ENABLED:-}" != "true" ]] && ssl="✗"
    local redis="✓"; [[ "${REDIS_ENABLED:-}" != "true" ]] && redis="✗"
    printf "  ${sc}%-35s${NC} %-10s %-5s %-5s %s\n" \
      "${DOMAIN:-?}" "${STATUS:-?}" "${ssl}" "${redis}" "${CREATED_AT%T*}"
  done
  echo ""
}
