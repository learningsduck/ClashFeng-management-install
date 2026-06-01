#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/app.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/app.sh"
# shellcheck source=lib/cleanup.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/cleanup.sh"

NGINX_SITE="/etc/nginx/conf.d/clashfeng.conf"

run_uninstall() {
  need_root
  load_install_info 2>/dev/null || true

  INSTALL_DIR="${INSTALL_DIR:-/opt/clashfeng}"
  COMPOSE_DIR="${COMPOSE_DIR:-${INSTALL_DIR}/compose}"
  APP_DIR="${APP_DIR:-${INSTALL_DIR}/app}"

  # --reinstall / 菜单「准备重装」：默认清空数据库与安装目录（保留证书）
  if [[ "${PREPARE_REINSTALL:-0}" == "1" ]]; then
    PURGE_DATA=1
    PURGE_ALL=1
    REMOVE_NGINX=1
    UNINSTALL_YES=1
    [[ "${KEEP_CERT:-}" != "0" ]] && KEEP_CERT=1
  fi

  echo ""
  echo -e "${YELLOW}══════════════ ClashFeng 卸载 ══════════════${NC}"
  echo "  安装目录: ${INSTALL_DIR}"
  echo "  Compose:  ${COMPOSE_DIR}"
  [[ -n "${DOMAIN:-}" ]] && echo "  域名:     ${DOMAIN}"
  if [[ "${PREPARE_REINSTALL:-0}" == "1" ]]; then
    echo -e "  模式:     ${CYAN}准备重装（清数据库 + 删安装目录）${NC}"
  fi
  echo -e "${YELLOW}══════════════════════════════════════════${NC}"
  echo ""

  if [[ "${UNINSTALL_YES:-0}" != "1" ]]; then
    if [[ "${PURGE_DATA:-0}" == "1" ]]; then
      warn "将删除 MySQL 数据卷（不可恢复）"
    else
      warn "将停止 Docker 容器；${YELLOW}未勾选清数据卷时，重装可能因密码不一致失败${NC}"
    fi
    prompt_yn "确认继续卸载?" "n" || { log "已取消"; return 0; }
  fi

  # --- systemd API ---
  log "停止宿主机 API 服务..."
  stop_host_app_service

  # --- Docker（务必在删目录前执行）---
  if [[ "${PURGE_DATA:-0}" == "1" || "${PREPARE_REINSTALL:-0}" == "1" ]]; then
    compose_down_with_volumes "${COMPOSE_DIR}"
  elif [[ -d "${COMPOSE_DIR}" && -f "${COMPOSE_DIR}/docker-compose.yml" ]]; then
    log "停止并移除 Docker 容器（保留数据卷）..."
    (
      cd "${COMPOSE_DIR}"
      docker compose down --remove-orphans 2>/dev/null || true
    )
    log "已保留 Docker 数据卷；若需彻底重装请加 --purge-data 或选「准备重装」"
  else
    warn "未找到 ${COMPOSE_DIR}/docker-compose.yml，尝试清理残留数据卷..."
    if [[ "${PURGE_DATA:-0}" == "1" ]]; then
      purge_clashfeng_docker_volumes
    fi
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

  # --- Certbot 证书 ---
  if [[ "${REMOVE_CERT:-0}" == "1" && -n "${DOMAIN:-}" ]]; then
    if command -v certbot &>/dev/null; then
      log "删除 Let's Encrypt 证书: ${DOMAIN} ..."
      certbot delete --cert-name "${DOMAIN}" --non-interactive 2>/dev/null || \
        warn "certbot delete 失败，可手动: certbot certificates"
    fi
  elif [[ "${PREPARE_REINSTALL:-0}" == "1" && "${KEEP_CERT:-0}" == "1" && -n "${DOMAIN:-}" ]]; then
    log "保留 Let's Encrypt 证书 (${DOMAIN})，重装后可继续 HTTPS"
  fi

  # --- 安装目录与密钥配置 ---
  if [[ "${PURGE_ALL:-0}" == "1" ]]; then
    if [[ "${UNINSTALL_YES:-0}" != "1" && "${PREPARE_REINSTALL:-0}" != "1" ]]; then
      warn "将删除整个目录 ${INSTALL_DIR}（含 app 源码、install-info、日志）"
      prompt_yn "确认删除安装目录?" "n" || PURGE_ALL=0
    fi
    if [[ "${PURGE_ALL}" == "1" && -d "${INSTALL_DIR}" ]]; then
      log "删除 ${INSTALL_DIR} ..."
      rm -rf "${INSTALL_DIR}"
    fi
  else
    if [[ "${PURGE_DATA:-0}" == "1" ]]; then
      log "删除 install-info 与 .env（避免重装使用旧密码）..."
      remove_stale_install_configs
    fi
    log "保留安装目录 ${INSTALL_DIR}（仅停止服务）"
  fi

  echo ""
  echo -e "${GREEN}卸载完成。${NC}"
  if [[ "${PREPARE_REINSTALL:-0}" == "1" ]]; then
    echo "  重新安装: sudo ./install.sh"
    echo "  或非交互: sudo ./install.sh --role=all-in-one --domain=你的域名 --email=你的邮箱 -y"
  elif [[ "${PURGE_DATA:-0}" != "1" && "${PURGE_ALL:-0}" != "1" ]]; then
    echo "  重新安装: sudo ./install.sh"
    echo -e "  ${YELLOW}彻底重装（推荐）:${NC} sudo ./install.sh --uninstall --reinstall -y && sudo ./install.sh"
  fi
}

uninstall_menu() {
  load_install_info 2>/dev/null || true

  echo ""
  echo "卸载方式:"
  echo "  [1] 卸载并准备重装（推荐）— 清空数据库、删除 /opt/clashfeng，保留 HTTPS 证书"
  echo "  [2] 仅停止服务 — 保留数据库与目录（升级/排查用）"
  echo "  [3] 高级自定义"
  echo "  [0] 返回"
  read -r -p "请选择 [0-3]: " uchoice

  PURGE_DATA=0
  PURGE_ALL=0
  PURGE_IMAGES=0
  REMOVE_NGINX=1
  REMOVE_CERT=0
  PREPARE_REINSTALL=0
  UNINSTALL_YES=0

  case "${uchoice}" in
    1)
      PREPARE_REINSTALL=1
      UNINSTALL_YES=1
      ;;
    2)
      REMOVE_NGINX=1
      if prompt_yn "同时移除 Nginx 站点配置?" "Y"; then
        REMOVE_NGINX=1
      else
        REMOVE_NGINX=0
      fi
      ;;
    3)
      if prompt_yn "删除 MySQL/应用数据卷? (不可恢复)" "n"; then
        PURGE_DATA=1
      fi
      if prompt_yn "删除整个安装目录 /opt/clashfeng?" "n"; then
        PURGE_ALL=1
        PURGE_DATA=1
      fi
      if prompt_yn "删除 Docker 构建镜像?" "n"; then
        PURGE_IMAGES=1
      fi
      if [[ -n "${DOMAIN:-}" ]] && prompt_yn "删除 Let's Encrypt 证书 (${DOMAIN})?" "n"; then
        REMOVE_CERT=1
      fi
      ;;
    0) return 0 ;;
    *) err "无效选项"; uninstall_menu; return ;;
  esac

  run_uninstall
}
