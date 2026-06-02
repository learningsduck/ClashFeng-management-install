#!/usr/bin/env bash
# 管理员账户管理（调用 ClashFeng-auth admin-cli）
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

ensure_app_built_for_admin_cli() {
  APP_DIR="${APP_DIR:-/opt/clashfeng/app}"
  [[ -d "${APP_DIR}" ]] || die "未找到 ${APP_DIR}，请先完成主站安装"
  export PATH="/usr/bin:/usr/local/bin:${PATH}"
  if [[ ! -f "${APP_DIR}/dist/db/index.js" ]]; then
    log "编译 auth（admin-cli）..."
    (cd "${APP_DIR}" && NODE_ENV=development npm ci >/dev/null 2>&1 && npm run build >/dev/null 2>&1)
  fi
}

run_admin_cli() {
  ensure_app_built_for_admin_cli
  (
    cd "${APP_DIR}"
    set -a
    # shellcheck source=/dev/null
    source "${APP_DIR}/.env"
    set +a
    /usr/bin/node scripts/admin-cli.mjs "$@"
  )
}

admin_panel_uses_https() {
  if [[ "${TLS_MODE:-}" == "http" || "${SKIP_CERT:-0}" == "1" ]]; then
    return 1
  fi
  ss -tlnp 2>/dev/null | grep -qE ':443[^0-9].*nginx|:443\s'
}

admin_panel_scheme() {
  if admin_panel_uses_https; then
    echo "https"
  else
    echo "http"
  fi
}

show_admin_panel_url() {
  load_install_info 2>/dev/null || true
  INSTALL_INFO="${INSTALL_INFO:-/opt/clashfeng/install-info.env}"

  if [[ -z "${ADMIN_PANEL_PATH:-}" ]]; then
    if [[ -f "${INSTALL_INFO}" ]]; then
      warn "install-info 中未找到 ADMIN_PANEL_PATH，请确认是否已完成主站安装"
    else
      warn "未找到 ${INSTALL_INFO}，请先完成主站安装"
    fi
    return 1
  fi

  local scheme
  scheme="$(admin_panel_scheme)"

  echo -e "  ${CYAN}管理后台入口（请妥善保存，勿公开）:${NC}"
  if [[ -n "${DOMAIN:-}" && "${DOMAIN}" != "db-local" && "${DOMAIN}" != "_" ]]; then
    echo "    ${scheme}://${DOMAIN}${ADMIN_PANEL_PATH}"
  elif [[ "${TLS_MODE:-}" == "deferred" || -z "${DOMAIN:-}" ]]; then
    echo "    http://127.0.0.1:${APP_PORT:-3001}${ADMIN_PANEL_PATH}"
    echo "    （配置域名与 HTTPS 后请用主菜单 [8] 或 [4] 查看公网地址）"
  else
    echo "    ${scheme}://${DOMAIN}${ADMIN_PANEL_PATH}"
  fi
  echo "    隐藏路径: ${ADMIN_PANEL_PATH}"
  return 0
}

show_admin_panel_entry() {
  need_root
  load_install_info 2>/dev/null || true
  INSTALL_INFO="${INSTALL_INFO:-/opt/clashfeng/install-info.env}"

  echo ""
  echo -e "${CYAN}════════════ 管理后台入口查询 ════════════${NC}"
  if [[ ! -f "${INSTALL_INFO}" ]]; then
    warn "未找到 ${INSTALL_INFO}"
    echo "  请先完成主站安装（主菜单 [1]）"
    return 1
  fi

  [[ -n "${DOMAIN:-}" && "${DOMAIN}" != "_" ]] && echo "  域名:     ${DOMAIN}"
  echo "  配置:     ${INSTALL_INFO}"
  echo ""
  show_admin_panel_url || true
  echo ""
  echo "  公网首页 ${DOMAIN:-}/ 仅为中性门户，不含管理功能"
  return 0
}

admin_management_menu() {
  need_root
  load_install_info 2>/dev/null || true
  APP_DIR="${APP_DIR:-/opt/clashfeng/app}"

  echo ""
  echo -e "${CYAN}════════════ 管理员账户管理 ════════════${NC}"
  show_admin_panel_url
  echo ""
  echo "  [1] 查看管理员列表"
  echo "  [2] 创建管理员"
  echo "  [3] 删除管理员"
  echo "  [4] 重置管理员密码"
  echo "  [5] 显示管理后台入口地址"
  echo "  [0] 返回"
  read -r -p "请选择 [0-5]: " achoice

  case "${achoice}" in
    1) run_admin_cli list ;;
    2)
      read -r -p "用户名: " uname
      run_admin_cli create --username "${uname}"
      ;;
    3)
      read -r -p "要删除的用户名: " uname
      run_admin_cli delete --username "${uname}"
      ;;
    4)
      read -r -p "用户名: " uname
      run_admin_cli reset-password --username "${uname}"
      ;;
    5) show_admin_panel_url ;;
    0) return 0 ;;
    *) err "无效选项"; admin_management_menu; return ;;
  esac
  echo ""
  read -r -p "按回车继续..." _
  admin_management_menu
}
