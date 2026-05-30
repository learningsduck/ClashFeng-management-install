#!/usr/bin/env bash
# ClashFeng 管理后台 + API 一键安装
# 用法: sudo ./install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/secrets.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/app.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/nginx.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/health.sh"

banner() {
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║     ClashFeng 管理后台 + API 一键安装  v1.0.0        ║"
  echo "║     CentOS 7/8/9 · 宿主机 Nginx · Docker MySQL      ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

main_menu() {
  echo ""
  echo "请选择安装角色:"
  echo "  [1] 主站一体 — MySQL 主库 + API + 管理后台 (推荐首台)"
  echo "  [2] API 备用节点 — 连接远程主库 (容灾)"
  echo "  [3] 仅数据库主库 — 无 Nginx / 无 App"
  echo "  [4] 维护工具"
  echo "  [0] 退出"
  echo ""
  read -r -p "请输入选项 [0-4]: " choice
  case "${choice}" in
    1) INSTALL_ROLE=all-in-one; run_all_in_one ;;
    2) INSTALL_ROLE=api-standby; run_api_standby ;;
    3) INSTALL_ROLE=db-only; run_db_only ;;
    4) maintenance_menu ;;
    0) exit 0 ;;
    *) err "无效选项"; main_menu ;;
  esac
}

maintenance_menu() {
  echo ""
  echo "维护工具:"
  echo "  [a] 健康检查"
  echo "  [b] 续签 Let's Encrypt 证书"
  echo "  [c] 查看 install-info (密钥已脱敏)"
  echo "  [0] 返回"
  read -r -p "请选择: " m
  case "${m}" in
    a) health_check || true; main_menu ;;
    b) renew_cert; main_menu ;;
    c) show_install_info; main_menu ;;
    0) main_menu ;;
    *) maintenance_menu ;;
  esac
}

prompt_domain_cert() {
  prompt DOMAIN "域名 (管理后台与 API 同域)" "${DOMAIN:-}"
  prompt ADMIN_EMAIL "Certbot 邮箱" "${ADMIN_EMAIL:-}"
  if prompt_yn "检查 DNS 是否指向本机公网 IP?" "Y"; then
    SKIP_DNS_CHECK=0
  else
    SKIP_DNS_CHECK=1
  fi
}

prompt_security() {
  prompt INSTALL_DIR "安装根目录" "${INSTALL_DIR}"
  COMPOSE_DIR="${INSTALL_DIR}/compose"
  APP_DIR="${INSTALL_DIR}/app"
  prompt ADMIN_IP_WHITELIST "管理后台 IP 白名单 (可选, 逗号分隔)" "${ADMIN_IP_WHITELIST:-}"
  REQUIRE_HTTPS=true
  if prompt_yn "生产环境强制 HTTPS (REQUIRE_HTTPS)?" "Y"; then
    REQUIRE_HTTPS=true
  else
    REQUIRE_HTTPS=false
  fi
}

confirm_install() {
  echo ""
  echo -e "${CYAN}══════════════ 安装摘要 ══════════════${NC}"
  echo "  角色:     ${INSTALL_ROLE}"
  echo "  访问地址: https://${DOMAIN}/"
  echo "  安装目录: ${INSTALL_DIR}"
  echo "  MySQL:    ${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DATABASE}"
  echo "  Nginx:    宿主机 + Let's Encrypt 自动续签"
  echo "  后端仓库: ${AUTH_REPO_URL} (${AUTH_REPO_BRANCH})"
  echo -e "${CYAN}══════════════════════════════════════${NC}"
  echo ""
  prompt_yn "确认开始安装?" "Y" || { warn "已取消"; exit 0; }
}

show_done() {
  save_install_info
  echo ""
  echo -e "${GREEN}════════════════ 安装完成 ════════════════${NC}"
  echo "  管理后台: https://${DOMAIN}/"
  echo "  API 示例: https://${DOMAIN}/auth/captcha"
  echo "  密钥文件: ${INSTALL_INFO}  (权限 600，请妥善保管)"
  echo ""
  echo "  首次使用: 打开管理后台 → 初始化管理员"
  echo "  初始化密钥 (ADMIN_INIT_SECRET) 见 install-info"
  echo ""
  if [[ "${INSTALL_ROLE}" == "all-in-one" ]]; then
    echo "  备用 VPS: 运行本脚本选 [2]，填写主库地址与相同 JWT_SECRET"
    echo "  客户端线路示例: ${SCRIPT_DIR}/endpoints.json.example"
  fi
  echo -e "${GREEN}════════════════════════════════════════${NC}"
  health_check || true
}

run_all_in_one() {
  prompt_domain_cert
  prompt_security
  MYSQL_HOST=mysql
  MYSQL_PORT=3306
  MYSQL_DATABASE="${MYSQL_DATABASE}"
  MYSQL_USER="${MYSQL_USER}"
  generate_secrets
  confirm_install

  mkdir_p "${INSTALL_DIR}" "${COMPOSE_DIR}" "${APP_DIR}"
  install_base_packages
  check_env
  install_docker
  open_firewall_http
  clone_auth_repo
  write_app_env
  write_compose_file

  cd "${COMPOSE_DIR}"
  docker compose up -d mysql
  wait_mysql_healthy
  run_db_init
  docker compose up -d
  docker_compose_up

  install_nginx_certbot
  install_nginx_site
  run_certbot || warn "证书申请未成功，可稍后手动 certbot --nginx -d ${DOMAIN}"

  show_done
}

run_api_standby() {
  echo ""
  echo -e "${YELLOW}备用节点: JWT_SECRET 必须与主站完全相同${NC}"
  prompt_domain_cert
  prompt INSTALL_DIR "安装根目录" "${INSTALL_DIR}"
  COMPOSE_DIR="${INSTALL_DIR}/compose"
  APP_DIR="${INSTALL_DIR}/app"
  prompt MYSQL_HOST "主库地址 (内网 IP 或域名)" ""
  prompt MYSQL_PORT "主库端口" "3306"
  MYSQL_DATABASE="${MYSQL_DATABASE}"
  MYSQL_USER="${MYSQL_USER}"
  prompt MYSQL_PASSWORD "主库用户密码 (与主站 clashwin 用户一致)" ""
  prompt JWT_SECRET "JWT_SECRET (从主站 install-info 复制)" ""
  prompt ADMIN_INIT_SECRET "ADMIN_INIT_SECRET (与主站一致)" ""
  prompt ADMIN_IP_WHITELIST "管理后台 IP 白名单 (可选)" "${ADMIN_IP_WHITELIST:-}"
  REQUIRE_HTTPS=true
  confirm_install

  mkdir_p "${INSTALL_DIR}" "${COMPOSE_DIR}" "${APP_DIR}"
  install_base_packages
  check_env
  install_docker
  open_firewall_http
  clone_auth_repo
  write_app_env
  write_compose_file

  log "测试连接主库 ${MYSQL_HOST}:${MYSQL_PORT} ..."
  if ! docker run --rm mysql:8.0 mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -e "SELECT 1" &>/dev/null; then
    die "无法连接主库，请检查 MYSQL_HOST、密码、主库防火墙/安全组"
  fi
  log "主库连接成功"

  docker_compose_up

  install_nginx_certbot
  install_nginx_site
  run_certbot || warn "证书申请未成功"

  show_done
}

run_db_only() {
  prompt INSTALL_DIR "安装根目录" "${INSTALL_DIR}"
  COMPOSE_DIR="${INSTALL_DIR}/compose"
  MYSQL_DATABASE="${MYSQL_DATABASE}"
  MYSQL_USER="${MYSQL_USER}"
  generate_secrets
  echo ""
  echo "MySQL 端口绑定 (示例):"
  echo "  127.0.0.1:3306:3306 — 仅本机"
  echo "  0.0.0.0:3306:3306 — 允许远程 (需配合安全组+白名单)"
  prompt MYSQL_BIND "端口映射" "127.0.0.1:3306:3306"
  read -r -p "允许访问 3306 的备用 VPS IP (可选): " standby_ip
  confirm_install

  mkdir_p "${INSTALL_DIR}" "${COMPOSE_DIR}"
  install_base_packages
  detect_os
  install_docker

  cat > "${COMPOSE_DIR}/.env" <<EOF
APP_DIR=${APP_DIR}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_BIND=${MYSQL_BIND}
EOF
  chmod 600 "${COMPOSE_DIR}/.env"
  cp "${SCRIPT_DIR}/templates/docker-compose.db-only.yml" "${COMPOSE_DIR}/docker-compose.yml"

  cd "${COMPOSE_DIR}"
  docker compose up -d
  wait_mysql_healthy

  [[ -n "${standby_ip:-}" ]] && allow_mysql_from_ip "${standby_ip}"

  DOMAIN="${DOMAIN:-db-local}"
  save_install_info
  log "数据库主库已启动。API 节点 MYSQL_HOST 填本机内网 IP。"
  echo "  root 密码、业务密码见: ${INSTALL_INFO}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --health) health_check; exit $? ;;
      --renew-cert) need_root; renew_cert; exit 0 ;;
      --show-info) show_install_info; exit 0 ;;
      --role=*) INSTALL_ROLE="${1#*=}"; shift ;;
      --domain=*) DOMAIN="${1#*=}"; shift ;;
      --email=*) ADMIN_EMAIL="${1#*=}"; shift ;;
      --dir=*) INSTALL_DIR="${1#*=}"; COMPOSE_DIR="${INSTALL_DIR}/compose"; APP_DIR="${INSTALL_DIR}/app"; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      -h|--help)
        echo "用法: sudo ./install.sh [选项]"
        echo "  --health          健康检查"
        echo "  --renew-cert      续签证书"
        echo "  --show-info       查看安装信息"
        echo "  --role=all-in-one|api-standby|db-only"
        echo "  --domain= --email= --dir=  非交互安装 (需配合 -y)"
        exit 0
        ;;
      *) die "未知参数: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  need_root
  banner
  mkdir_p "${INSTALL_DIR}"
  touch "${LOG_FILE}"

  detect_os
  check_env

  if [[ -n "${INSTALL_ROLE:-}" && "${ASSUME_YES:-0}" == "1" ]]; then
    case "${INSTALL_ROLE}" in
      all-in-one) run_all_in_one ;;
      api-standby) run_api_standby ;;
      db-only) run_db_only ;;
      *) die "未知角色: ${INSTALL_ROLE}" ;;
    esac
    exit 0
  fi

  main_menu
}

main "$@"
