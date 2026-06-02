#!/usr/bin/env bash
# 容灾：主库远程访问准备、备用 API 节点连接检测、客户端 endpoints
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/os.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/os.sh"
# shellcheck source=lib/mysql-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/mysql-bootstrap.sh"

is_mysql_master_node() {
  load_install_info 2>/dev/null || true
  [[ "${INSTALL_ROLE:-}" == "db-only" || "${INSTALL_ROLE:-}" == "all-in-one" ]] || return 1
  [[ -f "${COMPOSE_DIR:-/opt/clashfeng/compose}/docker-compose.yml" ]] || return 1
  grep -q "mysql:" "${COMPOSE_DIR}/docker-compose.yml" 2>/dev/null
}

is_api_standby_node() {
  load_install_info 2>/dev/null || true
  [[ "${INSTALL_ROLE:-}" == "api-standby" ]]
}

compose_mysql_bind() {
  local envf="${COMPOSE_DIR}/.env"
  if [[ -f "${envf}" ]]; then
    grep -m1 '^MYSQL_BIND=' "${envf}" 2>/dev/null | cut -d= -f2- || true
  fi
}

mysql_listening_on_public() {
  local bind
  bind="$(compose_mysql_bind)"
  [[ "${bind}" == 0.0.0.0:* ]] || [[ "${bind}" == *:0.0.0.0:* ]]
}

print_cloud_security_group_hint() {
  local standby_ip="${1:-}"
  local master_ip
  master_ip="${MASTER_PUBLIC_IP:-$(public_ip)}"
  echo ""
  echo -e "${YELLOW}══ 云厂商安全组（必做）══${NC}"
  echo "  在【主库 VPS】控制台添加入站规则："
  echo "    协议 TCP  端口 3306  来源 ${standby_ip:-备用VPS公网IP}/32"
  echo "  主库公网 IP: ${master_ip}"
  echo "  切勿将 3306 对 0.0.0.0/0 开放"
  echo ""
}

print_standby_prerequisites() {
  echo ""
  echo -e "${CYAN}备用 API 节点安装前，主库 VPS 须已完成：${NC}"
  echo "  1. 主菜单 [9] → [2] 允许备用 API 节点 IP 访问 MySQL"
  echo "  2. 云安全组放行: 主库 ← 本机公网 IP → TCP 3306"
  echo "  3. 从主库 install-info 复制: MYSQL_PASSWORD、JWT_SECRET、ADMIN_INIT_SECRET"
  echo "  4. MYSQL_HOST 填【主库公网 IP】（非域名，除非域名解析到主库且未被封）"
  echo ""
  echo "  本机公网 IP（填到主库白名单）: $(public_ip)"
  echo ""
}

print_standby_troubleshooting() {
  echo ""
  echo -e "${RED}无法连接主库时的检查清单：${NC}"
  echo "  □ 主库已执行 [9]→[2] 并填入本机 IP: $(public_ip)"
  echo "  □ 主库 MYSQL_BIND 为 0.0.0.0:3306:3306（非仅 127.0.0.1）"
  echo "  □ 云安全组已放行 3306 ← $(public_ip)"
  echo "  □ MYSQL_HOST / 密码 / 库名与主库 install-info 一致"
  echo "  □ 在主库上: nc -zv ${MYSQL_HOST:-主库IP} 3306"
  print_cloud_security_group_hint "$(public_ip)"
}

test_remote_mysql_connection() {
  local host="${1:-${MYSQL_HOST:-}}"
  local port="${2:-${MYSQL_PORT:-3306}}"
  local user="${3:-${MYSQL_USER:-clashwin}}"
  local pass="${4:-${MYSQL_PASSWORD:-}}"
  local db="${5:-${MYSQL_DATABASE:-clashwin_auth}}"

  [[ -n "${host}" ]] || { err "缺少主库地址 MYSQL_HOST"; return 1; }
  [[ -n "${pass}" ]] || { err "缺少 MYSQL_PASSWORD"; return 1; }

  log "测试 MySQL ${user}@${host}:${port}/${db} ..."
  if docker run --rm mysql:8.0 mysql -h "${host}" -P "${port}" -u "${user}" -p"${pass}" \
    -e "SELECT 1 AS ok" "${db}" &>/dev/null; then
    log "主库连接成功"
    return 0
  fi
  err "主库连接失败"
  return 1
}

show_topology() {
  load_install_info 2>/dev/null || true
  INSTALL_INFO="${INSTALL_INFO:-/opt/clashfeng/install-info.env}"
  echo ""
  echo -e "${CYAN}════════════ 当前拓扑 ════════════${NC}"
  if [[ ! -f "${INSTALL_INFO}" ]]; then
    warn "未找到 ${INSTALL_INFO}"
    return 1
  fi
  echo "  角色:       ${INSTALL_ROLE:-未知}"
  echo "  安装目录:   ${INSTALL_DIR:-/opt/clashfeng}"
  [[ -n "${DOMAIN:-}" && "${DOMAIN}" != "_" ]] && echo "  域名:       ${DOMAIN}"
  if is_api_standby_node; then
    echo "  远程主库:   ${MYSQL_HOST:-未设置}:${MYSQL_PORT:-3306}/${MYSQL_DATABASE:-}"
    echo "  说明:       本机仅 API+Nginx，数据在远程主库"
  elif is_mysql_master_node; then
    echo "  本机 MySQL: ${MYSQL_DATABASE:-} (用户 ${MYSQL_USER:-})"
    echo "  端口绑定:   $(compose_mysql_bind || echo '127.0.0.1:3306:3306 (默认)')"
    if mysql_listening_on_public; then
      echo -e "  远程访问:   ${GREEN}已绑定 0.0.0.0${NC}"
    else
      echo -e "  远程访问:   ${YELLOW}仅本机 127.0.0.1 — 备用节点无法连入${NC}"
    fi
    echo "  主库公网 IP: ${MASTER_PUBLIC_IP:-$(public_ip)}"
    [[ -n "${ALLOWED_STANDBY_IPS:-}" ]] && echo "  已放行备用 IP: ${ALLOWED_STANDBY_IPS}"
  fi
  [[ -n "${ADMIN_PANEL_PATH:-}" ]] && echo "  管理路径:   ${ADMIN_PANEL_PATH}"
  return 0
}

secret_hash() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

verify_jwt_with_master_info() {
  load_install_info 2>/dev/null || true
  [[ -n "${JWT_SECRET:-}" ]] || die "本机未配置 JWT_SECRET"

  echo ""
  echo "请提供【主库】install-info.env 的路径（在主库 VPS 上: ${INSTALL_INFO:-/opt/clashfeng/install-info.env}）"
  read -r -p "主库 install-info 路径: " master_info
  [[ -f "${master_info}" ]] || die "文件不存在: ${master_info}"

  local master_jwt local_hash master_hash
  master_jwt="$(grep -m1 '^JWT_SECRET=' "${master_info}" | cut -d= -f2- || true)"
  [[ -n "${master_jwt}" ]] || die "主库文件中未找到 JWT_SECRET"

  local_hash="$(secret_hash "${JWT_SECRET}")"
  master_hash="$(secret_hash "${master_jwt}")"

  if [[ "${local_hash}" == "${master_hash}" ]]; then
    log "JWT_SECRET 与主库一致"
    return 0
  fi
  err "JWT_SECRET 与主库不一致，备用节点登录态将无法与主站互通"
  return 1
}

export_client_endpoints() {
  load_install_info 2>/dev/null || true
  [[ -n "${DOMAIN:-}" && "${DOMAIN}" != "_" && "${DOMAIN}" != "db-local" ]] || {
    die "请先配置本机域名（主菜单 [4] 或安装时填写）"
  }

  local scheme="https"
  if [[ "${TLS_MODE:-}" == "http" || "${SKIP_CERT:-0}" == "1" ]]; then
    scheme="http"
  elif ! ss -tlnp 2>/dev/null | grep -qE ':443[^0-9].*nginx|:443\s'; then
    scheme="http"
  fi

  local out="${INSTALL_DIR:-/opt/clashfeng}/endpoints.json"
  local backups_json="[]"
  echo ""
  echo "可选：输入备用 API 域名（逗号分隔，直接回车跳过）"
  read -r -p "备用域名: " backup_domains
  if [[ -n "${backup_domains}" ]]; then
    backups_json="["
    local first=1 d
    IFS=',' read -ra _domains <<< "${backup_domains}"
    for d in "${_domains[@]}"; do
      d="$(echo "${d}" | xargs)"
      [[ -n "${d}" ]] || continue
      [[ "${d}" != http* ]] && d="${scheme}://${d}"
      [[ "${first}" == 1 ]] || backups_json+=","
      backups_json+="\"${d}\""
      first=0
    done
    backups_json+="]"
  fi

  local updated
  updated="$(date -Iseconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

  cat > "${out}" <<EOF
{
  "primary": "${scheme}://${DOMAIN}",
  "backups": ${backups_json},
  "updated_at": "${updated}"
}
EOF
  chmod 644 "${out}"

  APP_DIR="${APP_DIR:-/opt/clashfeng/app}"
  if [[ -d "${APP_DIR}" ]]; then
    mkdir_p "${APP_DIR}/public"
    cp "${out}" "${APP_DIR}/public/endpoints.json"
    log "已同步到 ${APP_DIR}/public/endpoints.json"
    if systemctl is-active clashfeng-auth &>/dev/null 2>&1; then
      log "客户端拉取地址: ${scheme}://${DOMAIN}/public/endpoints.json"
      warn "若 API 进程不自动重读文件，可执行: systemctl restart clashfeng-auth"
    fi
  fi

  log "已写入 ${out}"
  cat "${out}"
  echo ""
  echo -e "${GREEN}ClashWin 客户端（方案 A）会自动：${NC}"
  echo "  1. 启动时探测主备线路（/auth/captcha）"
  echo "  2. 从 ${scheme}://${DOMAIN}/public/endpoints.json 拉取最新主备列表"
  echo "  3. 当前线路失败时自动切换 backups，无需用户手改配置"
  echo ""
  echo "  构建客户端时可设置 VITE_AUTH_API_PRIMARY / VITE_AUTH_API_BACKUPS 作为内置默认值"
}

update_compose_mysql_bind() {
  local new_bind="$1"
  local envf="${COMPOSE_DIR}/.env"
  [[ -f "${envf}" ]] || die "未找到 ${envf}"

  if grep -q '^MYSQL_BIND=' "${envf}"; then
    sed -i "s|^MYSQL_BIND=.*|MYSQL_BIND=${new_bind}|" "${envf}"
  else
    echo "MYSQL_BIND=${new_bind}" >> "${envf}"
  fi
  MYSQL_BIND="${new_bind}"
}

recreate_mysql_with_bind() {
  local tpl="${SCRIPT_DIR}/templates/docker-compose.${INSTALL_ROLE}.yml"
  if [[ -f "${tpl}" ]]; then
    cp "${tpl}" "${COMPOSE_DIR}/docker-compose.yml"
  fi
  cd "${COMPOSE_DIR}"
  log "按新端口绑定重建 MySQL 容器..."
  docker compose up -d mysql --force-recreate
  # shellcheck source=lib/app.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/app.sh"
  wait_mysql_healthy
  bootstrap_mysql_users
}

append_allowed_standby_ip() {
  local ip="$1"
  local current="${ALLOWED_STANDBY_IPS:-}"
  if [[ ",${current}," == *",${ip},"* ]]; then
    return 0
  fi
  if [[ -n "${current}" ]]; then
    ALLOWED_STANDBY_IPS="${current},${ip}"
  else
    ALLOWED_STANDBY_IPS="${ip}"
  fi
}

prepare_master_allow_standby_ip() {
  need_root
  load_install_info 2>/dev/null || true
  is_mysql_master_node || die "本机不是 MySQL 主库节点（需主站一体或仅数据库角色）"

  COMPOSE_DIR="${COMPOSE_DIR:-/opt/clashfeng/compose}"
  INSTALL_DIR="${INSTALL_DIR:-/opt/clashfeng}"
  INSTALL_INFO="${INSTALL_INFO:-${INSTALL_DIR}/install-info.env}"

  echo ""
  echo -e "${CYAN}════════ 主库：允许备用 API 节点连接 ════════${NC}"
  echo "  将把 MySQL 绑定为 0.0.0.0:3306（仍依赖防火墙/安全组仅放行指定 IP）"
  echo "  主库公网 IP: $(public_ip)"
  echo ""

  local standby_ip="${1:-}"
  if [[ -z "${standby_ip}" ]]; then
    read -r -p "备用 API VPS 公网 IP: " standby_ip
  fi
  [[ -n "${standby_ip}" ]] || die "请输入 IP"
  is_ip_address "${standby_ip}" || die "无效 IPv4: ${standby_ip}"

  MASTER_PUBLIC_IP="$(public_ip)"
  update_compose_mysql_bind "0.0.0.0:3306:3306"
  recreate_mysql_with_bind
  grant_mysql_user_from_host "${standby_ip}"
  allow_mysql_from_ip "${standby_ip}"
  append_allowed_standby_ip "${standby_ip}"
  save_install_info

  log "已允许 ${standby_ip} 访问本机 MySQL"
  print_cloud_security_group_hint "${standby_ip}"

  echo -e "${GREEN}下一步：在备用 VPS 上执行${NC}"
  echo "  git clone https://github.com/learningsduck/ClashFeng-management-install.git"
  echo "  sudo ./install.sh   # 选 [2] API 备用节点"
  echo "  MYSQL_HOST=${MASTER_PUBLIC_IP}"
  echo "  密码与 JWT 从本机 ${INSTALL_INFO} 复制"
}

standby_main_menu() {
  load_install_info 2>/dev/null || true

  echo ""
  echo -e "${CYAN}════════════ 容灾与主库连接 ════════════${NC}"
  show_topology 2>/dev/null || true
  echo ""
  echo "  [1] 查看拓扑 / 连接说明"
  echo "  [2] [主库] 允许备用 API 节点 IP 访问 MySQL"
  echo "  [3] [备用] 测试主库 MySQL 连接"
  echo "  [4] 导出客户端 endpoints.json"
  echo "  [5] 校验 JWT_SECRET 是否与主库一致"
  echo "  [6] 显示备用节点安装清单"
  echo "  [0] 返回主菜单"
  echo ""
  read -r -p "请选择 [0-6]: " schoice

  case "${schoice}" in
    1) show_topology ;;
    2) prepare_master_allow_standby_ip ;;
    3)
      if [[ -z "${MYSQL_HOST:-}" ]]; then
        prompt MYSQL_HOST "主库地址 (公网 IP)" ""
        prompt MYSQL_PORT "主库端口" "3306"
        prompt MYSQL_USER "主库用户" "${MYSQL_USER:-clashwin}"
        prompt MYSQL_PASSWORD "主库用户密码" ""
      fi
      if test_remote_mysql_connection; then
        :
      else
        print_standby_troubleshooting
      fi
      ;;
    4) export_client_endpoints ;;
    5) verify_jwt_with_master_info ;;
    6) print_standby_prerequisites ;;
    0) return 0 ;;
    *) err "无效选项"; standby_main_menu; return ;;
  esac
  echo ""
  read -r -p "按回车返回容灾菜单..." _
  standby_main_menu
}
