#!/usr/bin/env bash
# ==============================================================================
# wp-clean.sh — Limpeza e otimização do banco de dados WordPress
#
# Descrição:
#   Remove lixo acumulado no banco (revisões, transients, orphans, spam, etc.),
#   otimiza tabelas e aplica índices via Index WP MySQL For Speed.
#   Gera um relatório completo em relatorio-limpeza.txt.
#
# ------------------------------------------------------------------------------
# Opções:
#
#   --path <dir>
#       Caminho raiz do WordPress. Padrão: . (diretório atual)
#       Pode ser definido via variável de ambiente: WP_PATH=/var/www/...
#
#   --report-only
#       Apenas leitura: mostra o que pode ser eliminado sem apagar nada.
#       Implica automaticamente --dry-run + --skip-backup + --with-caution.
#
#   --dry-run
#       Executa todas as verificações e exibe contagens, mas não apaga nada.
#       Diferente de --report-only: mantém os prompts de confirmação visíveis.
#
#   --with-caution
#       Inclui verificações de meta duplicado (post, user, comment, term meta).
#       Cada item exige confirmação manual antes de deletar.
#
#   --check-plugin <slug>
#       Busca restos de um plugin removido no banco de dados:
#       wp_options, wp_postmeta, wp_usermeta, wp_commentmeta, wp_termmeta
#       e tabelas extras com o slug no nome. Pede confirmação antes de deletar.
#
#   --skip-backup
#       Pula o backup inicial (wp db export). Útil em ambientes de teste.
#
#   --docker <container>
#       Executa todos os comandos WP-CLI dentro de um container Docker via
#       'docker exec <container> wp ...'. O --path deve apontar para o caminho
#       do WordPress DENTRO do container.
#
# ------------------------------------------------------------------------------
# Exemplos:
#
#   # Ver o que pode ser limpo sem alterar nada (modo diagnóstico)
#   ./wp-clean.sh --report-only
#
#   # Limpeza padrão com backup (recomendado em produção)
#   ./wp-clean.sh --path /var/www/meusite.com/htdocs
#
#   # Limpeza completa incluindo verificação de meta duplicado
#   ./wp-clean.sh --with-caution
#
#   # Verificar restos do plugin Jetpack após desinstalação
#   ./wp-clean.sh --check-plugin jetpack
#
#   # Verificar restos + limpeza completa
#   ./wp-clean.sh --check-plugin redirection --with-caution
#
#   # Diagnóstico em container Docker
#   ./wp-clean.sh --docker wordpress --report-only
#
#   # Limpeza em container Docker com path customizado
#   ./wp-clean.sh --docker meu-container --path /var/www/html
#
#   # Pular backup (ambiente de teste, já tem snapshot)
#   ./wp-clean.sh --skip-backup --with-caution
#
#   # Definir path via variável de ambiente
#   WP_PATH=/var/www/site.com/htdocs ./wp-clean.sh --report-only
#
# ------------------------------------------------------------------------------
# O que é limpo automaticamente (sem confirmação):
#   - Revisões de posts
#   - Auto-drafts
#   - Posts na lixeira
#   - Comentários spam e na lixeira
#   - Pingbacks e trackbacks
#   - Transients expirados
#   - Post meta e user meta órfãos (sem post/user pai)
#
# O que exige confirmação (--with-caution):
#   - oEmbed cache
#   - Comment meta e term meta órfãos
#   - Term relationships órfãos
#   - Meta duplicado (post, user, comment, term)
#   - REPAIR de tabelas
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Configuração padrão
# ------------------------------------------------------------------------------
WP_PATH="${WP_PATH:-.}"
REPORT="relatorio-limpeza.txt"
DATE=$(date +%Y%m%d-%H%M)
PLUGIN_CHECK=""
DRY_RUN=false
REPORT_ONLY=false
WITH_CAUTION=false
SKIP_BACKUP=false
DOCKER_CONTAINER=""

# ------------------------------------------------------------------------------
# Parsear argumentos
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)           WP_PATH="$2";            shift 2 ;;
        --check-plugin)   PLUGIN_CHECK="$2";       shift 2 ;;
        --docker)         DOCKER_CONTAINER="$2";   shift 2 ;;
        --report-only)    REPORT_ONLY=true;         shift   ;;
        --dry-run)        DRY_RUN=true;             shift   ;;
        --with-caution)   WITH_CAUTION=true;        shift   ;;
        --skip-backup)    SKIP_BACKUP=true;         shift   ;;
        *) echo "Opção desconhecida: $1"; exit 1 ;;
    esac
done

# --report-only implica dry-run + skip-backup + with-caution
if $REPORT_ONLY; then
    DRY_RUN=true
    SKIP_BACKUP=true
    WITH_CAUTION=true
fi

BACKUP_DIR="$(dirname "$WP_PATH")/backups"

# Montar comando WP-CLI: local ou via docker exec
if [[ -n "$DOCKER_CONTAINER" ]]; then
    WP="docker exec $DOCKER_CONTAINER wp --path=$WP_PATH"
else
    WP="wp --path=$WP_PATH"
fi

# ------------------------------------------------------------------------------
# Helpers de saída
# ------------------------------------------------------------------------------
section() {
    local line
    line=$(printf '=%.0s' {1..60})
    echo -e "\n${line}\n  $*\n${line}" | tee -a "$REPORT"
}
log()  { echo "" | tee -a "$REPORT"; echo "### $*" | tee -a "$REPORT"; }
info() { echo "    $*" | tee -a "$REPORT"; }
ok()   { echo "  [OK] $*" | tee -a "$REPORT"; }
skip() {
    if $REPORT_ONLY; then
        echo "  [RELATÓRIO] $*" | tee -a "$REPORT"
    else
        echo "  [--] $* (dry-run)" | tee -a "$REPORT"
    fi
}
warn() { echo "  [!]  $*" | tee -a "$REPORT"; }

run() {
    echo "    \$ $*" | tee -a "$REPORT"
    "$@" 2>&1 | tee -a "$REPORT" || true
}

db_query() { $WP db query "$1" --skip-column-names 2>/dev/null; }

# Exibe tamanho de tabelas em MB com 2 casas decimais
show_db_size() {
    local db_name
    db_name=$($WP db query "SELECT DATABASE();" --skip-column-names 2>/dev/null \
              | tr -d '[:space:]') || db_name="database"

    $WP db size "$@" --size_format=b 2>&1 \
    | awk -v db="$db_name" '
        # Linha 1 é número puro → wp db size sem --tables (total do banco)
        NR==1 && /^[0-9]+$/ {
            printf "%-45s %8.2f MB\n", db, $1/1024/1024
            next
        }
        # Linha de cabeçalho normal (com --tables)
        NR==1 { printf "%-45s %10s\n", $1, "Size"; next }
        # Linhas de dados
        { printf "%-45s %8.2f MB\n", $1, $2/1024/1024 }
    ' \
    | tee -a "$REPORT" || true
}


# Conta linhas afetadas por uma query SELECT COUNT(*)
db_count() { db_query "SELECT COUNT(*) FROM ($1) AS _c;" 2>/dev/null || echo 0; }

# Apaga em lotes de 500 IDs via WP-CLI post delete
delete_posts_by_type() {
    local post_type="$1" post_status="${2:-any}"
    local args="--post_type=${post_type} --post_status=${post_status} --format=ids"
    local count
    count=$($WP post list $args --format=count 2>/dev/null || echo 0)
    info "Total: $count"
    [[ "$count" -eq 0 ]] && return

    if $DRY_RUN; then skip "Deletar $count posts ($post_type/$post_status)"; return; fi

    # Deleta em lotes para não explodir o shell com milhares de IDs
    local batch=500 offset=0
    while true; do
        local ids
        ids=$($WP post list $args --posts_per_page=$batch --offset=$offset 2>/dev/null || true)
        [[ -z "$ids" ]] && break
        run $WP post delete $ids --force --quiet
        offset=$(( offset + batch ))
    done
    ok "$count posts removidos ($post_type/$post_status)"
}

delete_comments_by() {
    local flag="$1" value="$2"
    local count
    count=$($WP comment list "--${flag}=${value}" --format=count 2>/dev/null || echo 0)
    info "Total: $count"
    [[ "$count" -eq 0 ]] && return

    if $DRY_RUN; then skip "Deletar $count comentários (${flag}=${value})"; return; fi

    local ids
    ids=$($WP comment list "--${flag}=${value}" --format=ids)
    run $WP comment delete $ids --force
    ok "$count comentários removidos (${flag}=${value})"
}

# Mostra resultado e pede confirmação antes de executar SQL perigoso
confirm_sql() {
    local description="$1" count_sql="$2" delete_sql="$3"
    local count
    count=$(db_query "$count_sql" | tr -d '[:space:]')
    info "Encontrados: ${count:-0}"
    [[ "${count:-0}" -eq 0 ]] && return

    if $DRY_RUN; then skip "Executar: $description"; return; fi

    echo ""
    read -r -p "  ⚠  $description ($count registros) — confirmar? [s/N] " ans
    if [[ "${ans,,}" == "s" ]]; then
        db_query "$delete_sql" >> "$REPORT" 2>&1 || true
        ok "Concluído."
    else
        warn "Pulado pelo usuário."
    fi
}

# ==============================================================================
# INÍCIO — cabeçalho do relatório
# ==============================================================================
{
    echo "wp-clean.sh — $(date)"
    echo "WP_PATH:          $WP_PATH"
    echo "MODO:             $(  $REPORT_ONLY && echo 'APENAS RELATÓRIO' \
                             || ($DRY_RUN   && echo 'DRY-RUN') \
                             || echo 'LIMPEZA COMPLETA')"
    echo "WITH_CAUTION:     $WITH_CAUTION"
    [[ -n "$DOCKER_CONTAINER" ]] && echo "DOCKER:           $DOCKER_CONTAINER"
    [[ -n "$PLUGIN_CHECK"     ]] && echo "CHECK_PLUGIN:     $PLUGIN_CHECK"
    echo ""
} > "$REPORT"


# ==============================================================================
# 1. BACKUP
# ==============================================================================
section "BACKUP"
if $SKIP_BACKUP; then
    warn "Backup ignorado (--skip-backup)"
else
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/backup-$DATE.sql"
    info "Exportando para: $BACKUP_FILE"
    if $DRY_RUN; then
        skip "wp db export"
    else
        run $WP db export "$BACKUP_FILE"
        ok "Backup salvo: $BACKUP_FILE"
    fi
fi

# ==============================================================================
# 2. TAMANHO INICIAL
# ==============================================================================
section "TAMANHO INICIAL"
show_db_size
show_db_size --tables=wp_options,wp_postmeta,wp_posts,wp_usermeta,wp_commentmeta

# ==============================================================================
# 3. POSTS — limpeza segura
# ==============================================================================
section "POSTS"

log "Revisões"
# Risco: NENHUM — revisões não têm uso em produção
delete_posts_by_type revision

log "Auto-drafts"
# Risco: NENHUM — rascunhos automáticos do editor, descartáveis
delete_posts_by_type auto-draft

log "Posts na lixeira"
# Risco: BAIXO — já estão na lixeira; confirmar com o cliente antes
delete_posts_by_type any trash

# ==============================================================================
# 4. COMENTÁRIOS — limpeza segura
# ==============================================================================
section "COMENTÁRIOS"

log "Spam"
delete_comments_by status spam

log "Lixeira"
delete_comments_by status trash

log "Pingbacks"
# Risco: BAIXO — maioria é ruído de bots; pingbacks legítimos são raros
delete_comments_by type pingback

log "Trackbacks"
# Risco: BAIXO — similar a pingbacks
delete_comments_by type trackback

log "Não aprovados"
# Risco: MÉDIO — podem ser comentários legítimos aguardando moderação
# ↳ Veja manualmente em WP Admin > Comentários > Pendentes antes de rodar
COUNT_UNAPP=$($WP comment list --status=hold --format=count 2>/dev/null || echo 0)
info "Pendentes de aprovação: $COUNT_UNAPP"
if [[ "$COUNT_UNAPP" -gt 0 ]]; then
    warn "Verifique manualmente em WP Admin > Comentários > Pendentes antes de deletar."
    warn "Para deletar: wp comment delete \$(wp comment list --status=hold --format=ids) --force"
fi

# ==============================================================================
# 5. TRANSIENTS
# ==============================================================================
section "TRANSIENTS"

log "Deletar apenas expirados (seguro em produção)"
if $DRY_RUN; then
    COUNT_EXP=$(db_query "SELECT COUNT(*) FROM wp_options
        WHERE option_name LIKE '_transient_timeout_%'
          AND option_value < UNIX_TIMESTAMP();" | tr -d '[:space:]')
    info "Transients expirados: ${COUNT_EXP:-0}"
    skip "wp transient delete --expired"
else
    run $WP transient delete --expired
    ok "Transients expirados removidos"
fi

# ==============================================================================
# 6. oEmbed cache
# ==============================================================================
section "oEmBED CACHE"
# Risco: BAIXO — serão regerados automaticamente na próxima visualização
# Causa leve aumento de tempo no 1º acesso após a limpeza
log "Cache de embeds (meta_key LIKE '_oembed_%')"
confirm_sql \
    "Deletar oEmbed cache de wp_postmeta" \
    "SELECT COUNT(*) FROM wp_postmeta WHERE meta_key LIKE '_oembed_%'" \
    "DELETE FROM wp_postmeta WHERE meta_key LIKE '_oembed_%'"

# ==============================================================================
# 7. ORPHANS (post meta, user meta, comment meta, term meta)
# ==============================================================================
section "ORPHANS"

# Instalar o pacote se não estiver presente
$WP package install humanmade/orphan-command --quiet 2>/dev/null || true

log "Post meta órfão"
run $WP orphan post meta list
if ! $DRY_RUN; then run $WP orphan post meta delete; fi

log "User meta órfão"
run $WP orphan user meta list
if ! $DRY_RUN; then run $WP orphan user meta delete; fi

log "Comment meta órfão (SQL direto)"
confirm_sql \
    "Deletar comment meta sem comentário pai" \
    "SELECT COUNT(*) FROM wp_commentmeta cm
     LEFT JOIN wp_comments c ON c.comment_ID = cm.comment_id
     WHERE c.comment_ID IS NULL" \
    "DELETE cm FROM wp_commentmeta cm
     LEFT JOIN wp_comments c ON c.comment_ID = cm.comment_id
     WHERE c.comment_ID IS NULL"

log "Term meta órfão (SQL direto)"
confirm_sql \
    "Deletar term meta sem term pai" \
    "SELECT COUNT(*) FROM wp_termmeta tm
     LEFT JOIN wp_terms t ON t.term_id = tm.term_id
     WHERE t.term_id IS NULL" \
    "DELETE tm FROM wp_termmeta tm
     LEFT JOIN wp_terms t ON t.term_id = tm.term_id
     WHERE t.term_id IS NULL"

log "Term relationships órfãos"
confirm_sql \
    "Deletar term_relationships sem post ou taxonomy válidos" \
    "SELECT COUNT(*) FROM wp_term_relationships tr
     LEFT JOIN wp_posts p ON p.ID = tr.object_id
     WHERE p.ID IS NULL" \
    "DELETE tr FROM wp_term_relationships tr
     LEFT JOIN wp_posts p ON p.ID = tr.object_id
     WHERE p.ID IS NULL"

# ==============================================================================
# 8. ITENS DE ATENÇÃO (só com --with-caution)
# ==============================================================================
if $WITH_CAUTION; then
    section "ATENÇÃO — Meta duplicado"
    warn "WordPress PERMITE múltiplos valores para a mesma meta_key (ex: ACF, WooCommerce)."
    warn "Só são deletadas linhas onde post_id + meta_key + meta_value são 100% idênticos."

    log "Post meta duplicado (linhas 100% idênticas)"
    confirm_sql \
        "Deletar post meta com linhas idênticas" \
        "SELECT COUNT(*) FROM wp_postmeta
         WHERE meta_id NOT IN (
             SELECT MIN(meta_id) FROM wp_postmeta
             GROUP BY post_id, meta_key, meta_value
         )" \
        "DELETE FROM wp_postmeta
         WHERE meta_id NOT IN (
             SELECT min_id FROM (
                 SELECT MIN(meta_id) AS min_id
                 FROM wp_postmeta
                 GROUP BY post_id, meta_key, meta_value
             ) AS keep
         )"

    log "User meta duplicado (linhas 100% idênticas)"
    confirm_sql \
        "Deletar user meta com linhas idênticas" \
        "SELECT COUNT(*) FROM wp_usermeta
         WHERE umeta_id NOT IN (
             SELECT MIN(umeta_id) FROM wp_usermeta
             GROUP BY user_id, meta_key, meta_value
         )" \
        "DELETE FROM wp_usermeta
         WHERE umeta_id NOT IN (
             SELECT min_id FROM (
                 SELECT MIN(umeta_id) AS min_id
                 FROM wp_usermeta
                 GROUP BY user_id, meta_key, meta_value
             ) AS keep
         )"

    log "Comment meta duplicado (linhas 100% idênticas)"
    confirm_sql \
        "Deletar comment meta com linhas idênticas" \
        "SELECT COUNT(*) FROM wp_commentmeta
         WHERE meta_id NOT IN (
             SELECT MIN(meta_id) FROM wp_commentmeta
             GROUP BY comment_id, meta_key, meta_value
         )" \
        "DELETE FROM wp_commentmeta
         WHERE meta_id NOT IN (
             SELECT min_id FROM (
                 SELECT MIN(meta_id) AS min_id
                 FROM wp_commentmeta
                 GROUP BY comment_id, meta_key, meta_value
             ) AS keep
         )"

    log "Term meta duplicado (linhas 100% idênticas)"
    confirm_sql \
        "Deletar term meta com linhas idênticas" \
        "SELECT COUNT(*) FROM wp_termmeta
         WHERE meta_id NOT IN (
             SELECT MIN(meta_id) FROM wp_termmeta
             GROUP BY term_id, meta_key, meta_value
         )" \
        "DELETE FROM wp_termmeta
         WHERE meta_id NOT IN (
             SELECT min_id FROM (
                 SELECT MIN(meta_id) AS min_id
                 FROM wp_termmeta
                 GROUP BY term_id, meta_key, meta_value
             ) AS keep
         )"

else
    section "ATENÇÃO (pulado)"
    info "Meta duplicado não foi verificado."
    info "Rode com --with-caution para incluir essa verificação."
fi

# ==============================================================================
# 9. Verificar restos de plugin removido
# ==============================================================================
plugin_remnant_check() {
    local slug="$1"
    section "RESTOS DE PLUGIN: $slug"
    echo "Buscando no banco de dados..." | tee -a "$REPORT"

    local -A targets=(
        [wp_options]="option_name"
        [wp_postmeta]="meta_key"
        [wp_usermeta]="meta_key"
        [wp_commentmeta]="meta_key"
        [wp_termmeta]="meta_key"
    )

    for table in "${!targets[@]}"; do
        local col="${targets[$table]}"
        log "$table ($col LIKE '%${slug}%')"
        local result
        result=$(db_query "SELECT COUNT(*) AS total, ${col}
                           FROM ${table}
                           WHERE ${col} LIKE '%${slug}%'
                           GROUP BY ${col}
                           ORDER BY ${col};" 2>/dev/null || true)
        if [[ -n "$result" ]]; then
            echo "$result" | tee -a "$REPORT"
            if ! $DRY_RUN; then
                read -r -p "  Deletar de $table? [s/N] " ans
                if [[ "${ans,,}" == "s" ]]; then
                    db_query "DELETE FROM ${table} WHERE ${col} LIKE '%${slug}%';"
                    ok "$table limpo."
                fi
            fi
        else
            info "Nenhuma entrada em $table."
        fi
    done

    log "Tabelas com '${slug}' no nome"
    local extra_tables
    extra_tables=$(db_query "SELECT table_name
                             FROM information_schema.tables
                             WHERE table_schema = DATABASE()
                               AND table_name LIKE '%${slug//-/_}%';" 2>/dev/null || true)
    if [[ -n "$extra_tables" ]]; then
        echo "$extra_tables" | tee -a "$REPORT"
        if ! $DRY_RUN; then
            read -r -p "  Dropar essas tabelas? [s/N] " ans
            if [[ "${ans,,}" == "s" ]]; then
                while IFS= read -r tbl; do
                    [[ -z "$tbl" ]] && continue
                    db_query "DROP TABLE IF EXISTS \`${tbl}\`;"
                    ok "Tabela '$tbl' removida."
                done <<< "$extra_tables"
            fi
        fi
    else
        info "Nenhuma tabela extra encontrada."
    fi
}

[[ -n "$PLUGIN_CHECK" ]] && plugin_remnant_check "$PLUGIN_CHECK"

# ==============================================================================
# 10. REPAIR (opcional, bloqueia tabelas)
# ==============================================================================
section "REPAIR"
warn "REPAIR bloqueia tabelas durante a execução. Use em horário de baixo tráfego."
if ! $DRY_RUN; then
    read -r -p "  Executar wp db repair agora? [s/N] " ans
    if [[ "${ans,,}" == "s" ]]; then
        run $WP db repair
        ok "Repair concluído."
    else
        info "Repair pulado."
    fi
else
    skip "wp db repair"
fi

# ==============================================================================
# 11. OTIMIZAR TABELAS
# ==============================================================================
section "OPTIMIZE"
if $DRY_RUN; then
    skip "wp db optimize"
else
    run $WP db optimize
    ok "OPTIMIZE concluído."
fi

# ==============================================================================
# 12. ÍNDICES — Index WP MySQL For Speed
# ==============================================================================
section "ÍNDICES MYSQL"
if ! $WP plugin is-installed index-wp-mysql-for-speed 2>/dev/null; then
    run $WP plugin install index-wp-mysql-for-speed --activate
else
    run $WP plugin activate index-wp-mysql-for-speed 2>/dev/null || true
fi
if ! $DRY_RUN; then
    run $WP index-mysql enable --all
fi

# ==============================================================================
# 13. TAMANHO FINAL
# ==============================================================================
section "TAMANHO FINAL"
show_db_size
show_db_size --tables=wp_options,wp_postmeta,wp_posts,wp_usermeta,wp_commentmeta

# ==============================================================================
section "CONCLUÍDO"
info "Relatório: $REPORT"
[[ "${SKIP_BACKUP:-false}" == "false" && -n "${BACKUP_FILE:-}" ]] && info "Backup:    $BACKUP_FILE"