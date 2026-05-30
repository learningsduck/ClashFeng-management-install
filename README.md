# ClashFeng-management-install

ClashFeng 认证后端 + 管理后台在 **CentOS 7/8/9** 上的一键安装脚本。

- 宿主机 **Nginx + Certbot**（HTTPS 自动申请与续签）
- **Docker**：MySQL + [ClashFeng-auth](https://github.com/learningsduck/ClashFeng-auth)
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

- 管理后台：`https://你的域名/`
- 密钥文件：`/opt/clashfeng/install-info.env`（权限 600）

详细说明见 [INSTALL.md](./INSTALL.md)。

## 维护命令

```bash
sudo ./install.sh          # 交互菜单 → [4] 维护工具
sudo ./install.sh --health
sudo ./install.sh --renew-cert
sudo ./install.sh --show-info
```

## 多 VPS 容灾

1. **主 VPS**：选 `[1] 主站一体`
2. **备用 VPS**：选 `[2] API 备用节点`，填写主库内网地址与**相同** `JWT_SECRET`
3. 客户端主/备域名见 `endpoints.json.example`

## 系统要求

- CentOS / RHEL / Rocky / Alma **7 / 8 / 9**
- 内存建议 ≥ 2GB
- 域名 A 记录指向 VPS 公网 IP（申请证书前）
- 安全组放行 **80、443**；**不要**对公网开放 3306、3001
