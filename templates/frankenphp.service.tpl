[Unit]
Description=FrankenPHP Server
Documentation=https://frankenphp.dev
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=notify
User=www-data
Group=www-data
WorkingDirectory=/etc/frankenphp
ExecStart=/usr/local/bin/frankenphp run --config /etc/frankenphp/Caddyfile
ExecReload=/bin/kill -USR1 $MAINPID
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=65535
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
