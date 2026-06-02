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
- `.env` 中 `MYSQL_HOST` 指向主库**公网 IP**（跨 VPS 时）或内网 IP（同机房）
- 安装前须在主库执行 **[9]→[2]** 放行本机 IP，并配置云安全组 3306
- **JWT_SECRET、ADMIN_INIT_SECRET 必须与主站一致**
- 使用**另一个域名**（建议）

详见 [DISASTER.md](./DISASTER.md)。

### [3] 仅数据库主库

- 只启动 Docker MySQL
- 可配置允许备用 VPS IP 访问 3306

## 3. HTTPS / TLS 证书（主菜单 [4]）

| 选项 | 说明 |
|------|------|
| [1] 自动 Let's Encrypt | Certbot 自动配置 Nginx + 自动续签（推荐） |
| [2] 自定义证书目录 | 选择文件夹并自备 `fullchain.pem`、`privkey.pem`（可直接用 `/etc/letsencrypt/live/域名/`） |
| [3] 仅 HTTP | 不申请证书（如内网或 IP 访问） |

非交互示例：

```bash
sudo ./install.sh --role=all-in-one --domain=example.com --email=you@example.com --tls=auto -y
sudo ./install.sh --role=all-in-one --domain=example.com \
  --tls=manual --cert-dir=/etc/letsencrypt/live/example.com -y
```

## 4. 安装后

1. 浏览器打开 `https://域名/`
2. 展开「初始化管理员」，填写 `ADMIN_INIT_SECRET`（见 `install-info.env`）
3. 配置 `/opt/clashfeng/app/public/endpoints.json`（`primary` + `backups` 均为 **https 域名**）
4. ClashWin 构建时设置 `VITE_AUTH_API_PRIMARY=https://域名`（与 endpoints 一致）

**安全**：Node 默认 `BIND_HOST=127.0.0.1`，云安全组 **不要** 对公网开放 **3001**，仅 **80/443**。

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

## 6. 卸载与重装

交互式（推荐）：

```bash
sudo ./install.sh   # 选 [5] → [1] 卸载并准备重装
```

非交互：

```bash
# 推荐：卸载后可直接再装，不会出现 MySQL 密码不一致
sudo ./install.sh --uninstall --reinstall -y
sudo ./install.sh   # 或带 --domain= --email= -y

# 只停服务，保留数据库（升级用；勿用于「重装」）
sudo ./install.sh --uninstall -y

# 完全移除（含证书）
sudo ./install.sh --uninstall --purge-all --remove-cert -y
```

卸载**不会**删除系统级的 Docker、Nginx、Certbot、Node.js。  
`--reinstall` 会清空 MySQL 数据卷、删除 `/opt/clashfeng`，并**保留** HTTPS 证书（同域名重装时无需重新申请）。

## 7. 故障排查

```bash
sudo ./install.sh --health
docker compose -f /opt/clashfeng/compose/docker-compose.yml logs -f
journalctl -u nginx -e
certbot certificates
```

MySQL 连不上：检查主库安全组、firewalld、`MYSQL_HOST` 是否为内网地址。

### `Access denied for user 'clashwin'@'172.18.0.1'`

宿主机连 Docker MySQL 时客户端 IP 常为网桥地址。常见原因：**重装后 .env 密码与旧数据卷不一致**。

```bash
# 方案 A：清空数据卷后重装（测试环境）
sudo ./install.sh --uninstall --purge-data -y
git pull && sudo ./install.sh

# 方案 B：用当前 install-info 里的密码同步（在 compose 目录）
cd /opt/clashfeng/compose
source /opt/clashfeng/install-info.env
docker compose exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e \
  "ALTER USER 'clashwin'@'%' IDENTIFIED BY '$MYSQL_PASSWORD'; FLUSH PRIVILEGES;"
cd /opt/clashfeng/app && node scripts/init-mysql.mjs
```

HTTPS 失败：确认 DNS 已生效，`curl -I http://域名/` 可从公网访问。

### 安装停在 `[db:init] MySQL 表结构初始化完成` 很久

**v1.2+** 已改为宿主机 Node 运行 API，一般不会再卡在此步。若仍使用旧脚本：

```bash
cd ClashFeng-management-install && git pull
chmod +x scripts/resume-after-dbinit.sh
sudo ./scripts/resume-after-dbinit.sh
```

或手动：

```bash
sudo systemctl restart clashfeng-auth
journalctl -u clashfeng-auth -f
```
