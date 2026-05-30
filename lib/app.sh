#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

clone_auth_repo() {
  mkdir_p "${APP_DIR}"
  if [[ -d "${APP_DIR}/.git" ]]; then
    log "更新 ClashFeng-auth..."
    git -C "${APP_DIR}" fetch origin
    git -C "${APP_DIR}" checkout "${AUTH_REPO_BRANCH}"
    git -C "${APP_DIR}" pull --ff-only origin "${AUTH_REPO_BRANCH}" || warn "git pull 失败，使用本地代码继续"
  else
    log "克隆 ${AUTH_REPO_URL} ..."
    git clone --depth 1 -b "${AUTH_REPO_BRANCH}" "${AUTH_REPO_URL}" "${APP_DIR}"
  fi
}

write_app_env() {
  mkdir_p "${COMPOSE_DIR}"
  local admin_ip_line=""
  if [[ -n "${ADMIN_IP_WHITELIST:-}" ]]; then
    admin_ip_line="ADMIN_IP_WHITELIST=${ADMIN_IP_WHITELIST}"
  fi

  cat > "${COMPOSE_DIR}/.env" <<EOF
APP_DIR=${APP_DIR}
PORT=${APP_PORT}
NODE_ENV=${NODE_ENV}
REQUIRE_HTTPS=${REQUIRE_HTTPS}

JWT_SECRET=${JWT_SECRET}
JWT_ACCESS_EXPIRES_IN=${JWT_ACCESS_EXPIRES_IN}
JWT_REFRESH_EXPIRES_IN=${JWT_REFRESH_EXPIRES_IN}
ADMIN_INIT_SECRET=${ADMIN_INIT_SECRET}

MYSQL_HOST=${MYSQL_HOST}
MYSQL_PORT=${MYSQL_PORT}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-}

DATA_DIR=/app/data
SMS_PROVIDER=${SMS_PROVIDER}
EMAIL_PROVIDER=${EMAIL_PROVIDER}
${admin_ip_line}
EOF
  chmod 600 "${COMPOSE_DIR}/.env"
}

write_compose_file() {
  local tpl="${SCRIPT_DIR}/templates/docker-compose.${INSTALL_ROLE}.yml"
  [[ -f "${tpl}" ]] || die "缺少模板: ${tpl}"
  cp "${tpl}" "${COMPOSE_DIR}/docker-compose.yml"
}

run_db_init() {
  log "初始化数据库表结构..."
  local init_host="${MYSQL_HOST}"
  if [[ "${INSTALL_ROLE}" == "all-in-one" ]]; then
    init_host="127.0.0.1"
  fi

  if ! command -v node &>/dev/null; then
    log "安装 Node.js 22 用于 db:init（仅初始化阶段）..."
    if [[ "${OS_MAJOR:-8}" == "7" ]]; then
      curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
      yum install -y nodejs
    else
      curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
      dnf install -y nodejs
    fi
  fi

  cp "${COMPOSE_DIR}/.env" "${APP_DIR}/.env"
  sed -i "s/^MYSQL_HOST=.*/MYSQL_HOST=${init_host}/" "${APP_DIR}/.env"

  (
    cd "${APP_DIR}"
    npm ci
    npm run build
    node scripts/init-mysql.mjs
  )
  log "数据库表结构初始化完成（宿主机 Node 阶段结束）"
}

docker_compose_up() {
  cd "${COMPOSE_DIR}"
  echo ""
  log "=========================================="
  log "下一步: 构建 Docker 应用镜像（不是卡死）"
  log "首次需拉取 node:22 镜像并在容器内 npm install"
  log "国外 VPS 约 5–15 分钟，慢网可能 20–40 分钟"
  log "另开 SSH 可看进度: cd ${COMPOSE_DIR} && docker compose build --progress=plain app"
  log "=========================================="
  echo ""

  export DOCKER_BUILDKIT=1
  docker compose build --progress=plain app

  log "镜像构建完成，正在启动容器..."
  docker compose up -d

  log "等待应用就绪（/auth/captcha）..."
  local i
  for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${APP_PORT}/auth/captcha" >/dev/null 2>&1; then
      log "应用已响应"
      return 0
    fi
    sleep 2
  done
  warn "应用启动超时，请检查: docker compose -f ${COMPOSE_DIR}/docker-compose.yml logs"
}

wait_mysql_healthy() {
  log "等待 MySQL 就绪..."
  cd "${COMPOSE_DIR}"
  local i
  for i in $(seq 1 60); do
    if docker compose ps mysql 2>/dev/null | grep -q healthy; then
      log "MySQL 健康检查通过"
      return 0
    fi
    if docker compose exec -T mysql mysqladmin ping -h localhost -u root -p"${MYSQL_ROOT_PASSWORD}" &>/dev/null; then
      log "MySQL 已响应"
      return 0
    fi
    sleep 2
  done
  die "MySQL 启动超时，请检查 docker compose logs mysql"
}
