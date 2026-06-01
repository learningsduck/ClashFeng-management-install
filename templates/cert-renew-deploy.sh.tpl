#!/usr/bin/env bash
# Certbot renew deploy-hook：将证书同步到自定义目录并重载 Nginx
set -euo pipefail
DOMAIN="{{DOMAIN}}"
LE_DIR="/etc/letsencrypt/live/${DOMAIN}"
DEST_DIR="{{SSL_CERT_DIR}}"

[[ -f "${LE_DIR}/fullchain.pem" && -f "${LE_DIR}/privkey.pem" ]] || exit 0
[[ -n "${DEST_DIR}" ]] || exit 0

mkdir -p "${DEST_DIR}"
install -m 0644 "${LE_DIR}/fullchain.pem" "${DEST_DIR}/fullchain.pem"
install -m 0600 "${LE_DIR}/privkey.pem" "${DEST_DIR}/privkey.pem"
systemctl reload nginx
