[Unit]
Description=ClashFeng Auth Server (API + Admin)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory={{APP_DIR}}
EnvironmentFile={{APP_DIR}}/.env
ExecStart=/usr/bin/node dist/index.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
