#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

health_check() {
  load_install_info
  local ok=1
  echo "=== ClashFeng 健康检查 ==="

  if [[ -f "${COMPOSE_DIR}/docker-compose.yml" ]]; then
    cd "${COMPOSE_DIR}"
    docker compose ps || true
  fi

  local curl_opts=()
  if [[ "${REQUIRE_HTTPS:-false}" == "true" ]]; then
    curl_opts=(-H "X-Forwarded-Proto: https")
  fi
  if curl -sf "${curl_opts[@]}" "http://127.0.0.1:${APP_PORT:-3001}/auth/captcha" >/dev/null; then
    echo -e "${GREEN}OK${NC} 本地 API http://127.0.0.1:${APP_PORT:-3001}/auth/captcha"
  else
    echo -e "${RED}FAIL${NC} 本地 API"
    ok=0
  fi

  if [[ -n "${DOMAIN:-}" ]]; then
    if curl -sfk "https://${DOMAIN}/auth/captcha" >/dev/null 2>&1 || curl -sf "https://${DOMAIN}/auth/captcha" >/dev/null 2>&1; then
      echo -e "${GREEN}OK${NC} HTTPS https://${DOMAIN}/auth/captcha"
    else
      echo -e "${RED}FAIL${NC} HTTPS https://${DOMAIN}/"
      ok=0
    fi
  fi

  return $((ok == 0))
}

show_install_info() {
  load_install_info
  if [[ ! -f "${INSTALL_INFO}" ]]; then
    die "未找到 ${INSTALL_INFO}，请先安装"
  fi
  echo "=== install-info (${INSTALL_INFO}) ==="
  sed 's/\(PASSWORD\|SECRET\)=.*/\1=***hidden***/' "${INSTALL_INFO}"
  echo ""
  echo "查看完整密钥: sudo cat ${INSTALL_INFO}"
}

renew_cert() {
  load_install_info
  certbot renew --quiet --deploy-hook 'systemctl reload nginx'
  log "证书续签完成"
}
