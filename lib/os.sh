#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_NAME="${NAME:-unknown}"
  else
    die "无法识别操作系统，仅支持 CentOS/RHEL/Rocky/Alma 7/8/9"
  fi

  case "${OS_ID}" in
    centos|rhel|rocky|almalinux|ol)
      OS_FAMILY=centos
      ;;
    *)
      if [[ "${SKIP_OS_CHECK:-0}" == "1" ]]; then
        warn "未验证的系统: ${OS_ID}，继续安装"
        OS_FAMILY=centos
      else
        die "不支持的操作系统: ${OS_ID}。设置 SKIP_OS_CHECK=1 可强制继续"
      fi
      ;;
  esac

  OS_MAJOR="${OS_VERSION_ID%%.*}"
  log "检测到: ${OS_NAME} (${OS_ID} ${OS_VERSION_ID})"
}

check_env() {
  local mem_kb
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  local mem_mb=$((mem_kb / 1024))
  if [[ "${mem_mb}" -lt 1500 ]]; then
    warn "内存约 ${mem_mb}MB，建议 >= 2GB（CentOS 7 建议 2GB+）"
  fi

  local disk_avail
  disk_avail="$(df -Pm "${INSTALL_DIR%/*}" 2>/dev/null | awk 'NR==2 {print $4}' || df -Pm / | awk 'NR==2 {print $4}')"
  if [[ "${disk_avail:-0}" -lt 5000 ]]; then
    warn "根分区可用空间约 ${disk_avail}MB，建议 >= 10GB"
  fi

  local pip
  pip="$(public_ip)"
  log "公网 IP（探测）: ${pip}"

  if ss -tln 2>/dev/null | grep -qE ':80 |:80$'; then
    warn "端口 80 已被占用，Certbot/Nginx 可能冲突"
  fi
  if ss -tln 2>/dev/null | grep -qE ':443 |:443$'; then
    warn "端口 443 已被占用"
  fi
}

install_base_packages() {
  log "安装基础依赖 (git, curl, openssl)..."
  if command -v dnf &>/dev/null; then
    dnf install -y git curl openssl ca-certificates
  elif command -v yum &>/dev/null; then
    yum install -y git curl openssl ca-certificates
  else
    die "未找到 yum/dnf"
  fi
}

install_docker() {
  if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    log "Docker 已安装: $(docker --version)"
    return
  fi

  log "安装 Docker Engine + Compose 插件..."
  if [[ "${OS_MAJOR}" == "7" ]]; then
    yum install -y yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  else
    dnf install -y dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi

  systemctl enable docker
  systemctl start docker
  log "Docker 安装完成"
}

install_nginx_certbot() {
  log "安装宿主机 Nginx + Certbot..."
  if [[ "${OS_MAJOR}" == "7" ]]; then
    yum install -y epel-release
    yum install -y nginx certbot python2-certbot-nginx || {
      warn "python2-certbot-nginx 失败，尝试仅 certbot"
      yum install -y certbot
    }
  else
    if ! rpm -q epel-release &>/dev/null; then
      dnf install -y epel-release
    fi
    dnf install -y nginx certbot python3-certbot-nginx
  fi
  systemctl enable nginx
  systemctl start nginx || true
}

open_firewall_http() {
  if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
    firewall-cmd --permanent --add-service=http 2>/dev/null || true
    firewall-cmd --permanent --add-service=https 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log "firewalld 已放行 http/https"
  else
    warn "未启用 firewalld，请在云厂商安全组放行 80/443"
  fi
  warn_app_port_not_public
}

warn_app_port_not_public() {
  local port="${APP_PORT:-3001}"
  warn "请勿在云安全组对公网开放 TCP ${port}；API 仅通过 Nginx 443 访问（Node 绑定 127.0.0.1）"
}

allow_mysql_from_ip() {
  local remote_ip="$1"
  if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
    firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${remote_ip}/32' port port='3306' protocol='tcp' accept" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log "firewalld 已允许 ${remote_ip} 访问 3306"
  fi
  warn "若 MySQL 在云上，请在安全组额外放行 3306 来源 ${remote_ip}"
}
