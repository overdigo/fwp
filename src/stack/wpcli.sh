#!/usr/bin/env bash
# MODULE: wpcli.sh — WP-CLI wrapper and WordPress automation
WP_BIN="${WP_BIN:-/usr/local/bin/wp}"

wpcli_install() {
  if command -v wp &>/dev/null; then log_warn "WP-CLI already installed."; return 0; fi
  curl -sSL "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar" \
    -o "${WP_BIN}"
  chmod +x "${WP_BIN}"
  log_success "WP-CLI installed: $(wp --version --allow-root 2>/dev/null)"
}

wp_cli() {
  local path="${WP_PATH:-}"
  if [[ -n "${path}" ]]; then
    ( cd "${path}" 2>/dev/null || true; sudo -u www-data env WP_CLI_DISABLE_AUTO_CHECK_UPDATE=1 "${WP_BIN}" --path="${path}" "$@" )
  else
    ( cd /tmp && sudo -u www-data env WP_CLI_DISABLE_AUTO_CHECK_UPDATE=1 "${WP_BIN}" "$@" )
  fi
}

wpcli_download_wordpress() {
  local path="$1" locale="${2:-en_US}"
  log_info "Downloading WordPress (locale: ${locale})..."
  mkdir -p "${path}"; chown www-data:www-data "${path}"
  WP_PATH="${path}" wp_cli core download --locale="${locale}" --path="${path}"
  chown -R www-data:www-data "${path}"
  log_success "WordPress downloaded to ${path}"
}

wpcli_create_config() {
  local path="$1" dbname="$2" dbuser="$3" dbpass="$4" dbprefix="${5:-wp_}"
  log_info "Generating wp-config.php (prefix: ${dbprefix})..."
  WP_PATH="${path}" wp_cli config create \
    --dbname="${dbname}" --dbuser="${dbuser}" --dbpass="${dbpass}" \
    --dbprefix="${dbprefix}" \
    --dbhost="localhost:/run/mysqld/mysqld.sock" --dbcharset="utf8mb4" \
    --dbcollate="utf8mb4_unicode_ci" --skip-check
  WP_PATH="${path}" wp_cli config set WP_CACHE            true  --raw
  WP_PATH="${path}" wp_cli config set WP_POST_REVISIONS   5     --raw
  WP_PATH="${path}" wp_cli config set DISALLOW_FILE_EDIT  true  --raw
  WP_PATH="${path}" wp_cli config set WP_DEBUG            false --raw
  WP_PATH="${path}" wp_cli config set CONCATENATE_SCRIPTS false --raw
  log_success "wp-config.php created"
}

wpcli_install_wordpress() {
  local path="$1" domain="$2" title="$3" user="$4" pass="$5" email="$6"
  log_info "Installing WordPress at ${domain}..."
  WP_PATH="${path}" wp_cli core install \
    --url="https://${domain}" --title="${title}" \
    --admin_user="${user}" --admin_password="${pass}" \
    --admin_email="${email}" --skip-email
  log_success "WordPress installed at https://${domain}"
}

wpcli_setup_redis_cache() {
  local path="$1"
  log_info "Installing Redis Object Cache plugin..."
  WP_PATH="${path}" wp_cli plugin install redis-cache --activate
  WP_PATH="${path}" wp_cli config set WP_REDIS_SCHEME "unix"
  WP_PATH="${path}" wp_cli config set WP_REDIS_PATH   "/var/run/redis/redis-server.sock"
  WP_PATH="${path}" wp_cli config set WP_REDIS_DATABASE 0    --raw
  WP_PATH="${path}" wp_cli redis enable 2>/dev/null || true
  log_success "Redis Object Cache enabled"
}

wpcli_setup_locale() {
  local path="$1" locale="$2"
  [[ "${locale}" == "en_US" ]] && return 0
  log_info "Installing language pack: ${locale}..."
  WP_PATH="${path}" wp_cli language core install "${locale}" 2>/dev/null || true
  WP_PATH="${path}" wp_cli site switch-language "${locale}"  2>/dev/null || true
  log_success "Language ${locale} installed"
}
