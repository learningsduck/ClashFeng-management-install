#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# 宿主机经 127.0.0.1:3306 连接时，MySQL 看到的客户端常为 Docker 网桥 IP（如 172.18.0.1）
# 需确保业务用户密码与 .env 一致，且允许 % / localhost
bootstrap_mysql_users() {
  [[ -f "${COMPOSE_DIR}/docker-compose.yml" ]] || return 0
  grep -q "mysql:" "${COMPOSE_DIR}/docker-compose.yml" 2>/dev/null || return 0

  cd "${COMPOSE_DIR}"
  log "同步 MySQL 用户 ${MYSQL_USER}（修复宿主机连接 Access denied）..."

  local root_pw="${MYSQL_ROOT_PASSWORD:-}"
  if [[ -z "${root_pw}" && -f "${COMPOSE_DIR}/.env" ]]; then
    root_pw="$(grep -m1 '^MYSQL_ROOT_PASSWORD=' "${COMPOSE_DIR}/.env" | cut -d= -f2- || true)"
  fi
  [[ -n "${root_pw}" ]] || die "缺少 MYSQL_ROOT_PASSWORD，请检查 ${COMPOSE_DIR}/.env"

  local sql
  sql="CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER '${MYSQL_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
ALTER USER '${MYSQL_USER}'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'localhost';
FLUSH PRIVILEGES;"

  if ! docker compose exec -T mysql mysql -uroot -p"${root_pw}" --default-character-set=utf8mb4 -e "${sql}" 2>/dev/null; then
    warn "mysql_native_password 可能不适用，尝试 caching_sha2 默认方式..."
    sql="CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'localhost';
FLUSH PRIVILEGES;"
    docker compose exec -T mysql mysql -uroot -p"${root_pw}" --default-character-set=utf8mb4 -e "${sql}"
  fi

  log "验证业务用户连接..."
  if docker run --rm --network host mysql:8.0 mysql -h 127.0.0.1 -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -e "SELECT 1" &>/dev/null; then
    log "MySQL 用户 ${MYSQL_USER}@127.0.0.1 连接成功"
  elif mysql -h 127.0.0.1 -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -e "SELECT 1" &>/dev/null 2>&1; then
    log "MySQL 用户连接成功"
  else
    warn "业务用户验证失败。若曾重装且未删数据卷，请执行:"
    warn "  sudo ./install.sh --uninstall --reinstall -y"
    warn "然后重新安装，或手动用 root 修改 clashwin 密码与 install-info.env 一致"
  fi
}
