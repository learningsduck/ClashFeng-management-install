#!/usr/bin/env bash
# HTTPS / Let's Encrypt 证书配置
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=lib/nginx.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/nginx.sh"

TLS_MODE="${TLS_MODE:-}"          # letsencrypt-auto | letsencrypt-manual | http
SSL_CERT_DIR="${SSL_CERT_DIR:-}"  # 手动模式：证书目录（操作者自备文件）
SSL_CERT_PATH="${SSL_CERT_PATH:-}"
SSL_KEY_PATH="${SSL_KEY_PATH:-}"

is_ip_address() {
  [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

default_ssl_cert_dir() {
  echo "/etc/nginx/ssl/${DOMAIN}"
}

ssl_cert_dir_help() {
  cat <<'EOF'
  请在所选目录中自行放置证书文件（文件名需一致）：
    fullchain.pem  — 站点证书 + 中间证书（推荐）
      或 cert.pem  — 仅站点证书（无中间链时）
    privkey.pem    — 私钥（必填）
  也可直接使用 Certbot 目录，例如：
    /etc/letsencrypt/live/你的域名/
EOF
}

# 根据目录解析 Nginx 使用的证书/私钥路径（写入 SSL_CERT_PATH / SSL_KEY_PATH）
resolve_ssl_paths_from_dir() {
  local dir="${SSL_CERT_DIR:-}"
  dir="${dir%/}"
  [[ -n "${dir}" && -d "${dir}" ]] || return 1

  SSL_CERT_DIR="${dir}"
  SSL_CERT_PATH=""
  SSL_KEY_PATH=""

  local f
  for f in privkey.pem private.key key.pem; do
    if [[ -f "${dir}/${f}" ]]; then
      SSL_KEY_PATH="${dir}/${f}"
      break
    fi
  done

  for f in fullchain.pem cert.pem certificate.pem; do
    if [[ -f "${dir}/${f}" ]]; then
      SSL_CERT_PATH="${dir}/${f}"
      break
    fi
  done

  [[ -n "${SSL_CERT_PATH}" && -n "${SSL_KEY_PATH}" ]]
}

validate_cert_dir() {
  if resolve_ssl_paths_from_dir; then
    log "证书目录: ${SSL_CERT_DIR}"
    log "  证书: ${SSL_CERT_PATH}"
    log "  私钥: ${SSL_KEY_PATH}"
    return 0
  fi
  return 1
}

is_le_live_cert_dir() {
  local dir le
  dir="$(readlink -f "${SSL_CERT_DIR}" 2>/dev/null || echo "${SSL_CERT_DIR}")"
  le="$(readlink -f "/etc/letsencrypt/live/${DOMAIN}" 2>/dev/null || true)"
  [[ -n "${le}" && "${dir}" == "${le}" ]]
}

tls_mode_label() {
  case "${TLS_MODE:-}" in
    letsencrypt-auto) echo "Let's Encrypt 自动申请 + 自动续签" ;;
    letsencrypt-manual) echo "自定义证书目录（自备证书文件）" ;;
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
  if [[ "${TLS_MODE:-}" == "letsencrypt-auto" ]]; then
    prompt ADMIN_EMAIL "Certbot 邮箱 (到期提醒)" "${ADMIN_EMAIL:-}"
    [[ -n "${ADMIN_EMAIL}" ]] || die "申请/续签 Let's Encrypt 必须填写邮箱"
  fi
}

prompt_manual_cert_dir() {
  echo ""
  ssl_cert_dir_help
  echo ""
  local def_dir
  def_dir="$(default_ssl_cert_dir)"
  if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    def_dir="/etc/letsencrypt/live/${DOMAIN}"
  fi
  prompt SSL_CERT_DIR "证书目录（请提前放好 fullchain.pem 与 privkey.pem）" "${SSL_CERT_DIR:-$def_dir}"

  if ! validate_cert_dir; then
    die "目录 ${SSL_CERT_DIR} 中未找到有效证书文件，请按上方说明放置 fullchain.pem（或 cert.pem）和 privkey.pem"
  fi
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

sync_le_certs_to_dir() {
  local le_dir="/etc/letsencrypt/live/${DOMAIN}"
  [[ -f "${le_dir}/fullchain.pem" && -f "${le_dir}/privkey.pem" ]] \
    || die "未找到 Let's Encrypt 证书目录: ${le_dir}"

  mkdir -p "${SSL_CERT_DIR}"
  install -m 0644 "${le_dir}/fullchain.pem" "${SSL_CERT_DIR}/fullchain.pem"
  install -m 0600 "${le_dir}/privkey.pem" "${SSL_CERT_DIR}/privkey.pem"
  SSL_CERT_PATH="${SSL_CERT_DIR}/fullchain.pem"
  SSL_KEY_PATH="${SSL_CERT_DIR}/privkey.pem"
  log "Let's Encrypt 证书已同步到目录: ${SSL_CERT_DIR}"
}

obtain_le_certificate() {
  [[ -n "${ADMIN_EMAIL:-}" ]] || die "手动目录模式若需自动申请证书，请先配置 ADMIN_EMAIL"
  local staging_arg=()
  if [[ "${CERTBOT_STAGING:-0}" == "1" ]]; then
    staging_arg=(--staging)
  fi

  log "向 Let's Encrypt 申请证书 (${DOMAIN})..."
  install_nginx_site
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
  resolve_ssl_paths_from_dir || die "无法解析证书目录 ${SSL_CERT_DIR}"
  log "配置 Nginx HTTPS..."
  render_template "${SCRIPT_DIR}/templates/nginx-https.conf.tpl" "/etc/nginx/conf.d/clashfeng.conf"
  nginx -t
  systemctl reload nginx
}

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
  log "HTTPS 已启用（Let's Encrypt 自动续签，证书在 /etc/letsencrypt/live/${DOMAIN}/）"
}

apply_tls_letsencrypt_manual_dir() {
  REQUIRE_HTTPS=true
  SKIP_CERT=0
  [[ -n "${SSL_CERT_DIR}" ]] || prompt_manual_cert_dir

  if ! validate_cert_dir; then
    if prompt_yn "目录中尚无证书，是否用 Let's Encrypt 申请并写入该目录?" "n"; then
      prompt ADMIN_EMAIL "Certbot 邮箱" "${ADMIN_EMAIL:-}"
      check_dns || true
      obtain_le_certificate
      sync_le_certs_to_dir
    else
      die "请先在 ${SSL_CERT_DIR} 放置证书文件后再执行"
    fi
  fi

  install_nginx_https_site

  if is_le_live_cert_dir; then
    setup_certbot_auto_renew "systemctl reload nginx"
    log "使用 Let's Encrypt 目录，续签后 Certbot 会自动更新该目录内文件"
  else
    install_cert_renew_deploy_hook
    setup_certbot_auto_renew "${INSTALL_DIR}/scripts/cert-renew-deploy.sh"
    log "HTTPS 已启用；Let's Encrypt 续签后将同步到 ${SSL_CERT_DIR}/fullchain.pem 与 privkey.pem"
  fi
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
    letsencrypt-manual) apply_tls_letsencrypt_manual_dir ;;
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
      if is_le_live_cert_dir; then
        certbot renew --quiet --deploy-hook 'systemctl reload nginx'
      else
        local hook="${INSTALL_DIR}/scripts/cert-renew-deploy.sh"
        if [[ -x "${hook}" ]]; then
          certbot renew --deploy-hook "${hook}"
        else
          certbot renew --deploy-hook "systemctl reload nginx"
        fi
      fi
      ;;
    *)
      certbot renew --quiet --deploy-hook 'systemctl reload nginx'
      ;;
  esac
  log "证书续签检查完成"
}

tls_main_menu() {
  load_install_info 2>/dev/null || true

  echo ""
  echo -e "${CYAN}════════════ HTTPS / TLS 证书 ════════════${NC}"
  echo "  当前模式: $(tls_mode_label)"
  [[ -n "${DOMAIN:-}" ]] && echo "  域名:     ${DOMAIN}"
  [[ -n "${SSL_CERT_DIR:-}" ]] && echo "  证书目录: ${SSL_CERT_DIR}"
  echo ""
  echo "  [1] 自动申请 Let's Encrypt（Certbot 管理，目录 /etc/letsencrypt/live/域名/）"
  echo "  [2] 使用自定义证书目录（自备 fullchain.pem + privkey.pem）"
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
      prompt DOMAIN "域名" "${DOMAIN:-}"
      prompt_manual_cert_dir
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

prompt_tls_settings() {
  if [[ -n "${TLS_MODE:-}" ]]; then
    log "证书模式: $(tls_mode_label)"
    return 0
  fi

  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    TLS_MODE="${TLS_MODE:-letsencrypt-auto}"
    [[ "${TLS_MODE}" != "http" ]] || { SKIP_CERT=1; REQUIRE_HTTPS=false; }
    if [[ "${TLS_MODE}" == "letsencrypt-manual" && -z "${SSL_CERT_DIR}" ]]; then
      die "非交互手动模式需指定 --cert-dir=/path/to/certs"
    fi
    log "已选: $(tls_mode_label)"
    return 0
  fi

  echo ""
  echo "HTTPS / TLS 证书:"
  echo "  [1] 自动申请 Let's Encrypt（推荐，证书在 /etc/letsencrypt/live/域名/）"
  echo "  [2] 指定证书目录（自行准备 fullchain.pem + privkey.pem）"
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
