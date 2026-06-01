#!/usr/bin/env bash
# HTTPS / Let's Encrypt 证书配置
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/nginx.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/nginx.sh"

TLS_MODE="${TLS_MODE:-}"          # letsencrypt-auto | letsencrypt-manual | http
SSL_CERT_PATH="${SSL_CERT_PATH:-}"
SSL_KEY_PATH="${SSL_KEY_PATH:-}"

is_ip_address() {
  [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

default_ssl_cert_path() {
  echo "/etc/nginx/ssl/${DOMAIN}/fullchain.pem"
}

default_ssl_key_path() {
  echo "/etc/nginx/ssl/${DOMAIN}/privkey.pem"
}

tls_mode_label() {
  case "${TLS_MODE:-}" in
    letsencrypt-auto) echo "Let's Encrypt 自动申请 + 自动续签" ;;
    letsencrypt-manual) echo "自定义证书路径 + Certbot 自动续签同步" ;;
    http) echo "仅 HTTP（无 TLS）" ;;
    *) echo "未设置" ;;
  esac
}

prompt_tls_email_and_domain() {
  if [[ -z "${DOMAIN:-}" ]]; then
    prompt DOMAIN "域名 (证书与访问同域)" "${DOMAIN:-}"
  fi
  if is_ip_address "${DOMAIN}"; then
    warn "IP 地址无法申请 Let's Encrypt，将使用仅 HTTP"
    TLS_MODE=http
    SKIP_CERT=1
    REQUIRE_HTTPS=false
    return 0
  fi
  prompt ADMIN_EMAIL "Certbot 邮箱 (到期提醒)" "${ADMIN_EMAIL:-}"
  [[ -n "${ADMIN_EMAIL}" ]] || die "申请/续签 Let's Encrypt 必须填写邮箱"
}

prompt_manual_cert_paths() {
  local def_cert def_key
  def_cert="$(default_ssl_cert_path)"
  def_key="$(default_ssl_key_path)"
  prompt SSL_CERT_PATH "证书完整链路径 (fullchain.pem)" "${SSL_CERT_PATH:-$def_cert}"
  prompt SSL_KEY_PATH "私钥路径 (privkey.pem)" "${SSL_KEY_PATH:-$def_key}"
}

validate_cert_files() {
  [[ -f "${SSL_CERT_PATH}" && -f "${SSL_KEY_PATH}" ]] || return 1
  return 0
}

ensure_certbot_webroot() {
  mkdir -p /var/www/certbot
}

install_cert_renew_deploy_hook() {
  local hook="${INSTALL_DIR}/scripts/cert-renew-deploy.sh"
  mkdir_p "${INSTALL_DIR}/scripts"
  render_template "${SCRIPT_DIR}/templates/cert-renew-deploy.sh.tpl" "${hook}"
  chmod 700 "${hook}"
  log "已安装证书续签同步脚本: ${hook}"
}

setup_certbot_auto_renew() {
  local deploy_hook="${1:-systemctl reload nginx}"

  systemctl enable certbot-renew.timer 2>/dev/null || true
  systemctl start certbot-renew.timer 2>/dev/null || true

  local cron_line="0 3 * * * certbot renew --quiet --deploy-hook '${deploy_hook}'"
  if ! crontab -l 2>/dev/null | grep -qF "certbot renew"; then
    (crontab -l 2>/dev/null; echo "${cron_line}") | crontab - 2>/dev/null || true
  fi
}

sync_le_certs_to_manual_paths() {
  local le_dir="/etc/letsencrypt/live/${DOMAIN}"
  [[ -f "${le_dir}/fullchain.pem" && -f "${le_dir}/privkey.pem" ]] \
    || die "未找到 Let's Encrypt 证书目录: ${le_dir}"

  mkdir -p "$(dirname "${SSL_CERT_PATH}")" "$(dirname "${SSL_KEY_PATH}")"
  install -m 0644 "${le_dir}/fullchain.pem" "${SSL_CERT_PATH}"
  install -m 0600 "${le_dir}/privkey.pem" "${SSL_KEY_PATH}"
  log "证书已同步到: ${SSL_CERT_PATH}"
}

obtain_le_certificate() {
  local staging_arg=()
  if [[ "${CERTBOT_STAGING:-0}" == "1" ]]; then
    staging_arg=(--staging)
  fi

  log "向 Let's Encrypt 申请证书 (${DOMAIN})..."
  if certbot certonly --nginx -d "${DOMAIN}" --email "${ADMIN_EMAIL}" \
    --agree-tos --non-interactive "${staging_arg[@]}"; then
    return 0
  fi
  warn "certonly --nginx 失败，尝试 webroot 方式..."
  ensure_certbot_webroot
  certbot certonly --webroot -w /var/www/certbot -d "${DOMAIN}" \
    --email "${ADMIN_EMAIL}" --agree-tos --non-interactive "${staging_arg[@]}"
}

install_nginx_https_site() {
  log "配置 Nginx HTTPS（自定义证书路径）..."
  render_template "${SCRIPT_DIR}/templates/nginx-https.conf.tpl" "/etc/nginx/conf.d/clashfeng.conf"
  nginx -t
  systemctl reload nginx
}

# --- 模式 1：Certbot 自动配置 Nginx + 自动续签 ---
apply_tls_letsencrypt_auto() {
  REQUIRE_HTTPS=true
  SKIP_CERT=0
  check_dns || true

  install_nginx_site
  log "Certbot 自动配置 Nginx 与证书..."
  local staging_arg=()
  if [[ "${CERTBOT_STAGING:-0}" == "1" ]]; then
    staging_arg=(--staging)
  fi

  if ! certbot --nginx -d "${DOMAIN}" --email "${ADMIN_EMAIL}" \
    --agree-tos --non-interactive "${staging_arg[@]}"; then
    warn "Certbot 失败。请确认 80 端口可从公网访问且 DNS 已生效后执行:"
    warn "  certbot --nginx -d ${DOMAIN} --email ${ADMIN_EMAIL}"
    return 1
  fi

  setup_certbot_auto_renew "systemctl reload nginx"
  log "HTTPS 已启用（Let's Encrypt 自动续签）"
}

# --- 模式 2：用户指定证书路径，Certbot 续签后同步 ---
apply_tls_letsencrypt_manual_paths() {
  REQUIRE_HTTPS=true
  SKIP_CERT=0
  [[ -n "${SSL_CERT_PATH}" && -n "${SSL_KEY_PATH}" ]] || prompt_manual_cert_paths
  check_dns || true

  install_nginx_site
  if ! validate_cert_files; then
    obtain_le_certificate
    sync_le_certs_to_manual_paths
  else
    log "使用已有证书文件: ${SSL_CERT_PATH}"
    # 仍尝试续签/更新 LE 账户（已有证书可能是手动放置的）
    if [[ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
      obtain_le_certificate || warn "Let's Encrypt 首次申请失败，继续使用现有证书文件"
      sync_le_certs_to_manual_paths 2>/dev/null || true
    fi
  fi

  install_nginx_https_site
  install_cert_renew_deploy_hook
  setup_certbot_auto_renew "${INSTALL_DIR}/scripts/cert-renew-deploy.sh"
  log "HTTPS 已启用（续签后自动同步到自定义路径）"
}

apply_tls_http_only() {
  TLS_MODE=http
  SKIP_CERT=1
  if [[ -z "${REQUIRE_HTTPS:-}" ]]; then
    REQUIRE_HTTPS=false
  fi
  install_nginx_site
  warn "仅 HTTP: http://${DOMAIN}/"
}

apply_tls_configuration() {
  if [[ "${SKIP_CERT:-0}" == "1" || "${TLS_MODE:-}" == "http" ]]; then
    apply_tls_http_only
    return 0
  fi

  [[ -n "${DOMAIN:-}" ]] || die "缺少域名，无法配置 HTTPS"
  prompt_tls_email_and_domain

  case "${TLS_MODE:-letsencrypt-auto}" in
    letsencrypt-auto) apply_tls_letsencrypt_auto ;;
    letsencrypt-manual) apply_tls_letsencrypt_manual_paths ;;
    http) apply_tls_http_only ;;
    *)
      warn "未知 TLS_MODE=${TLS_MODE}，使用自动模式"
      TLS_MODE=letsencrypt-auto
      apply_tls_letsencrypt_auto
      ;;
  esac
}

tls_renew_now() {
  load_install_info
  need_root
  case "${TLS_MODE:-letsencrypt-auto}" in
    letsencrypt-manual)
      local hook="${INSTALL_DIR}/scripts/cert-renew-deploy.sh"
      if [[ -x "${hook}" ]]; then
        certbot renew --deploy-hook "${hook}"
      else
        certbot renew --deploy-hook "systemctl reload nginx"
      fi
      ;;
    *)
      certbot renew --quiet --deploy-hook 'systemctl reload nginx'
      ;;
  esac
  log "证书续签检查完成"
}

# 主菜单：HTTPS / TLS 证书
tls_main_menu() {
  load_install_info 2>/dev/null || true

  echo ""
  echo -e "${CYAN}════════════ HTTPS / TLS 证书 ════════════${NC}"
  echo "  当前模式: $(tls_mode_label)"
  [[ -n "${DOMAIN:-}" ]] && echo "  域名:     ${DOMAIN}"
  [[ -n "${SSL_CERT_PATH:-}" ]] && echo "  证书:     ${SSL_CERT_PATH}"
  echo ""
  echo "  [1] 自动申请 Let's Encrypt（Certbot 自动配置 Nginx + 自动续签）"
  echo "  [2] 手动指定证书路径（Certbot 续签后自动同步到该路径）"
  echo "  [3] 仅 HTTP / 跳过 HTTPS"
  echo "  [4] 立即应用当前证书配置（已安装服务时）"
  echo "  [5] 手动触发证书续签检查"
  echo "  [0] 返回主菜单"
  echo ""
  read -r -p "请选择 [0-5]: " tchoice

  case "${tchoice}" in
    1)
      TLS_MODE=letsencrypt-auto
      prompt_tls_email_and_domain
      save_install_info
      log "已保存: $(tls_mode_label)"
      ;;
    2)
      TLS_MODE=letsencrypt-manual
      prompt_tls_email_and_domain
      prompt_manual_cert_paths
      save_install_info
      log "已保存: $(tls_mode_label)"
      ;;
    3)
      TLS_MODE=http
      SKIP_CERT=1
      REQUIRE_HTTPS=false
      prompt DOMAIN "域名或 IP" "${DOMAIN:-}"
      save_install_info
      log "已保存: $(tls_mode_label)"
      ;;
    4)
      [[ -f "${INSTALL_INFO}" ]] || die "请先完成安装或先选 [1]/[2] 保存配置"
      load_install_info
      install_nginx_certbot
      apply_tls_configuration
      save_install_info
      health_check || true
      ;;
    5)
      tls_renew_now
      ;;
    0) return 0 ;;
    *) err "无效选项"; tls_main_menu; return ;;
  esac
}

# 安装流程中：选择 TLS（若主菜单 [4] 未预设）
prompt_tls_settings() {
  if [[ -n "${TLS_MODE:-}" ]]; then
    log "证书模式: $(tls_mode_label)"
    return 0
  fi

  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    TLS_MODE="${TLS_MODE:-letsencrypt-auto}"
    [[ "${TLS_MODE}" != "http" ]] || { SKIP_CERT=1; REQUIRE_HTTPS=false; }
    log "已选: $(tls_mode_label)"
    return 0
  fi

  echo ""
  echo "HTTPS / TLS 证书:"
  echo "  [1] 自动申请 Let's Encrypt（推荐）"
  echo "  [2] 手动指定证书公钥/私钥路径（续签后自动同步）"
  echo "  [3] 仅 HTTP / 跳过 HTTPS"
  read -r -p "请选择 [1-3] [1]: " tsel
  tsel="${tsel:-1}"
  case "${tsel}" in
    1) TLS_MODE=letsencrypt-auto ;;
    2) TLS_MODE=letsencrypt-manual ;;
    3) TLS_MODE=http; SKIP_CERT=1; REQUIRE_HTTPS=false ;;
    *) die "无效选项" ;;
  esac
  log "已选: $(tls_mode_label)"
}
