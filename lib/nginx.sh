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

# 证书申请/续签见 lib/tls.sh（apply_tls_configuration / tls_renew_now）
