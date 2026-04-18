#!/usr/bin/env bash
# FrankenWP Security Audit Tool
# Usage: ./security_audit.sh <domain> [ip]

set -euo pipefail

DOMAIN="${1:-}"
IP="${2:-127.0.0.1}"

if [[ -z "${DOMAIN}" ]]; then
    echo "Usage: $0 <domain> [ip]"
    exit 1
fi

BOLD="\033[1m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
NC="\033[0m"

echo -e "${BOLD}${CYAN}Auditing Security for: ${DOMAIN}${NC}"
echo "──────────────────────────────────────────"

echo -e "\n${BOLD}1. Redirect Chain & HSTS Audit${NC}"
protocols=("http" "https")
variants=("${DOMAIN}" "www.${DOMAIN}")

for proto in "${protocols[@]}"; do
    for var in "${variants[@]}"; do
        port=80; [[ "${proto}" == "https" ]] && port=443
        echo -n "  Testing ${proto}://${var} -> "
        curl -4Ik "${proto}://${var}" --resolve "${var}:${port}:${IP}" 2>/dev/null | \
            grep -Ei "HTTP/|location:|strict-transport-security:|server:" | tr '\n' ' '
        echo ""
    done
done

echo -e "\n${BOLD}2. TLS Version Handshake${NC}"
for ver in "1.2" "1.3"; do
    echo -n "  Testing TLS ${ver}: "
    echo | openssl s_client -connect "${IP}:443" -servername "${DOMAIN}" "-tls1_${ver#*.}" 2>/dev/null | \
        grep -Ei "Protocol  :|Cipher    :" | tr '\n' ' ' || echo -n "FAILED"
    echo ""
done

echo -e "\n${BOLD}3. SNI Requirement Check${NC}"
echo -n "  Connecting without SNI: "
sni_check=$(echo | openssl s_client -connect "${IP}:443" 2>&1 || true)
if echo "${sni_check}" | grep -Ei "alert|error" > /dev/null; then
    echo -e "${GREEN}Passed (Connection Rejected)${NC}"
else
    echo -e "${YELLOW}Warning (Server accepted connection without SNI)${NC}"
fi

echo -e "\n${BOLD}4. HTTP/2 Support${NC}"
echo -n "  Checking HTTP/2: "
if curl -4Ik --http2 "https://${DOMAIN}" --resolve "${DOMAIN}:443:${IP}" 2>/dev/null | grep -q "HTTP/2"; then
    echo -e "${GREEN}Enabled${NC}"
else
    echo -e "${YELLOW}Disabled or not supported by curl version${NC}"
fi

echo -e "\n${BOLD}${GREEN}Audit Complete.${NC}"
