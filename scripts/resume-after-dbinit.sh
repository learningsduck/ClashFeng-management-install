#!/usr/bin/env bash
# db:init 完成后安装中断时，在服务器上执行本脚本继续（无需重新 Docker 构建）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/app.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/nginx.sh"

need_root
load_install_info
INSTALL_DIR="${INSTALL_DIR:-/opt/clashfeng}"
COMPOSE_DIR="${COMPOSE_DIR:-${INSTALL_DIR}/compose}"
APP_DIR="${APP_DIR:-${INSTALL_DIR}/app}"

log "从 db:init 之后继续安装..."
[[ -f "${APP_DIR}/dist/index.js" ]] || die "未找到 ${APP_DIR}/dist/index.js，请先完成 db:init"

if [[ -f "${COMPOSE_DIR}/docker-compose.yml" ]] && grep -q "mysql:" "${COMPOSE_DIR}/docker-compose.yml" 2>/dev/null; then
  cd "${COMPOSE_DIR}"
  docker compose up -d mysql 2>/dev/null || true
fi

cp "${COMPOSE_DIR}/.env" "${APP_DIR}/.env" 2>/dev/null || true
sed -i 's/^MYSQL_HOST=.*/MYSQL_HOST=127.0.0.1/' "${APP_DIR}/.env" 2>/dev/null || true

start_host_app_service

if [[ -n "${DOMAIN:-}" && -f "${SCRIPT_DIR}/templates/nginx.conf.tpl" ]]; then
  install_nginx_site 2>/dev/null || warn "Nginx 已配置或需手动配置"
  run_certbot 2>/dev/null || warn "Certbot 需手动执行"
fi

health_check || true
log "继续安装完成。访问: https://${DOMAIN:-127.0.0.1:3001}/"
