#!/usr/bin/env bash
# MODULE: site/create.sh — Full WordPress site creation flow
site_create() {
  local domain="" locale="${FWP_DEFAULT_LOCALE:-en_US}"
  local title="My WordPress Site" admin_user="admwp" admin_email=""
  local skip_redis=false skip_ssl=false www_pref="" worker_mode=false
  local cache_plugin="wpsc"  # default: wp-super-cache
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --locale=*)      locale="${1#*=}";       shift ;;
      --locale)        locale="$2";            shift 2 ;;
      --title=*)       title="${1#*=}";        shift ;;
      --title)         title="$2";             shift 2 ;;
      --admin-email=*) admin_email="${1#*=}";  shift ;;
      --admin-email)   admin_email="$2";       shift 2 ;;
      --admin-user=*)  admin_user="${1#*=}";   shift ;;
      --skip-redis)    skip_redis=true;        shift ;;
      --skip-ssl)      skip_ssl=true;          shift ;;
      --dev)           is_dev=true;            shift ;;
      --www)           www_pref="www";         shift ;;
      --no-www)        www_pref="non-www";     shift ;;
      --skip-www-prompt) www_pref="none";      shift ;;
      --worker)        worker_mode=true;       shift ;;
      --cache=*)       cache_plugin="${1#*=}"; shift ;;
      --cache)         cache_plugin="$2";      shift 2 ;;
      --wpsc)          cache_plugin="wpsc";    shift ;;
      --wprocket)      cache_plugin="wprocket"; shift ;;
      --wpce)          cache_plugin="wpce";    shift ;;
      --nocache)       cache_plugin="none";    shift ;;
      *)               positional+=("$1");     shift ;;
    esac
  done
  domain="${positional[0]:-}"
  domain="${domain#www.}"
  [[ -z "${domain}" ]] && log_fatal "Usage: fwp site create <domain> [options]"
  admin_email="${admin_email:-admin@${domain}}"

  if [[ -z "${www_pref}" ]]; then
    if [[ -t 0 ]]; then
      echo -e "  Como você prefere o endereço final de ${CYAN}${domain}${NC}?"
      echo "  1) Sem www (ex: ${domain})"
      echo "  2) Com www (ex: www.${domain})"
      echo "  3) Não redirecionar (manter apenas ${domain})"
      while true; do
        read -r -p "  Escolha a opção (1/2/3) [1]: " opt
        opt="${opt:-1}"
        case "$opt" in
          1) www_pref="non-www"; break ;;
          2) www_pref="www"; break ;;
          3) www_pref="none"; break ;;
          *) echo "  Selecione 1, 2 ou 3." ;;
        esac
      done
    else
      www_pref="non-www"
    fi
  fi

  source "${FWP_HOME}/src/stack/mariadb.sh"
  source "${FWP_HOME}/src/stack/wpcli.sh"

  echo ""
  echo -e "  ${BOLD}${CYAN}Creating WordPress site: ${domain}${NC}"
  echo "  ──────────────────────────────────────────"

  log_step "1/8 Validating..."
  _validate_domain "${domain}"
  if _site_exists "${domain}"; then
    log_fatal "Site '${domain}' already exists. Run: fwp site info ${domain}"
  fi
  log_success "Domain valid"

  log_step "2/8 Generating credentials..."
  local base_domain="${domain%%.*}"
  base_domain="${base_domain//[^a-zA-Z0-9]/_}"
  
  if [[ "${admin_user}" == "admin" ]]; then
    admin_user="${base_domain}_adm"
  fi

  local db_name db_user db_pass admin_pass db_suffix
  db_name=$(_generate_db_name "${domain}")
  db_suffix=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8 || true)
  
  db_user="${base_domain}_user_${db_suffix}"
  db_user="${db_user:0:32}"
  
  db_pass=$(_generate_password 18)
  admin_pass=$(_generate_password 18)
  log_success "Credentials generated"

  log_step "3/8 Creating directories..."
  local webroot="/var/www/${domain}/htdocs"
  local sitedir="/var/www/${domain}"
  mkdir -p "${webroot}" "${sitedir}/logs" "${sitedir}/conf"
  chown -R www-data:www-data "${sitedir}"
  log_success "${sitedir}"

  log_step "4/8 Creating database..."
  stack_mariadb_create_db "${db_name}" "${db_user}" "${db_pass}"

  log_step "5/8 Configuring FrankenPHP (Caddyfile)..."
  _site_generate_caddyfile "${domain}" "${webroot}" "${skip_ssl}" "${www_pref}" "${worker_mode}" "${cache_plugin}"
  _frankenphp_reload

  # Add to /etc/hosts (Loopback) for internal communications
  if ! grep -q " ${domain}$" /etc/hosts; then
    echo "127.0.0.1 ${domain} www.${domain}" >> /etc/hosts
    log_info "Added ${domain} to /etc/hosts"
  fi

  log_step "6/8 Downloading WordPress..."
  wpcli_download_wordpress "${webroot}" "${locale}"
  local db_prefix; db_prefix=$(_generate_table_prefix)
  wpcli_create_config "${webroot}" "${db_name}" "${db_user}" "${db_pass}" "${db_prefix}"
  
  log_info "Setting WordPress memory limits..."
  WP_PATH="${webroot}" wp_cli config set WP_MEMORY_LIMIT 512M
  WP_PATH="${webroot}" wp_cli config set WP_MAX_MEMORY_LIMIT 512M

  log_step "7/8 Installing WordPress..."
  wpcli_install_wordpress "${webroot}" "${domain}" "${title}" \
    "${admin_user}" "${admin_pass}" "${admin_email}"
  wpcli_setup_locale "${webroot}" "${locale}"
  
  log_info "Setting permalink structure to /%postname%/..."
  WP_PATH="${webroot}" wp_cli option update permalink_structure '/%postname%/'
  WP_PATH="${webroot}" wp_cli rewrite flush
  
  if [[ "${worker_mode}" == "true" ]]; then
    log_info "Creating worker.php bridge..."
    cat > "${webroot}/worker.php" << 'EOF'
<?php
// FrankenWP — WordPress Worker Bridge
ignore_user_abort(true);

// Bootstrap do WordPress feito UMA VEZ
define('ABSPATH', __DIR__ . '/');
define('WPINC', 'wp-includes');

// Loop de requests
$handler = static function () {
    // Carrega o WordPress normalmente
    require __DIR__ . '/wp-blog-header.php';
};

// Loop principal — bloqueia até uma requisição chegar
while (frankenphp_handle_request($handler)) {
    gc_collect_cycles();
}
EOF
    chown www-data:www-data "${webroot}/worker.php"
  fi

  log_step "8/8 Enabling Redis Object Cache..."
  if [[ "${skip_redis}" == "false" ]] && systemctl is-active --quiet redis-server 2>/dev/null; then
    wpcli_setup_redis_cache "${webroot}"
  else
    log_info "Skipping Redis (not available or --skip-redis)"
  fi

  _site_install_cache_plugin "${webroot}" "${cache_plugin}"

  log_step "Configuring Cron tasks..."
  WP_PATH="${webroot}" wp_cli config set DISABLE_WP_CRON true --raw --type=constant
  
  # Add real system cron (every 5 minutes) via /etc/cron.d for better management
  echo "*/5 * * * * sudo -u www-data /usr/local/bin/wp cron event run --due-now --path=${webroot} > /dev/null 2>&1" > "/etc/cron.d/fwp-${domain//./-}"

  _site_save_registry "${domain}" "${webroot}" \
    "${db_name}" "${db_user}" "${db_pass}" "${db_prefix}" \
    "${admin_user}" "${admin_pass}" "${admin_email}" \
    "${skip_redis}" "${skip_ssl}" "${worker_mode}" "${cache_plugin}"

  if [[ "${is_dev:-false}" == "true" ]]; then
    log_step "Extra: Importing WordPress Theme Unit Test data..."
    WP_PATH="${webroot}" wp_cli plugin install wordpress-importer --activate
    
    local xml_file="/tmp/themeunittestdata.xml"
    if [[ ! -f "${xml_file}" ]]; then
      log_info "Downloading test data..."
      curl -sSL -o "${xml_file}" https://raw.githubusercontent.com/WPTT/theme-test-data/master/themeunittestdata.wordpress.xml
      chown www-data:www-data "${xml_file}"
    fi
    
    log_info "Importing XML (this may take a minute)..."
    WP_PATH="${webroot}" wp_cli import "${xml_file}" --authors=create
    log_success "Test data imported"
  fi

  _site_print_summary "${domain}" "${admin_user}" "${admin_pass}" \
    "${admin_email}" "${db_name}" "${db_user}" "${db_pass}" "${skip_ssl}"

  log_info "Auditando Redirecionamentos, HSTS e TLS..."
  local protocols=("http" "https")
  local variants=("${domain}" "www.${domain}")
  
  echo -e "\n--- Auditoria de Redirecionamentos e HSTS ---"
  for proto in "${protocols[@]}"; do
    for var in "${variants[@]}"; do
      echo -n "  Testing ${proto}://${var} -> "
      curl -4Ik "${proto}://${var}" --resolve "${var}:${proto#*://}:127.0.0.1" 2>/dev/null | \
        grep -Ei "HTTP/|location:|strict-transport-security:|server:" | tr '\n' ' '
      echo ""
    done
  done

  echo -e "\n--- Auditoria de TLS e SNI ---"
  echo -n "  TLS 1.2 Handshake: "
  echo | openssl s_client -connect 127.0.0.1:443 -servername "${domain}" -tls1_2 2>/dev/null | grep -Ei "Protocol  :|Cipher    :" | tr '\n' ' ' || echo "Falhou"
  echo -e "\n"
  
  echo -n "  TLS 1.3 Handshake: "
  echo | openssl s_client -connect 127.0.0.1:443 -servername "${domain}" -tls1_3 2>/dev/null | grep -Ei "Protocol  :|Cipher    :" | tr '\n' ' ' || echo "Falhou"
  echo -e "\n"

  echo -n "  Teste SEM SNI (Deveria ser rejeitado): "
  if echo | openssl s_client -connect 127.0.0.1:443 2>&1 | grep -Ei "alert|error" > /dev/null; then
    echo "Sucesso (Conexão rejeitada conforme esperado)"
  else
    echo "Aviso: Servidor aceitou conexão sem SNI"
  fi
  echo -e "\n${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

_site_generate_caddyfile() {
  local domain="$1" webroot="$2" skip_ssl="$3" www_pref="${4:-non-www}" worker_mode="${5:-false}" cache_plugin="${6:-wpsc}"
  local caddy_file="/etc/frankenphp/sites-available/${domain}.conf"
  local log_dir="/var/www/${domain}/logs"
  
  local proto="https"
  [[ "${skip_ssl}" == "true" ]] && proto="http"

  local tls_block=""
  # Detect local/dev domains or --dev flag to use internal self-signed SSL
  if [[ "${skip_ssl}" == "false" ]]; then
    if [[ "${is_dev:-false}" == "true" ]] || [[ "${domain}" =~ \.(test|local|dev|example)$ ]] || [[ "${domain}" == "localhost" ]]; then
      tls_block="    tls internal"
    else
      tls_block="    tls {
        curves x25519
        key_type ed25519
    }"
    fi
  fi

  local cpus; cpus=$(nproc)
  local num_workers=$(( cpus * 8 ))
  [[ $num_workers -lt 8 ]] && num_workers=8

  local worker_block=""
  if [[ "${worker_mode}" == "true" ]]; then
    worker_block="worker ${webroot}/worker.php ${num_workers}"
  fi

  local hot_reload_block=""
  local mercure_block=""
  if [[ "${is_dev:-false}" == "true" ]]; then
    mercure_block="    mercure {
        anonymous
    }"
    hot_reload_block="        hot_reload"
  fi

  # Determine canonical and non-canonical based on preference
  local canonical="${domain}"
  local non_canonical="www.${domain}"
  if [[ "${www_pref}" == "www" ]]; then
      canonical="www.${domain}"
      non_canonical="${domain}"
  fi

  cat > "${caddy_file}" << CADDY
# 1. HTTP -> HTTPS (Same Host)
http://${canonical}, http://${non_canonical} {
    header -Server
    redir https://{host}{uri} 301
}

# 2. HTTPS Non-Canonical -> HTTPS Canonical (HSTS Preload compliant)
https://${non_canonical} {
    ${tls_block}
    header {
        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        -Server
    }
    redir https://${canonical}{uri} 301
}

https://${canonical} {
    root * ${webroot}
    ${tls_block}
    ${mercure_block}

    # 1. Matchers e Bloqueios (Performance: descartar lixo rápido)
    @wp_xmlrpc      path /xmlrpc.php
    @wp_users_enum  path /wp-json/wp/v2/users
    @author_enum    query author=*
    @blocked {
        path /wp-config.php
        path /.htaccess
        path /.env
        path *.sql
        path /wp-includes/build/
        path /wp-admin/includes/
        path /wp-content/uploads/*.php
    }

    respond @blocked 403
    respond @wp_xmlrpc 403
    respond @author_enum 403

    # 2. Headers de Segurança e Anonimato
    header {
        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        ?X-Frame-Options "SAMEORIGIN"
        ?X-Content-Type-Options "nosniff"
        ?Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=()"
        ?Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; img-src 'self' data: https: blob:; font-src 'self' data:; connect-src 'self'; media-src 'self' https: data: blob:; frame-ancestors 'self'; base-uri 'self'; form-action 'self'"
        ?X-XSS-Protection "1; mode=block"
        ?Cross-Origin-Opener-Policy "same-origin-allow-popups"
        ?Cross-Origin-Embedder-Policy "unsafe-none"
        ?Cross-Origin-Resource-Policy "same-origin"
        -Server
        -X-Powered-By
        -Via
    }

    # 3. Cache Estático de Página
    @nocache {
        header Cookie *wordpress_logged_in*
        header Cookie *wp-postpass*
        header Cookie *woocommerce_items_in_cart*
    }

CADDY_CACHE_BLOCK


    # 4. Cache de Ativos Estáticos e Negociação de Imagens
    @avif {
        header Accept *image/avif*
        path *.jpg *.jpeg *.png
        file {
            try_files {path}.avif
        }
    }
    rewrite @avif {path}.avif

    @webp {
        header Accept *image/webp*
        path *.jpg *.jpeg *.png
        file {
            try_files {path}.webp
        }
    }
    rewrite @webp {path}.webp

    @images {
        path *.jpg *.jpeg *.png *.webp *.avif
    }
    header @images Vary "Accept"

    @static {
        file
        path *.ico *.css *.js *.gif *.jpg *.jpeg *.png *.svg *.woff *.woff2 *.webp *.avif *.mp4 *.webm
    }
    header @static Cache-Control "public, max-age=31536000, immutable"

    # 5. Compressão
    encode {
        zstd better
        br
        gzip 6
        minimum_length 512
    }

    # 6. Processamento PHP (FrankenPHP)
    php_server {
        root ${webroot}
        resolve_root_symlink false
        ${worker_block}
        ${hot_reload_block}
    }
    file_server

    # 7. Logging
    log {
        output file ${log_dir}/access.log {
            roll_size     20MB
            roll_keep     5
            roll_keep_for 168h
        }
        level  WARN
    }
}
CADDY

  # Inject the correct cache block for the chosen plugin.
  # Write block to a temp file first (awk -v can't pass multiline vars reliably).
  local tmp_block; tmp_block=$(mktemp)
  local tmp_caddy; tmp_caddy=$(mktemp)
  _site_cache_block "${cache_plugin}" > "${tmp_block}"
  awk -v blkfile="${tmp_block}" '
    /CADDY_CACHE_BLOCK/ {
      while ((getline line < blkfile) > 0) print line
      close(blkfile)
      next
    }
    { print }
  ' "${caddy_file}" > "${tmp_caddy}"
  mv "${tmp_caddy}" "${caddy_file}"
  rm -f "${tmp_block}"

  chmod 644 "${caddy_file}"
  ln -sf "${caddy_file}" "/etc/frankenphp/sites-enabled/${domain}.conf"
  log_success "Caddyfile created: ${caddy_file}"
}

# Return the Caddyfile cache block snippet for the given plugin slug
_site_cache_block() {
  local plugin="${1:-wpsc}"
  case "${plugin}" in
    wpsc)
      cat <<'BLOCK'
    @supercache {
        not header Cookie *wordpress_logged_in*
        not header Cookie *wp-postpass*
        not header Cookie *woocommerce_items_in_cart*
        expression {query} == ""
        method GET
        file {
            try_files /wp-content/cache/supercache/{http.request.host}{uri}/index.html
        }
    }
    rewrite @supercache /wp-content/cache/supercache/{http.request.host}{uri}/index.html
BLOCK
      ;;
    wprocket)
      cat <<'BLOCK'
    @wprocket {
        not header Cookie *wordpress_logged_in*
        not header Cookie *wp-postpass*
        not header Cookie *woocommerce_items_in_cart*
        expression {query} == ""
        method GET
        file {
            try_files /wp-content/cache/wp-rocket/{http.request.host}{uri}/index.html
        }
    }
    rewrite @wprocket /wp-content/cache/wp-rocket/{http.request.host}{uri}/index.html

    @wprocket_html {
        path /wp-content/cache/wp-rocket/*.html
    }
    header @wprocket_html Vary "Accept-Encoding, Cookie"
    header @wprocket_html Cache-Control "public, max-age=36000"
BLOCK
      ;;
    wpce)
      cat <<'BLOCK'
    @wpce {
        not header Cookie *wordpress_logged_in*
        not header Cookie *wp-postpass*
        not header Cookie *woocommerce_items_in_cart*
        expression {query} == ""
        method GET
        file {
            try_files /wp-content/cache/cache-enabler/{http.request.host}{uri}index.html
        }
    }
    rewrite @wpce /wp-content/cache/cache-enabler/{http.request.host}{uri}index.html

    @wpce_html {
        path /wp-content/cache/cache-enabler/*.html
    }
    header @wpce_html Vary "Accept-Encoding, Cookie"
    header @wpce_html Cache-Control "public, max-age=36000"
BLOCK
      ;;
    none)
      echo "    # No page cache plugin configured"
      ;;
    *)
      log_warn "Unknown cache plugin '${plugin}', skipping cache block"
      echo "    # Unknown cache plugin: ${plugin}"
      ;;
  esac
}

# Install and activate the chosen cache plugin via WP-CLI
_site_install_cache_plugin() {
  local webroot="$1" plugin="${2:-wpsc}"
  case "${plugin}" in
    wpsc)
      log_step "Installing WP Super Cache..."
      WP_PATH="${webroot}" wp_cli plugin install wp-super-cache --activate
      log_success "WP Super Cache installed"
      ;;
    wprocket)
      log_step "Installing WP Rocket..."
      # WP Rocket is a premium plugin — cannot be installed from wordpress.org
      # Users must upload the plugin manually or via a licensed key.
      log_warn "WP Rocket is a premium plugin. Upload it manually to ${webroot}/wp-content/plugins/ and activate it."
      ;;
    wpce)
      log_step "Installing Cache Enabler..."
      WP_PATH="${webroot}" wp_cli plugin install cache-enabler --activate
      log_success "Cache Enabler installed"
      ;;
    none)
      log_info "No page cache plugin selected (--nocache)"
      ;;
    *)
      log_warn "Unknown cache plugin '${plugin}'. No cache plugin installed."
      ;;
  esac
}

_site_save_registry() {
  mkdir -p /etc/fwp/sites
  cat > "/etc/fwp/sites/${1}.conf" << CONF
DOMAIN="${1}"
CREATED_AT="$(date --iso-8601=seconds)"
STATUS="enabled"
WEBROOT="${2}"
DB_NAME="${3}"
DB_USER="${4}"
DB_PASS="${5}"
DB_PREFIX="${6}"
WP_ADMIN_USER="${7}"
WP_ADMIN_PASS="${8}"
WP_ADMIN_EMAIL="${9}"
REDIS_ENABLED="$( [[ "${10}" == "false" ]] && echo "true" || echo "false" )"
SSL_ENABLED="$( [[ "${11}" == "false" ]] && echo "true" || echo "false" )"
CACHE_PLUGIN="${12:-wpsc}"
CONF
  chmod 600 "/etc/fwp/sites/${1}.conf"
  log_success "Registry: /etc/fwp/sites/${1}.conf"

  # Also write a human-readable credentials file one level above htdocs.
  # Owned by root:root, chmod 700 — not accessible by www-data or the web.
  local site_dir; site_dir="$(dirname "${2}")"  # /var/www/<domain>
  cat > "${site_dir}/.credentials" << CREDS
# FrankenWP — Site Credentials
# Generated: $(date --iso-8601=seconds)
# WARNING: Keep this file private (root only, chmod 700)

DOMAIN="${1}"
CACHE_PLUGIN="${12:-wpsc}"

## WordPress Admin
WP_ADMIN_URL="https://${1}/wp-admin"
WP_ADMIN_USER="${7}"
WP_ADMIN_PASS="${8}"
WP_ADMIN_EMAIL="${9}"

## Database
DB_NAME="${3}"
DB_USER="${4}"
DB_PASS="${5}"
DB_PREFIX="${6}"
CREDS
  chown root:root "${site_dir}/.credentials"
  chmod 700 "${site_dir}/.credentials"
  log_success "Credentials: ${site_dir}/.credentials (root only)"
}

_site_print_summary() {
  local domain="$1" user="$2" pass="$3" email="$4" db="$5" dbu="$6" dbp="$7" skip_ssl="$8"
  local proto="https"; [[ "${skip_ssl}" == "true" ]] && proto="http"
  echo ""
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}${BOLD}  ✓ WordPress site created successfully!${NC}"
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}Site URL:${NC}    ${CYAN}${proto}://${domain}${NC}"
  echo -e "  ${BOLD}Admin URL:${NC}   ${CYAN}${proto}://${domain}/wp-admin${NC}"
  echo ""
  echo -e "  ${BOLD}Username:${NC}    ${YELLOW}${user}${NC}"
  echo -e "  ${BOLD}Password:${NC}    ${YELLOW}${pass}${NC}"
  echo -e "  ${BOLD}Email:${NC}       ${email}"
  echo ""
  echo -e "  ${BOLD}Database:${NC}    ${db}"
  echo -e "  ${BOLD}DB User:${NC}     ${dbu}"
  echo -e "  ${BOLD}DB Pass:${NC}     ${dbp}"
  echo ""
}
