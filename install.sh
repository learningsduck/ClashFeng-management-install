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
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/uninstall.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/tls.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/admin-mgmt.sh"

banner() {
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║     ClashFeng 管理后台 + API 一键安装  v1.2.0        ║"
  echo "║     API: 宿主机 Node · MySQL: Docker · Nginx 宿主机  ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

main_menu() {
  echo ""
  echo "请选择安装角色:"
  echo "  [1] 主站一体 — MySQL 主库 + API + 管理后台 (推荐首台)"
  echo "  [2] API 备用节点 — 连接远程主库 (容灾)"
  echo "  [3] 仅数据库主库 — 无 Nginx / 无 App"
  echo "  [4] HTTPS / TLS 证书 (Let's Encrypt)"
  echo "  [5] 管理员账户管理"
  echo "  [6] 维护工具"
  echo "  [7] 一键卸载"
  echo "  [0] 退出"
  echo ""
  read -r -p "请输入选项 [0-7]: " choice
  case "${choice}" in
    1) INSTALL_ROLE=all-in-one; run_all_in_one ;;
    2) INSTALL_ROLE=api-standby; run_api_standby ;;
    3) INSTALL_ROLE=db-only; run_db_only ;;
    4) tls_main_menu; main_menu ;;
    5) admin_management_menu; main_menu ;;
    6) maintenance_menu ;;
    7) uninstall_menu; main_menu ;;
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
  echo "  [d] 管理员账户管理"
  echo "  [e] 一键卸载"
  echo "  [0] 返回"
  read -r -p "请选择: " m
  case "${m}" in
    a) health_check || true; main_menu ;;
    b) renew_cert; main_menu ;;
    c) show_install_info; main_menu ;;
    d) admin_management_menu; main_menu ;;
    e) uninstall_menu; main_menu ;;
    0) main_menu ;;
    *) maintenance_menu ;;
  esac
}

is_ip_address() {
  [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

prompt_domain_cert() {
  prompt DOMAIN "域名 (管理后台与 API 同域)" "${DOMAIN:-}"
  if is_ip_address "${DOMAIN}"; then
    warn "使用 IP 作为访问地址，将跳过 Let's Encrypt（仅 HTTP）"
    TLS_MODE=http
    SKIP_CERT=1
    REQUIRE_HTTPS=false
  fi
  if [[ "${SKIP_DNS_CHECK:-0}" == "1" ]]; then
    :
  elif prompt_yn "检查 DNS 是否指向本机公网 IP?" "Y"; then
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
  if [[ "${SKIP_CERT:-0}" == "1" ]]; then
    REQUIRE_HTTPS=false
  elif prompt_yn "生产环境强制 HTTPS (REQUIRE_HTTPS)?" "Y"; then
    REQUIRE_HTTPS=true
  else
    REQUIRE_HTTPS=false
  fi
}

confirm_install() {
  echo ""
  echo -e "${CYAN}══════════════ 安装摘要 ══════════════${NC}"
  echo "  角色:     ${INSTALL_ROLE}"
  if [[ "${TLS_MODE:-}" == "http" || "${SKIP_CERT:-0}" == "1" ]]; then
    echo "  访问地址: http://${DOMAIN}/"
  else
    echo "  访问地址: https://${DOMAIN}/"
  fi
  echo "  安装目录: ${INSTALL_DIR}"
  echo "  MySQL:    ${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DATABASE}"
  echo "  TLS:      $(tls_mode_label)"
  echo "  Nginx:    宿主机反向代理"
  echo "  后端仓库: ${AUTH_REPO_URL} (${AUTH_REPO_BRANCH})"
  echo -e "${CYAN}══════════════════════════════════════${NC}"
  echo ""
  prompt_yn "确认开始安装?" "Y" || { warn "已取消"; exit 0; }
}

show_done() {
  save_install_info
  echo ""
  echo -e "${GREEN}════════════════ 安装完成 ════════════════${NC}"
  if [[ "${TLS_MODE:-}" == "http" ]]; then
    echo "  管理后台: http://${DOMAIN}/"
    echo "  API 示例: http://${DOMAIN}/auth/captcha"
  else
    echo "  管理后台: https://${DOMAIN}/"
    echo "  API 示例: https://${DOMAIN}/auth/captcha"
  fi
  echo "  密钥文件: ${INSTALL_INFO}  (权限 600，请妥善保管)"
  echo ""
  echo "  首次使用: 运行本脚本 [5] 创建管理员，再访问下方管理后台地址"
  show_admin_panel_url
  echo "  公网首页 https://${DOMAIN}/ 仅为中性门户，不暴露管理功能"
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
  prompt_tls_settings
  prompt_security
  MYSQL_HOST=127.0.0.1
  MYSQL_PORT=3306
  MYSQL_DATABASE="${MYSQL_DATABASE}"
  MYSQL_USER="${MYSQL_USER}"
  clear_stale_install_env
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

  docker_compose_mysql_up
  run_db_init
  start_host_app_service

  install_nginx_certbot
  apply_tls_configuration || warn "HTTPS 配置未完全成功，可稍后在主菜单 [4] 重试"

  show_done
}

run_api_standby() {
  echo ""
  echo -e "${YELLOW}备用节点: JWT_SECRET 必须与主站完全相同${NC}"
  prompt_domain_cert
  prompt_tls_settings
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

  log "测试连接主库 ${MYSQL_HOST}:${MYSQL_PORT} ..."
  if ! docker run --rm mysql:8.0 mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -e "SELECT 1" &>/dev/null; then
    die "无法连接主库，请检查 MYSQL_HOST、密码、主库防火墙/安全组"
  fi
  log "主库连接成功"

  build_app
  start_host_app_service

  install_nginx_certbot
  apply_tls_configuration || warn "HTTPS 配置未完全成功"

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
      --uninstall)
        need_root
        load_install_info
        UNINSTALL_YES=1
        REMOVE_NGINX=1
        shift
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --reinstall) PREPARE_REINSTALL=1; shift ;;
            --purge-data) PURGE_DATA=1; shift ;;
            --purge-all) PURGE_ALL=1; PURGE_DATA=1; shift ;;
            --purge-images) PURGE_IMAGES=1; shift ;;
            --remove-cert) REMOVE_CERT=1; shift ;;
            -y|--yes) UNINSTALL_YES=1; shift ;;
            *) break ;;
          esac
        done
        run_uninstall
        exit 0
        ;;
      --role=*) INSTALL_ROLE="${1#*=}"; shift ;;
      --domain=*) DOMAIN="${1#*=}"; shift ;;
      --email=*) ADMIN_EMAIL="${1#*=}"; shift ;;
      --dir=*) INSTALL_DIR="${1#*=}"; COMPOSE_DIR="${INSTALL_DIR}/compose"; APP_DIR="${INSTALL_DIR}/app"; shift ;;
      --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
      --skip-cert) SKIP_CERT=1; TLS_MODE=http; REQUIRE_HTTPS=false; shift ;;
      --tls=*) TLS_MODE="${1#*=}"; shift ;;
      --cert-dir=*) SSL_CERT_DIR="${1#*=}"; TLS_MODE=letsencrypt-manual; shift ;;
      --cert-fullchain=*) SSL_CERT_DIR="$(dirname "${1#*=}")"; SSL_CERT_PATH="${1#*=}"; TLS_MODE=letsencrypt-manual; shift ;;
      --cert-key=*) SSL_KEY_PATH="${1#*=}"; TLS_MODE=letsencrypt-manual; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      -h|--help)
        echo "用法: sudo ./install.sh [选项]"
        echo "  --health          健康检查"
        echo "  --renew-cert      续签证书"
        echo "  --show-info       查看安装信息"
        echo "  --uninstall       卸载 (可加 --reinstall -y 准备重装; --purge-data --purge-all)"
        echo "  --role=all-in-one|api-standby|db-only"
        echo "  --domain= --email= --dir=  非交互安装 (需配合 -y)"
        echo "  --skip-dns-check  跳过 DNS 与公网 IP 校验"
        echo "  --skip-cert       仅 HTTP（无 Let's Encrypt）"
        echo "  --tls=auto|manual|http  证书模式（manual 需配合 --cert-dir=/path/to/certs）"
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
