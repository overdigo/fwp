#!/usr/bin/env bash
fwp_print_banner() {
  echo -e "${CYAN}${BOLD}"
  cat << 'ART'
  ___              _            __      ______
 / __\_ _ __ _ _ _| | _____ _ _\ \    / /  _ \
/ _\| '_/ _` | ' \ |/ / -_) ' \\ \/\/ /| |_) |
\/___|_| \__,_|_||_|_\_\___|_||_|\__  / |  __/
                                      \/  |_|
ART
  echo -e "${NC}${BOLD}  WordPress + FrankenPHP — Automated CLI Tool${NC}\n"
}
