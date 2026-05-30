#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/mysql-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/mysql-bootstrap.sh"

SYSTEMD_UNIT="/etc/systemd/system/clashfeng-auth.service"

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

  local db_host="${MYSQL_HOST}"
  if [[ "${INSTALL_ROLE}" == "all-in-one" ]]; then
    db_host="127.0.0.1"
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

MYSQL_HOST=${db_host}
MYSQL_PORT=${MYSQL_PORT}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-}

DATA_DIR=${APP_DIR}/data
SMS_PROVIDER=${SMS_PROVIDER}
EMAIL_PROVIDER=${EMAIL_PROVIDER}
${admin_ip_line}
EOF
  chmod 600 "${COMPOSE_DIR}/.env"
  cp "${COMPOSE_DIR}/.env" "${APP_DIR}/.env"
  chmod 600 "${APP_DIR}/.env"
  mkdir_p "${APP_DIR}/data"
}

write_compose_file() {
  local tpl="${SCRIPT_DIR}/templates/docker-compose.${INSTALL_ROLE}.yml"
  [[ -f "${tpl}" ]] || die "缺少模板: ${tpl}"
  cp "${tpl}" "${COMPOSE_DIR}/docker-compose.yml"
}

ensure_node() {
  if command -v node &>/dev/null; then
    return 0
  fi
  log "安装 Node.js（宿主机运行 API）..."
  if [[ "${OS_MAJOR:-8}" == "7" ]]; then
    curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
    yum install -y nodejs
  else
    curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
    dnf install -y nodejs
  fi
}

build_app() {
  ensure_node
  log "编译 ClashFeng-auth（npm ci + build）..."
  (
    cd "${APP_DIR}"
    npm ci
    npm run build
  )
  log "编译完成"
}

run_db_init() {
  log "初始化 MySQL 表结构..."
  ensure_node
  build_app

  local init_host="127.0.0.1"
  if [[ "${INSTALL_ROLE}" == "api-standby" ]]; then
    init_host="${MYSQL_HOST}"
  fi

  sed -i "s/^MYSQL_HOST=.*/MYSQL_HOST=${init_host}/" "${APP_DIR}/.env"

  log "执行 init-mysql.mjs ..."
  if ! (cd "${APP_DIR}" && node scripts/init-mysql.mjs); then
    warn "业务用户建表失败，尝试使用 root 账户初始化..."
    (
      cd "${APP_DIR}"
      MYSQL_USER=root MYSQL_PASSWORD="${MYSQL_ROOT_PASSWORD}" node scripts/init-mysql.mjs
    )
    bootstrap_mysql_users
  fi
  log "数据库表结构初始化完成"
}

docker_compose_mysql_up() {
  if [[ ! -f "${COMPOSE_DIR}/docker-compose.yml" ]]; then
    return 0
  fi
  if ! grep -q "mysql:" "${COMPOSE_DIR}/docker-compose.yml" 2>/dev/null; then
    return 0
  fi
  log "启动 Docker MySQL..."
  cd "${COMPOSE_DIR}"
  docker compose up -d mysql
  wait_mysql_healthy
  bootstrap_mysql_users
}

install_systemd_service() {
  log "配置 systemd 服务 clashfeng-auth ..."
  render_template "${SCRIPT_DIR}/templates/clashfeng-auth.service.tpl" "${SYSTEMD_UNIT}"
  systemctl daemon-reload
  systemctl enable clashfeng-auth
  systemctl restart clashfeng-auth
}

start_host_app_service() {
  echo ""
  log "=========================================="
  log "启动 API（宿主机 Node + systemd）"
  log "已跳过 Docker 构建应用镜像，避免长时间无输出"
  log "=========================================="
  echo ""

  [[ -f "${APP_DIR}/dist/index.js" ]] || die "缺少 ${APP_DIR}/dist/index.js，请先 build"

  install_systemd_service

  log "等待应用就绪..."
  local i
  for i in $(seq 1 40); do
    if curl -sf "http://127.0.0.1:${APP_PORT}/auth/captcha" >/dev/null 2>&1; then
      log "应用已响应 http://127.0.0.1:${APP_PORT}"
      systemctl --no-pager status clashfeng-auth | head -5 || true
      return 0
    fi
    if ! systemctl is-active clashfeng-auth &>/dev/null; then
      warn "服务未运行，最近日志:"
      journalctl -u clashfeng-auth -n 20 --no-pager || true
    fi
    sleep 2
  done
  die "应用启动超时。执行: journalctl -u clashfeng-auth -f"
}

# 保留：仅当 USE_DOCKER_APP=1 时使用（默认不再调用）
docker_compose_up() {
  cd "${COMPOSE_DIR}"
  export DOCKER_BUILDKIT=1
  log "Docker 模式构建应用（较慢）..."
  docker compose build --progress=plain app
  docker compose up -d
  local i
  for i in $(seq 1 30); do
    curl -sf "http://127.0.0.1:${APP_PORT}/auth/captcha" >/dev/null 2>&1 && return 0
    sleep 2
  done
  warn "应用启动超时"
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
  die "MySQL 启动超时，请检查: docker compose -f ${COMPOSE_DIR}/docker-compose.yml logs mysql"
}

stop_host_app_service() {
  systemctl stop clashfeng-auth 2>/dev/null || true
  systemctl disable clashfeng-auth 2>/dev/null || true
  rm -f "${SYSTEMD_UNIT}"
  systemctl daemon-reload 2>/dev/null || true
}
