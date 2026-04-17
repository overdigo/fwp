#!/usr/bin/env bash
# MODULE: log.sh — ANSI-colored logging functions
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
FWP_LOG_FILE="${FWP_LOG_FILE:-/var/log/fwp/fwp.log}"
_log_write() {
  local level="$1"; shift
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  mkdir -p "$(dirname "${FWP_LOG_FILE}")" 2>/dev/null || true
  echo "[${ts}] [${level}] $*" >> "${FWP_LOG_FILE}" 2>/dev/null || true
}
log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; _log_write "INFO"    "$*"; }
log_success() { echo -e "${GREEN}[✓]${NC}      $*"; _log_write "SUCCESS" "$*"; }
log_warn()    { echo -e "${YELLOW}[!]${NC}      $*"; _log_write "WARN"    "$*"; }
log_error()   { echo -e "${RED}[✗]${NC}      $*" >&2; _log_write "ERROR"  "$*"; }
log_fatal()   { echo -e "${RED}[FATAL]${NC}  $*" >&2; _log_write "FATAL"  "$*"; exit 1; }
log_step()    { echo -e "\n${CYAN}${BOLD}━━ $* ${NC}"; _log_write "STEP"   "$*"; }
log_debug()   { [[ "${FWP_DEBUG:-0}" == "1" ]] && echo -e "${BOLD}[DEBUG]${NC}  $*"; }
