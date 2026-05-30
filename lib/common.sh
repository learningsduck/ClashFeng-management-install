#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config/defaults.env"

INSTALL_INFO="${INSTALL_DIR}/install-info.env"
LOG_FILE="${INSTALL_DIR}/install.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*" | tee -a "${LOG_FILE}"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "${LOG_FILE}"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}" >&2; }
die()  { err "$@"; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 运行，或: sudo $0"
  fi
}

mkdir_p() {
  mkdir -p "$@"
}

load_install_info() {
  if [[ -f "${INSTALL_INFO}" ]]; then
    # shellcheck source=/dev/null
    set -a
    source "${INSTALL_INFO}"
    set +a
  fi
}

save_install_info() {
  mkdir_p "${INSTALL_DIR}"
  chmod 700 "${INSTALL_DIR}"
  cat > "${INSTALL_INFO}" <<EOF
# ClashFeng install-info — 请妥善保管 (${INSTALL_INFO})
INSTALLED_AT=$(date -Iseconds 2>/dev/null || date)
INSTALL_ROLE=${INSTALL_ROLE:-}
DOMAIN=${DOMAIN:-}
ADMIN_EMAIL=${ADMIN_EMAIL:-}
INSTALL_DIR=${INSTALL_DIR}
COMPOSE_DIR=${COMPOSE_DIR}
APP_DIR=${APP_DIR}
MYSQL_HOST=${MYSQL_HOST:-}
MYSQL_PORT=${MYSQL_PORT:-}
MYSQL_DATABASE=${MYSQL_DATABASE:-}
MYSQL_USER=${MYSQL_USER:-}
MYSQL_PASSWORD=${MYSQL_PASSWORD:-}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-}
JWT_SECRET=${JWT_SECRET:-}
ADMIN_INIT_SECRET=${ADMIN_INIT_SECRET:-}
REQUIRE_HTTPS=${REQUIRE_HTTPS:-true}
ADMIN_IP_WHITELIST=${ADMIN_IP_WHITELIST:-}
AUTH_REPO_URL=${AUTH_REPO_URL:-}
AUTH_REPO_BRANCH=${AUTH_REPO_BRANCH:-}
EOF
  chmod 600 "${INSTALL_INFO}"
}

prompt() {
  local var_name="$1"
  local message="$2"
  local default="${3:-}"
  local value
  if [[ -n "${default}" ]]; then
    read -r -p "${message} [${default}]: " value
    value="${value:-$default}"
  else
    read -r -p "${message}: " value
  fi
  printf -v "${var_name}" '%s' "${value}"
}

prompt_yn() {
  local message="$1"
  local default="${2:-Y}"
  local value
  read -r -p "${message} [${default}/n]: " value
  value="${value:-$default}"
  [[ "${value}" =~ ^[Yy] ]]
}

render_template() {
  local tpl="$1"
  local out="$2"
  local content
  content="$(cat "${tpl}")"
  local vars=(
    DOMAIN ADMIN_EMAIL INSTALL_DIR APP_DIR COMPOSE_DIR APP_PORT
    MYSQL_HOST MYSQL_PORT MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD MYSQL_ROOT_PASSWORD
    JWT_SECRET ADMIN_INIT_SECRET REQUIRE_HTTPS ADMIN_IP_WHITELIST
    NODE_ENV APP_PORT AUTH_REPO_URL
  )
  for v in "${vars[@]}"; do
    content="${content//\{\{${v}\}\}/${!v:-}}"
  done
  echo "${content}" > "${out}"
}

public_ip() {
  curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
    || echo "unknown"
}

resolve_domain() {
  local domain="$1"
  getent ahosts "${domain}" 2>/dev/null | awk '{print $1; exit}'
}
