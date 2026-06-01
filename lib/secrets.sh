#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

rand_hex() {
  openssl rand -hex 32
}

# 避免 shell 中残留旧 MYSQL_* / JWT_* 导致重装密码与数据卷不一致
clear_stale_install_env() {
  unset MYSQL_ROOT_PASSWORD MYSQL_PASSWORD JWT_SECRET ADMIN_INIT_SECRET 2>/dev/null || true
}

generate_secrets() {
  if [[ -z "${JWT_SECRET:-}" ]]; then
    JWT_SECRET="$(rand_hex)"
  fi
  if [[ -z "${ADMIN_INIT_SECRET:-}" ]]; then
    ADMIN_INIT_SECRET="$(rand_hex)"
  fi
  if [[ -z "${MYSQL_PASSWORD:-}" ]]; then
    MYSQL_PASSWORD="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)"
  fi
  if [[ "${INSTALL_ROLE}" == "all-in-one" || "${INSTALL_ROLE}" == "db-only" ]]; then
    if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
      MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)"
    fi
  fi
}
