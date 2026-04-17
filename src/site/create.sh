#!/usr/bin/env bash
# MODULE: site/create.sh — Full WordPress site creation flow
site_create() {
  local domain="" locale="${FWP_DEFAULT_LOCALE:-en_US}"
  local title="My WordPress Site" admin_user="admwp" admin_email=""
  local skip_redis=false skip_ssl=false www_pref=""
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
  _site_generate_caddyfile "${domain}" "${webroot}" "${skip_ssl}" "${www_pref}"
  _frankenphp_reload

  log_step "6/8 Downloading WordPress..."
  wpcli_download_wordpress "${webroot}" "${locale}"
  wpcli_create_config "${webroot}" "${db_name}" "${db_user}" "${db_pass}"

  log_step "7/8 Installing WordPress..."
  wpcli_install_wordpress "${webroot}" "${domain}" "${title}" \
    "${admin_user}" "${admin_pass}" "${admin_email}"
  wpcli_setup_locale "${webroot}" "${locale}"

  log_step "8/8 Enabling Redis Object Cache..."
  if [[ "${skip_redis}" == "false" ]] && systemctl is-active --quiet redis-server 2>/dev/null; then
    wpcli_setup_redis_cache "${webroot}"
  else
    log_info "Skipping Redis (not available or --skip-redis)"
  fi

  _site_save_registry "${domain}" "${webroot}" \
    "${db_name}" "${db_user}" "${db_pass}" \
    "${admin_user}" "${admin_pass}" "${admin_email}" \
    "${skip_redis}" "${skip_ssl}"

  if [[ "${is_dev:-false}" == "true" ]]; then
    log_step "Extra: Importing WordPress Theme Unit Test data..."
    wp plugin install wordpress-importer --activate --path="${webroot}" --allow-root
    
    local xml_file="/tmp/themeunittestdata.xml"
    if [[ ! -f "${xml_file}" ]]; then
      log_info "Downloading test data..."
      curl -sSL -o "${xml_file}" https://raw.githubusercontent.com/WPTT/theme-test-data/master/themeunittestdata.wordpress.xml
    fi
    
    log_info "Importing XML (this may take a minute)..."
    wp import "${xml_file}" --authors=create --path="${webroot}" --allow-root
    log_success "Test data imported"
  fi

  _site_print_summary "${domain}" "${admin_user}" "${admin_pass}" \
    "${admin_email}" "${db_name}" "${db_user}" "${db_pass}" "${skip_ssl}"
}

_site_generate_caddyfile() {
  local domain="$1" webroot="$2" skip_ssl="$3" www_pref="${4:-non-www}"
  local caddy_file="/etc/frankenphp/sites-available/${domain}.conf"
  local log_dir="/var/www/${domain}/logs"
  
  local proto="https"
  [[ "${skip_ssl}" == "true" ]] && proto="http"

  local tls_block=""
  # Detect local/dev domains or --dev flag to use internal self-signed SSL
  if [[ "${skip_ssl}" == "false" ]]; then
    if [[ "${is_dev:-false}" == "true" ]] || [[ "${domain}" =~ \.(test|local|dev|example)$ ]] || [[ "${domain}" == "localhost" ]]; then
      tls_block="    tls internal"
    fi
  fi

  local redir_block=""
  local main_host="${proto}://${domain}"

  if [[ "${www_pref}" == "www" ]]; then
    main_host="${proto}://www.${domain}"
    redir_block="${proto}://${domain} {
    redir ${proto}://www.${domain}{uri}
}
"
  elif [[ "${www_pref}" == "non-www" ]]; then
    main_host="${proto}://${domain}"
    redir_block="${proto}://www.${domain} {
    redir ${proto}://${domain}{uri}
}
"
  fi

  cat > "${caddy_file}" << CADDY
${redir_block}
${main_host} {
    root * ${webroot}
    ${tls_block}

    # FrankenPHP worker — handles PHP via worker mode for best performance
    php_server

    # Compression: Zstandard (fastest), Brotli (best ratio), Gzip (fallback)
    encode zstd br gzip

    log {
        output file ${log_dir}/access.log {
            roll_size 50mb
            roll_keep 7
            roll_keep_for 720h
        }
        format console
    }

    @wp_login       path /wp-login.php
    @wp_xmlrpc      path /xmlrpc.php
    @wp_jwt         path /wp-json/jwt-auth/v1/token
    @wp_users_enum  path /wp-json/wp/v2/users
    @wp_comments    path /wp-comments-post.php
    @author_enum    query author=*

    @wp_rest_write {
        path /wp-json/*
        method POST PUT PATCH DELETE
    }

    @wp_search query s=*

    # Block access to sensitive WordPress files
    @blocked {
        path /wp-config.php
        path /.htaccess
        path /.env
        path *.sql
        path /wp-includes/build/
        path /wp-admin/includes/
        path /wp-content/uploads/*.php
    }

    # -------------------------------------------------------
    # Bloqueios diretos
    # -------------------------------------------------------
    respond @blocked 403
    respond @wp_xmlrpc   403
    respond @author_enum 403

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        ?X-Frame-Options "SAMEORIGIN"
        ?X-Content-Type-Options "nosniff"
        ?Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=()"
        ?Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https: blob:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'self'; base-uri 'self'; form-action 'self'"
        ?X-XSS-Protection "1; mode=block"
        ?Cross-Origin-Opener-Policy "same-origin-allow-popups"
        ?Cross-Origin-Embedder-Policy "unsafe-none"
        ?Cross-Origin-Resource-Policy "same-origin"
        -Server
        -X-Powered-By
        -Via
    }

    # Negociação de conteúdo para imagens (AVIF e WebP)
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

    # Headers específicos para imagens para o cache lidar bem com a negociação
    @images {
        path *.jpg *.jpeg *.png *.webp *.avif
    }
    header @images Vary "Accept"

    # Long-term cache for immutable static assets
    @static {
        file
        path *.ico *.css *.js *.gif *.jpg *.jpeg *.png *.svg
        path *.woff *.woff2 *.webp *.avif *.mp4 *.webm
    }
    header @static Cache-Control "public, max-age=31536000, immutable"
}
CADDY

  ln -sf "${caddy_file}" "/etc/frankenphp/sites-enabled/${domain}.conf"
  log_success "Caddyfile created: ${caddy_file}"
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
WP_ADMIN_USER="${6}"
WP_ADMIN_PASS="${7}"
WP_ADMIN_EMAIL="${8}"
REDIS_ENABLED="$( [[ "${9}" == "false" ]] && echo "true" || echo "false" )"
SSL_ENABLED="$( [[ "${10}" == "false" ]] && echo "true" || echo "false" )"
CONF
  chmod 600 "/etc/fwp/sites/${1}.conf"
  log_success "Registry: /etc/fwp/sites/${1}.conf"
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
