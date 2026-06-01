#!/usr/bin/env bash
# Docker / 安装目录清理（卸载与重装共用）
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# 列出可能残留的 ClashFeng MySQL 数据卷
clashfeng_mysql_volumes() {
  docker volume ls -q 2>/dev/null | grep -iE 'mysql_data|clashfeng' || true
}

# 删除所有匹配的 Docker 数据卷（含 compose 未 down -v 的残留）
purge_clashfeng_docker_volumes() {
  local vol
  while IFS= read -r vol; do
    [[ -z "${vol}" ]] && continue
    log "删除 Docker 数据卷: ${vol}"
    docker volume rm -f "${vol}" 2>/dev/null || true
  done < <(clashfeng_mysql_volumes)
}

# 停止并删除 compose 项目（含卷）
compose_down_with_volumes() {
  local compose_dir="$1"
  [[ -d "${compose_dir}" && -f "${compose_dir}/docker-compose.yml" ]] || return 0
  log "停止 Docker Compose（${compose_dir}）..."
  (
    cd "${compose_dir}"
    docker compose down -v --remove-orphans 2>/dev/null \
      || docker compose down --remove-orphans -v 2>/dev/null \
      || true
  )
  purge_clashfeng_docker_volumes
}

# 用 root 密码探测 MySQL 容器是否可登录
mysql_root_password_works() {
  local root_pw="$1"
  local compose_dir="$2"
  [[ -n "${root_pw}" && -d "${compose_dir}" ]] || return 1
  docker compose -f "${compose_dir}/docker-compose.yml" exec -T mysql \
    mysqladmin ping -h localhost -uroot -p"${root_pw}" &>/dev/null
}

# 读取即将用于安装的 root 密码（优先 compose/.env，其次 install-info）
mysql_root_password_from_config() {
  local pw=""
  if [[ -f "${COMPOSE_DIR}/.env" ]]; then
    pw="$(grep -m1 '^MYSQL_ROOT_PASSWORD=' "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d= -f2- || true)"
  fi
  if [[ -z "${pw}" && -f "${INSTALL_INFO}" ]]; then
    pw="$(grep -m1 '^MYSQL_ROOT_PASSWORD=' "${INSTALL_INFO}" 2>/dev/null | cut -d= -f2- || true)"
  fi
  printf '%s' "${pw}"
}

# 安装前：若存在旧数据卷但密码与配置不一致，自动清卷，避免 root Access denied
ensure_mysql_volume_matches_config() {
  [[ -f "${COMPOSE_DIR}/docker-compose.yml" ]] || return 0
  grep -q "mysql:" "${COMPOSE_DIR}/docker-compose.yml" 2>/dev/null || return 0

  local vols
  vols="$(clashfeng_mysql_volumes | tr '\n' ' ')"
  [[ -n "${vols// }" ]] || return 0

  local root_pw
  root_pw="$(mysql_root_password_from_config)"

  if [[ -z "${root_pw}" ]]; then
    warn "检测到 MySQL 数据卷（${vols}）但无 MYSQL_ROOT_PASSWORD 配置，将清空数据卷"
    compose_down_with_volumes "${COMPOSE_DIR}"
    return 0
  fi

  if ! docker compose -f "${COMPOSE_DIR}/docker-compose.yml" ps mysql 2>/dev/null | grep -qE 'running|Up'; then
    return 0
  fi

  if mysql_root_password_works "${root_pw}" "${COMPOSE_DIR}"; then
    log "MySQL 数据卷与当前配置密码一致"
    return 0
  fi

  warn "MySQL 数据卷密码与 .env/install-info 不一致（重装常见原因），自动清空数据卷..."
  compose_down_with_volumes "${COMPOSE_DIR}"
  # 新安装将使用 generate_secrets 生成的新密码
  unset MYSQL_ROOT_PASSWORD MYSQL_PASSWORD JWT_SECRET ADMIN_INIT_SECRET 2>/dev/null || true
  rm -f "${COMPOSE_DIR}/.env" "${APP_DIR}/.env" "${INSTALL_INFO}" 2>/dev/null || true
}

# 删除安装目录内会导致重装冲突的文件（在未 purge-all 时可选）
remove_stale_install_configs() {
  rm -f "${INSTALL_INFO}" "${COMPOSE_DIR}/.env" "${APP_DIR}/.env" 2>/dev/null || true
}
