#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

install_nginx_site() {
  log "配置 Nginx 反向代理..."
  render_template "${SCRIPT_DIR}/templates/nginx.conf.tpl" "/etc/nginx/conf.d/clashfeng.conf"
  nginx -t
  systemctl reload nginx
}

check_dns() {
  local domain_ip
  domain_ip="$(resolve_domain "${DOMAIN}")"
  local my_ip
  my_ip="$(public_ip)"
  if [[ -z "${domain_ip}" ]]; then
    warn "无法解析域名 ${DOMAIN}，Certbot 可能失败。可稍后重跑: certbot --nginx -d ${DOMAIN}"
    return 1
  fi
  if [[ "${domain_ip}" != "${my_ip}" && "${SKIP_DNS_CHECK:-0}" != "1" ]]; then
    warn "域名 ${DOMAIN} 解析为 ${domain_ip}，本机公网 IP 为 ${my_ip}，不一致"
    prompt_yn "仍继续申请证书?" "n" || return 1
  else
    log "DNS 检查通过: ${DOMAIN} -> ${domain_ip}"
  fi
}

run_certbot() {
  if [[ -z "${DOMAIN:-}" || -z "${ADMIN_EMAIL:-}" ]]; then
    warn "未配置域名或邮箱，跳过 Certbot"
    return 0
  fi
  check_dns || true

  log "申请 Let's Encrypt 证书..."
  local staging_arg=()
  if [[ "${CERTBOT_STAGING:-0}" == "1" ]]; then
    staging_arg=(--staging)
  fi

  if certbot --nginx -d "${DOMAIN}" --email "${ADMIN_EMAIL}" --agree-tos --non-interactive "${staging_arg[@]}" 2>/dev/null; then
    :
  else
    certbot --nginx -d "${DOMAIN}" --email "${ADMIN_EMAIL}" --agree-tos --non-interactive "${staging_arg[@]}" || {
      warn "Certbot 失败。请确认 80 端口可从公网访问且 DNS 已生效后执行:"
      warn "  certbot --nginx -d ${DOMAIN}"
      return 1
    }
  fi

  systemctl enable certbot-renew.timer 2>/dev/null || true
  systemctl start certbot-renew.timer 2>/dev/null || true

  if ! crontab -l 2>/dev/null | grep -q certbot; then
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'") | crontab - 2>/dev/null || true
  fi
  log "HTTPS 证书配置完成"
}

setup_certbot_cron() {
  systemctl enable certbot-renew.timer 2>/dev/null || true
}
