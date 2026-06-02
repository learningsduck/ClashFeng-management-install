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
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/standby.sh"

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
  echo "  [8] 查询管理后台入口"
  echo "  [9] 容灾与主库连接"
  echo "  [0] 退出"
  echo ""
  read -r -p "请输入选项 [0-9]: " choice
  case "${choice}" in
    1) INSTALL_ROLE=all-in-one; run_all_in_one ;;
    2) INSTALL_ROLE=api-standby; run_api_standby ;;
    3) INSTALL_ROLE=db-only; run_db_only ;;
    4) tls_main_menu; main_menu ;;
    5) admin_management_menu; main_menu ;;
    6) maintenance_menu ;;
    7) uninstall_menu; main_menu ;;
    8) show_admin_panel_entry; main_menu ;;
    9) standby_main_menu; main_menu ;;
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
  echo "  [f] 查询管理后台入口"
  echo "  [g] 容灾与主库连接"
  echo "  [0] 返回"
  read -r -p "请选择: " m
  case "${m}" in
    a) health_check || true; main_menu ;;
    b) renew_cert; main_menu ;;
    c) show_install_info; main_menu ;;
    d) admin_management_menu; main_menu ;;
    e) uninstall_menu; main_menu ;;
    f) show_admin_panel_entry; main_menu ;;
    g) standby_main_menu; main_menu ;;
    0) main_menu ;;
    *) maintenance_menu ;;
  esac
}

prompt_domain_cert() {
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    if [[ "${TLS_MODE:-}" == "deferred" ]]; then
      DOMAIN="${DOMAIN:-}"
      SKIP_CERT=1
      REQUIRE_HTTPS=false
      SKIP_DNS_CHECK=1
      log "访问地址: 稍后配置（--tls=deferred）"
      return 0
    fi
    prompt DOMAIN "域名 (管理后台与 API 同域)" "${DOMAIN:-}"
    if is_ip_address "${DOMAIN}"; then
      warn "使用 IP 作为访问地址，将跳过 Let's Encrypt（仅 HTTP）"
      TLS_MODE=http
      SKIP_CERT=1
      REQUIRE_HTTPS=false
    fi
    if [[ "${SKIP_DNS_CHECK:-0}" != "1" ]]; then
      SKIP_DNS_CHECK=0
    fi
    return 0
  fi

  echo ""
  echo "访问地址 / 域名（管理后台与 API 同域）:"
  echo "  [1] 填写域名（用于 HTTP/HTTPS 与证书）"
  echo "  [2] 填写 IP 地址（仅 HTTP，无法自动申请证书）"
  echo "  [3] 稍后配置（先完成安装，稍后在主菜单 [4] 设置域名与证书目录）"
  read -r -p "请选择 [1-3] [1]: " dsel
  dsel="${dsel:-1}"
  case "${dsel}" in
    1)
      prompt DOMAIN "域名" "${DOMAIN:-}"
      if is_ip_address "${DOMAIN}"; then
        TLS_MODE=http
        SKIP_CERT=1
        REQUIRE_HTTPS=false
      fi
      ;;
    2)
      prompt DOMAIN "IP 地址" "${DOMAIN:-}"
      is_ip_address "${DOMAIN}" || die "请填写有效 IPv4 地址"
      TLS_MODE=http
      SKIP_CERT=1
      REQUIRE_HTTPS=false
      ;;
    3)
      DOMAIN=""
      TLS_MODE=deferred
      SKIP_CERT=1
      REQUIRE_HTTPS=false
      SKIP_DNS_CHECK=1
      log "已选: 稍后配置域名与 HTTPS/证书（安装后使用主菜单 [4]）"
      return 0
      ;;
    *) die "无效选项" ;;
  esac

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
  if is_tls_deferred 2>/dev/null || [[ "${TLS_MODE:-}" == "deferred" ]]; then
    echo "  访问地址: （稍后配置）安装后主菜单 [4] 设置域名与证书"
  elif [[ "${TLS_MODE:-}" == "http" || "${SKIP_CERT:-0}" == "1" ]]; then
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
  if [[ "${INSTALL_ROLE}" == "all-in-one" || "${INSTALL_ROLE}" == "db-only" ]]; then
    MASTER_PUBLIC_IP="${MASTER_PUBLIC_IP:-$(public_ip)}"
  fi
  save_install_info
  echo ""
  echo -e "${GREEN}════════════════ 安装完成 ════════════════${NC}"
  if [[ "${TLS_MODE:-}" == "deferred" ]]; then
    echo "  API 已运行: http://127.0.0.1:${APP_PORT:-3001}/auth/captcha"
    echo "  域名/HTTPS: 尚未配置。请运行本脚本主菜单 [4] → [6] 设置域名 → [1]/[2] 选证书方式 → [4] 应用"
    echo "  （应用证书仅重载 Nginx，不影响 MySQL 与 API 服务）"
  elif [[ "${TLS_MODE:-}" == "http" ]]; then
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
  if [[ "${TLS_MODE:-}" != "deferred" && -n "${DOMAIN:-}" ]]; then
  echo "  公网首页为中性门户页，管理功能仅在隐藏路径 ${ADMIN_PANEL_PATH:-} 提供"
  fi
  echo ""
  if [[ "${INSTALL_ROLE}" == "all-in-one" ]]; then
    echo "  容灾备用: 主库先 [9]→[2] 放行备用 IP，备用 VPS 选 [2] 安装 API"
    echo "  客户端 endpoints: 主菜单 [9]→[4] 导出"
  fi
  if [[ "${INSTALL_ROLE}" == "api-standby" ]]; then
    echo "  容灾: 主菜单 [9]→[4] 导出客户端 endpoints.json"
    export_client_endpoints 2>/dev/null || echo "  （配置 HTTPS/域名后执行 [9]→[4] 导出）"
  fi
  echo -e "${GREEN}════════════════════════════════════════${NC}"
  health_check || true
}

run_all_in_one() {
  prompt_domain_cert
  if [[ "${TLS_MODE:-}" != "deferred" ]]; then
    prompt_tls_settings
  fi
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
  if [[ "${TLS_MODE:-}" == "deferred" ]]; then
    apply_tls_deferred_bootstrap
  else
    if apply_tls_configuration; then
      sync_require_https_to_app
    else
      warn "HTTPS 配置未完全成功，可稍后在主菜单 [4] 重试"
    fi
  fi
  warn_app_port_not_public

  show_done
}

run_api_standby() {
  echo ""
  echo -e "${YELLOW}备用节点: JWT_SECRET 必须与主站完全相同${NC}"
  print_standby_prerequisites
  if ! prompt_yn "已在主库 VPS 执行 [9]→[2] 放行本机 IP $(public_ip) ?" "Y"; then
    warn "请先在主库完成白名单后再继续"
    standby_main_menu
    return 0
  fi
  prompt_domain_cert
  if [[ "${TLS_MODE:-}" != "deferred" ]]; then
    prompt_tls_settings
  fi
  prompt INSTALL_DIR "安装根目录" "${INSTALL_DIR}"
  COMPOSE_DIR="${INSTALL_DIR}/compose"
  APP_DIR="${INSTALL_DIR}/app"
  local master_hint
  master_hint="主库公网 IP（install-info 中 MASTER_PUBLIC_IP）"
  prompt MYSQL_HOST "主库地址 (${master_hint})" ""
  prompt MYSQL_PORT "主库端口" "3306"
  MYSQL_DATABASE="${MYSQL_DATABASE}"
  MYSQL_USER="${MYSQL_USER}"
  prompt MYSQL_PASSWORD "主库用户密码 (与主站 clashwin 用户一致)" ""

  log "安装前测试主库连接..."
  if ! test_remote_mysql_connection "${MYSQL_HOST}" "${MYSQL_PORT}" "${MYSQL_USER}" "${MYSQL_PASSWORD}" "${MYSQL_DATABASE}"; then
    print_standby_troubleshooting
    die "请先修复主库连接后再安装备用节点"
  fi
  prompt JWT_SECRET "JWT_SECRET (从主站 install-info 复制)" ""
  prompt ADMIN_INIT_SECRET "ADMIN_INIT_SECRET (与主站一致)" ""
  prompt ADMIN_IP_WHITELIST "管理后台 IP 白名单 (可选)" "${ADMIN_IP_WHITELIST:-}"
  if [[ "${TLS_MODE:-}" == "deferred" || "${SKIP_CERT:-0}" == "1" || "${TLS_MODE:-}" == "http" ]]; then
    REQUIRE_HTTPS=false
  elif [[ "${ASSUME_YES:-0}" == "1" ]]; then
    REQUIRE_HTTPS=true
  elif prompt_yn "生产环境强制 HTTPS (REQUIRE_HTTPS)?" "Y"; then
    REQUIRE_HTTPS=true
  else
    REQUIRE_HTTPS=false
  fi
  confirm_install

  mkdir_p "${INSTALL_DIR}" "${COMPOSE_DIR}" "${APP_DIR}"
  install_base_packages
  check_env
  install_docker
  open_firewall_http
  clone_auth_repo
  write_app_env

  if ! test_remote_mysql_connection; then
    print_standby_troubleshooting
    die "无法连接主库"
  fi

  build_app
  start_host_app_service

  install_nginx_certbot
  if [[ "${TLS_MODE:-}" == "deferred" ]]; then
    apply_tls_deferred_bootstrap
  else
    if apply_tls_configuration; then
      sync_require_https_to_app
    else
      warn "HTTPS 配置未完全成功，可稍后在主菜单 [4] 重试"
    fi
  fi
  warn_app_port_not_public

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
  read -r -p "允许访问 3306 的备用 VPS IP (可选): " standby_ip
  if [[ -n "${standby_ip:-}" ]]; then
    MYSQL_BIND="0.0.0.0:3306:3306"
    log "已选远程主库模式: 绑定 ${MYSQL_BIND}，仅放行 ${standby_ip}"
  else
    prompt MYSQL_BIND "端口映射" "127.0.0.1:3306:3306"
  fi
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

  MASTER_PUBLIC_IP="$(public_ip)"
  if [[ -n "${standby_ip:-}" ]]; then
    grant_mysql_user_from_host "${standby_ip}"
    allow_mysql_from_ip "${standby_ip}"
    ALLOWED_STANDBY_IPS="${standby_ip}"
    print_cloud_security_group_hint "${standby_ip}"
  fi

  DOMAIN="${DOMAIN:-db-local}"
  save_install_info
  log "数据库主库已启动。"
  echo "  备用 API 节点 MYSQL_HOST=${MASTER_PUBLIC_IP}（公网 IP）"
  echo "  密钥见: ${INSTALL_INFO}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --health) health_check; exit $? ;;
      --renew-cert) need_root; renew_cert; exit 0 ;;
      --show-info) show_install_info; exit 0 ;;
      --show-admin-url) need_root; show_admin_panel_entry; exit 0 ;;
      --show-topology) need_root; show_topology; exit 0 ;;
      --test-mysql) need_root; load_install_info; test_remote_mysql_connection || exit 1; exit 0 ;;
      --export-endpoints) need_root; export_client_endpoints; exit 0 ;;
      --prepare-standby-ip=*)
        need_root
        load_install_info
        prepare_master_allow_standby_ip "${1#*=}"
        exit 0
        ;;
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
      --defer-tls|--defer-cert) TLS_MODE=deferred; SKIP_CERT=1; REQUIRE_HTTPS=false; shift ;;
      --tls=*)
        TLS_MODE="${1#*=}"
        case "${TLS_MODE}" in
          auto) TLS_MODE=letsencrypt-auto ;;
          manual) TLS_MODE=letsencrypt-manual ;;
          deferred) SKIP_CERT=1; REQUIRE_HTTPS=false ;;
          http) SKIP_CERT=1; REQUIRE_HTTPS=false ;;
        esac
        shift
        ;;
      --cert-dir=*) SSL_CERT_DIR="${1#*=}"; TLS_MODE=letsencrypt-manual; shift ;;
      --cert-fullchain=*) SSL_CERT_DIR="$(dirname "${1#*=}")"; SSL_CERT_PATH="${1#*=}"; TLS_MODE=letsencrypt-manual; shift ;;
      --cert-key=*) SSL_KEY_PATH="${1#*=}"; TLS_MODE=letsencrypt-manual; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      -h|--help)
        echo "用法: sudo ./install.sh [选项]"
        echo "  --health          健康检查"
        echo "  --renew-cert      续签证书"
        echo "  --show-info       查看安装信息"
        echo "  --show-admin-url  查询管理后台入口地址"
        echo "  --show-topology   查看安装拓扑"
        echo "  --test-mysql      测试主库 MySQL 连接"
        echo "  --export-endpoints  导出客户端 endpoints.json"
        echo "  --prepare-standby-ip=IP  [主库] 允许该 IP 访问 MySQL"
        echo "  --uninstall       卸载 (可加 --reinstall -y 准备重装; --purge-data --purge-all)"
        echo "  --role=all-in-one|api-standby|db-only"
        echo "  --domain= --email= --dir=  非交互安装 (需配合 -y)"
        echo "  --skip-dns-check  跳过 DNS 与公网 IP 校验"
        echo "  --skip-cert       仅 HTTP（无 Let's Encrypt）"
        echo "  --defer-tls       暂不配置域名与证书（安装后菜单 [4] 配置）"
        echo "  --tls=auto|manual|http|deferred  证书模式（manual 需 --cert-dir=）"
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
