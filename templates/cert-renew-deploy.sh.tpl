#!/usr/bin/env bash
# Certbot renew deploy-hook：将证书同步到自定义路径并重载 Nginx
set -euo pipefail
DOMAIN="{{DOMAIN}}"
LE_DIR="/etc/letsencrypt/live/${DOMAIN}"
DEST_CERT="{{SSL_CERT_PATH}}"
DEST_KEY="{{SSL_KEY_PATH}}"

[[ -f "${LE_DIR}/fullchain.pem" && -f "${LE_DIR}/privkey.pem" ]] || exit 0

mkdir -p "$(dirname "${DEST_CERT}")" "$(dirname "${DEST_KEY}")"
install -m 0644 "${LE_DIR}/fullchain.pem" "${DEST_CERT}"
install -m 0600 "${LE_DIR}/privkey.pem" "${DEST_KEY}"
systemctl reload nginx
