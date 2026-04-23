#!/usr/bin/env bash
#
# Module: stack/systemd-limits.sh
# Purpose: Applies systemd cgroup resource limits and accounting for core services
#          (FrankenPHP, MariaDB, Redis) to optimize high-load stress scenarios.
#

set -euo pipefail

# Applica as regras de cgroup (Resource Limits e Accounting)
stack_systemd_limits_apply() {
    log_step "Applying systemd resource limits and accounting..."

    # FrankenPHP
    mkdir -p /etc/systemd/system/frankenphp.service.d
    cat <<EOF > /etc/systemd/system/frankenphp.service.d/99-resource-limits.conf
[Service]
MemoryAccounting=yes
CPUAccounting=yes
TasksAccounting=yes
# Aumenta tarefas para suportar muitas conexões/workers
TasksMax=8192
# Previne uso de swap para evitar degradação drástica de performance
MemorySwapMax=0
# Leve vantagem na concorrência de CPU (padrão é 100)
CPUWeight=150
EOF

    # MariaDB
    mkdir -p /etc/systemd/system/mariadb.service.d
    cat <<EOF > /etc/systemd/system/mariadb.service.d/99-resource-limits.conf
[Service]
MemoryAccounting=yes
CPUAccounting=yes
TasksAccounting=yes
# Prioridade no I/O de disco
IOWeight=200
# DB já gerencia sua própria RAM (Buffer Pool), swap destruiria a latência
MemorySwapMax=0
TasksMax=4096
EOF

    # Redis
    mkdir -p /etc/systemd/system/redis-server.service.d
    cat <<EOF > /etc/systemd/system/redis-server.service.d/99-resource-limits.conf
[Service]
MemoryAccounting=yes
CPUAccounting=yes
TasksAccounting=yes
# Sendo um datastore em memória, swap é catastrófico
MemorySwapMax=0
EOF

    systemctl daemon-reload
    
    # Reinicia os serviços caso existam e estejam rodando
    systemctl restart redis-server 2>/dev/null || true
    systemctl restart mariadb 2>/dev/null || true
    systemctl restart frankenphp 2>/dev/null || true

    log_success "Systemd resource limits applied successfully."
}

# Remove as regras para permitir teste "sem limites" (baseline)
stack_systemd_limits_remove() {
    log_step "Removing systemd resource limits..."

    rm -f /etc/systemd/system/frankenphp.service.d/99-resource-limits.conf
    rm -f /etc/systemd/system/mariadb.service.d/99-resource-limits.conf
    rm -f /etc/systemd/system/redis-server.service.d/99-resource-limits.conf

    systemctl daemon-reload

    systemctl restart redis-server 2>/dev/null || true
    systemctl restart mariadb 2>/dev/null || true
    systemctl restart frankenphp 2>/dev/null || true

    log_success "Systemd resource limits removed. Services reverted to default systemd behavior."
}

# Exibe o status atual e contabilização (se ativo)
stack_systemd_limits_status() {
    log_info "=== Systemd Resource Accounting & Limits ==="
    
    for svc in frankenphp mariadb redis-server; do
        if systemctl is-active --quiet "\${svc}"; then
            log_info "Status for \${svc}:"
            # O grep extrai as linhas que contêm métricas de uso do systemctl status
            systemctl status "\${svc}" | grep -E "Memory:|CPU:|Tasks:" || log_info "  (No accounting data available)"
            echo "---"
        fi
    done
    
    log_info "Tip: Run 'systemd-cgtop' to see real-time cgroup resource consumption."
}
