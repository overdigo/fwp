#!/usr/bin/env bash
# MODULE: os.sh — OS detection and package manager abstraction
fwp_os_detect() {
  [[ ! -f /etc/os-release ]] && log_fatal "Cannot detect OS: /etc/os-release not found."
  source /etc/os-release
  export OS_ID="${ID}" OS_VERSION="${VERSION_ID}" OS_CODENAME="${VERSION_CODENAME:-}"
  case "${OS_ID}" in
    debian)
      case "${OS_VERSION}" in
        12) export OS_NAME="Debian 12 (Bookworm)" ;;
        13) export OS_NAME="Debian 13 (Trixie)" ;;
        *)  log_fatal "Unsupported Debian ${OS_VERSION}. Supported: 12, 13" ;;
      esac ;;
    ubuntu)
      case "${OS_VERSION}" in
        22.04) export OS_NAME="Ubuntu 22.04 LTS (Jammy)" ;;
        24.04) export OS_NAME="Ubuntu 24.04 LTS (Noble)" ;;
        26.04) export OS_NAME="Ubuntu 26.04 LTS" ;;
        *)     log_fatal "Unsupported Ubuntu ${OS_VERSION}. Supported: 22.04, 24.04, 26.04" ;;
      esac ;;
    *) log_fatal "Unsupported OS '${OS_ID}'. Supported: Debian 12/13, Ubuntu 22.04/24.04/26.04" ;;
  esac
}
fwp_os_pkg_update()    { DEBIAN_FRONTEND=noninteractive apt-get update -qq; }
fwp_os_pkg_install()   { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"; }
fwp_os_check_arch() {
  local arch; arch=$(uname -m)
  case "${arch}" in
    x86_64)  export SYS_ARCH="x86_64";  export FPH_ARCH="x86_64" ;;
    aarch64) export SYS_ARCH="aarch64"; export FPH_ARCH="aarch64" ;;
    *) log_fatal "Unsupported architecture: '${arch}'. Supported: x86_64, aarch64." ;;
  esac
}
