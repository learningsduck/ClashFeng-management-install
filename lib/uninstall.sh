#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/app.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/app.sh"

NGINX_SITE="/etc/nginx/conf.d/clashfeng.conf"

run_uninstall() {
  need_root
  load_install_info

  INSTALL_DIR="${INSTALL_DIR:-/opt/clashfeng}"
  COMPOSE_DIR="${COMPOSE_DIR:-${INSTALL_DIR}/compose}"

  echo ""
  echo -e "${YELLOW}══════════════ ClashFeng 卸载 ══════════════${NC}"
  echo "  安装目录: ${INSTALL_DIR}"
  echo "  Compose:  ${COMPOSE_DIR}"
  [[ -n "${DOMAIN:-}" ]] && echo "  域名:     ${DOMAIN}"
  echo -e "${YELLOW}══════════════════════════════════════════${NC}"
  echo ""

  if [[ "${UNINSTALL_YES:-0}" != "1" ]]; then
    warn "将停止 Docker 容器并移除 Nginx 站点配置"
    prompt_yn "确认继续卸载?" "n" || { log "已取消"; return 0; }
  fi

  # --- systemd API ---
  log "停止宿主机 API 服务..."
  stop_host_app_service

  # --- Docker ---
  if [[ -d "${COMPOSE_DIR}" && -f "${COMPOSE_DIR}/docker-compose.yml" ]]; then
    log "停止并移除 Docker 容器..."
    cd "${COMPOSE_DIR}"
    if [[ "${PURGE_DATA:-0}" == "1" ]]; then
      warn "将删除 MySQL / 应用数据卷（不可恢复）"
      docker compose down -v --remove-orphans 2>/dev/null || docker compose down --remove-orphans 2>/dev/null || true
    else
      docker compose down --remove-orphans 2>/dev/null || true
      log "已保留 Docker 数据卷，重装后可恢复数据库"
    fi
  else
    warn "未找到 ${COMPOSE_DIR}/docker-compose.yml，跳过 compose down"
  fi

  # --- 删除本机构建的镜像 ---
  if [[ "${PURGE_IMAGES:-0}" == "1" ]]; then
    log "删除 ClashFeng 相关 Docker 镜像..."
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -iE 'clashfeng|compose-app' | while read -r img; do
      docker rmi -f "${img}" 2>/dev/null || true
    done
    docker image prune -f 2>/dev/null || true
  fi

  # --- Nginx ---
  if [[ "${REMOVE_NGINX:-1}" == "1" ]]; then
    if [[ -f "${NGINX_SITE}" ]]; then
      log "移除 Nginx 配置 ${NGINX_SITE} ..."
      rm -f "${NGINX_SITE}"
      if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || true
      else
        warn "Nginx 配置检测失败，请手动检查 /etc/nginx"
      fi
    fi
  fi

  # --- Certbot 证书（可选）---
  if [[ "${REMOVE_CERT:-0}" == "1" && -n "${DOMAIN:-}" ]]; then
    if command -v certbot &>/dev/null; then
      log "删除 Let's Encrypt 证书: ${DOMAIN} ..."
      certbot delete --cert-name "${DOMAIN}" --non-interactive 2>/dev/null || \
        warn "certbot delete 失败，可手动: certbot certificates"
    fi
  fi

  # --- 安装目录 ---
  if [[ "${PURGE_ALL:-0}" == "1" ]]; then
    if [[ "${UNINSTALL_YES:-0}" != "1" ]]; then
      warn "将删除整个目录 ${INSTALL_DIR}（含 app 源码、install-info、日志）"
      prompt_yn "确认删除安装目录?" "n" || PURGE_ALL=0
    fi
    if [[ "${PURGE_ALL}" == "1" && -d "${INSTALL_DIR}" ]]; then
      log "删除 ${INSTALL_DIR} ..."
      rm -rf "${INSTALL_DIR}"
    fi
  else
    log "保留安装目录 ${INSTALL_DIR}（仅停止服务）"
  fi

  echo ""
  echo -e "${GREEN}卸载完成。${NC}"
  if [[ "${PURGE_DATA:-0}" != "1" && "${PURGE_ALL:-0}" != "1" ]]; then
    echo "  重新安装: sudo ./install.sh"
    echo "  彻底重装并清空数据库: sudo ./install.sh --uninstall --purge-data -y && sudo ./install.sh"
  fi
}

uninstall_menu() {
  load_install_info 2>/dev/null || true
  PURGE_DATA=0
  PURGE_ALL=0
  PURGE_IMAGES=0
  REMOVE_NGINX=1
  REMOVE_CERT=0

  echo ""
  echo "卸载选项（回车默认）:"
  if prompt_yn "删除 MySQL/应用数据卷? (不可恢复)" "n"; then
    PURGE_DATA=1
  fi
  if prompt_yn "删除整个安装目录 /opt/clashfeng?" "n"; then
    PURGE_ALL=1
  fi
  if prompt_yn "删除 Docker 构建镜像?" "n"; then
    PURGE_IMAGES=1
  fi
  if [[ -n "${DOMAIN:-}" ]] && prompt_yn "删除 Let's Encrypt 证书 (${DOMAIN})?" "n"; then
    REMOVE_CERT=1
  fi

  run_uninstall
}
