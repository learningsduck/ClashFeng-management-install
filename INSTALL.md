# 安装手册

## 1. 安装前准备

| 项目 | 要求 |
|------|------|
| 系统 | CentOS 7/8/9、Rocky、Alma |
| 权限 | root 或 sudo |
| 域名 | 已解析到本机公网 IP |
| 端口 | 80、443 可访问；22 用于 SSH |
| 仓库 | 能访问 GitHub（克隆 ClashFeng-auth） |

## 2. 角色说明

### [1] 主站一体（首台 VPS）

- Docker MySQL 主库（仅监听 127.0.0.1:3306）
- Docker ClashFeng-auth（127.0.0.1:3001）
- 宿主机 Nginx 反代 + Let's Encrypt

### [2] API 备用节点

- 不安装本地 MySQL
- `.env` 中 `MYSQL_HOST` 指向主库内网 IP
- **JWT_SECRET、ADMIN_INIT_SECRET 必须与主站一致**
- 使用**另一个域名**（建议）

### [3] 仅数据库主库

- 只启动 Docker MySQL
- 可配置允许备用 VPS IP 访问 3306

## 3. 安装后

1. 浏览器打开 `https://域名/`
2. 展开「初始化管理员」，填写 `ADMIN_INIT_SECRET`（见 `install-info.env`）
3. 修改 ClashWin 客户端 `AUTH_API_BASE_URL` 为 `https://域名`

## 4. 目录结构

```text
/opt/clashfeng/
  app/                 # ClashFeng-auth 源码
  compose/             # docker-compose.yml + .env
  install-info.env     # 密钥（勿泄露）
  install.log
```

## 5. 更新后端

```bash
cd /opt/clashfeng/app
git pull
cd /opt/clashfeng/compose
docker compose build app
docker compose up -d
```

## 6. 故障排查

```bash
sudo ./install.sh --health
docker compose -f /opt/clashfeng/compose/docker-compose.yml logs -f
journalctl -u nginx -e
certbot certificates
```

MySQL 连不上：检查主库安全组、firewalld、`MYSQL_HOST` 是否为内网地址。

HTTPS 失败：确认 DNS 已生效，`curl -I http://域名/` 可从公网访问。

### 安装停在 `[db:init] MySQL 表结构初始化完成` 很久

数据库已建好，脚本正在 **构建 Docker 应用镜像**（默认几乎无输出）。请耐心等待，或另开 SSH 执行：

```bash
cd /opt/clashfeng/compose
docker compose build --progress=plain app
docker compose up -d
docker compose logs -f app
```

若拉取 `node:22` 极慢，可配置 Docker 镜像加速后重试构建。
