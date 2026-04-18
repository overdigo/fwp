# Per-site Caddyfile template
# Variables replaced by src/site/create.sh
{{DOMAIN}} {
    root * {{WEBROOT}}
    php_server
    encode zstd br gzip

    log {
        output file {{LOG_DIR}}/access.log {
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

    # -------------------------------------------------------
    # Rate limits
    # -------------------------------------------------------
    rate_limit @wp_login {
        zone login_attempts {
            key    {remote_host}
            events 5
            window 1m
        }
    }

    rate_limit @wp_jwt {
        zone jwt_auth {
            key    {remote_host}
            events 10
            window 1m
        }
    }

    rate_limit @wp_users_enum {
        zone users_enum {
            key    {remote_host}
            events 5
            window 1m
        }
    }

    rate_limit @wp_comments {
        zone comment_flood {
            key    {remote_host}
            events 10
            window 1m
        }
    }

    rate_limit @wp_rest_write {
        zone rest_write {
            key    {remote_host}
            events 20
            window 1m
        }
    }

    rate_limit @wp_search {
        zone search_flood {
            key    {remote_host}
            events 15
            window 1m
        }
    }

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

        # Omitir assinaturas do servidor e tecnologias
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

    @static {
        file
        path *.ico *.css *.js *.gif *.jpg *.jpeg *.png *.svg
        path *.woff *.woff2 *.webp *.avif *.mp4 *.webm
    }
    header @static Cache-Control "public, max-age=31536000, immutable"
}
