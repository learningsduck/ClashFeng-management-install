# ClashFeng-management-install

ClashFeng 认证后端 + 管理后台在 **CentOS 7/8/9** 上的一键安装脚本。

- 宿主机 **Nginx + Certbot**（HTTPS 自动申请与续签）
- **Docker**：仅 MySQL；**API** 用宿主机 Node + systemd（避免 Docker 构建卡住）
- 支持：主站一体、API 备用节点、仅数据库主库

## 快速开始

```bash
yum install -y git   # 或 dnf install -y git
git clone https://github.com/learningsduck/ClashFeng-management-install.git
cd ClashFeng-management-install
chmod +x install.sh
sudo ./install.sh
```

安装完成后：

- 管理后台：`https://你的域名/`（安装时也可选「稍后配置域名/证书」，完成后在主菜单 **[4] HTTPS/TLS** 设置）
- 密钥文件：`/opt/clashfeng/install-info.env`（权限 600）

非交互示例（先装服务，后配证书）：

```bash
sudo ./install.sh -y --role=all-in-one --defer-tls --dir=/opt/clashfeng
# 安装后：sudo ./install.sh → [4] → [6] 填域名 → [2] 证书目录 → [4] 应用
```

详细说明见 [INSTALL.md](./INSTALL.md)。

## 维护命令

```bash
sudo ./install.sh          # [4] HTTPS / [5] 管理员 / [8] 后台入口 / [9] 容灾 / [7] 卸载
sudo ./install.sh --health
sudo ./install.sh --renew-cert
sudo ./install.sh --show-info
sudo ./install.sh --show-admin-url   # 随时查看管理后台 URL
```

## 一键卸载

```bash
sudo ./install.sh                    # 主菜单 [5] → 选 [1] 卸载并准备重装（推荐）
sudo ./install.sh --uninstall --reinstall -y   # 非交互：清库+删目录，保留 HTTPS 证书
sudo ./install.sh --uninstall -y     # 仅停服务（保留数据卷；重装可能密码冲突）
sudo ./install.sh --uninstall --purge-all --remove-cert -y   # 彻底删除（含证书）
```

| 选项 | 作用 |
|------|------|
| `--reinstall` | **推荐**：等同清数据卷 + 删除 `/opt/clashfeng`，保留 Let's Encrypt 证书 |
| `--purge-data` | `docker compose down -v`，清空数据库 |
| `--purge-all` | 删除 `/opt/clashfeng` 整个目录 |
| `--purge-images` | 删除本机构建的 Docker 镜像 |
| `--remove-cert` | `certbot delete` 删除域名证书 |

## 多 VPS 容灾（域名/IP 被封时）

1. **旧 VPS（主库）**：`[9] 容灾与主库连接` → `[2]` 放行新 VPS IP + 云安全组 3306
2. **新 VPS**：`[2] API 备用节点`，`MYSQL_HOST` 填主库**公网 IP**，`JWT_SECRET` 与主库一致
3. **客户端**：`[9] → [4]` 导出 `endpoints.json`，或参考 `endpoints.json.example`

详细步骤见 [DISASTER.md](./DISASTER.md)。

## 系统要求

- CentOS / RHEL / Rocky / Alma **7 / 8 / 9**
- 内存建议 ≥ 2GB
- 域名 A 记录指向 VPS 公网 IP（申请证书前）
- 安全组放行 **80、443**；**不要**对公网开放 3306、3001
