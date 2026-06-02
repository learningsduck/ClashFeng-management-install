# 容灾：旧域名被封，新 VPS + 新域名

## 架构

```text
[旧 VPS — 被封 IP]          [新 VPS — 新域名]
  MySQL 主库 (3306)    ←——    API + Nginx + 管理后台
  仅放行新 VPS IP              客户端访问 https://新域名/
```

## 步骤一：旧 VPS（主库）— 放行新 VPS

1. 登录**旧 VPS**（仍运行 MySQL 的机器）
2. 更新脚本：`cd ClashFeng-management-install && git pull`
3. 执行：

```bash
sudo ./install.sh
# 主菜单 [9] 容灾与主库连接 → [2] 允许备用 API 节点 IP
# 填入【新 VPS 公网 IP】
```

或一行命令（将 `新VPS的IP` 替换为实际 IP）：

```bash
sudo ./install.sh --prepare-standby-ip=新VPS的IP
```

4. 在**云厂商安全组**（旧 VPS）添加入站：**TCP 3306 ← 新 VPS IP/32**
5. 记录旧 VPS 公网 IP，供新 VPS 作 `MYSQL_HOST`

## 步骤二：新 VPS — 安装备用 API

1. 新域名 **A 记录** 指向新 VPS
2. 克隆并安装：

```bash
git clone https://github.com/learningsduck/ClashFeng-management-install.git
cd ClashFeng-management-install
sudo ./install.sh
# [2] API 备用节点
```

3. 按提示填写：
   - **MYSQL_HOST**：旧 VPS **公网 IP**
   - **MYSQL_PASSWORD / JWT_SECRET / ADMIN_INIT_SECRET**：从旧机 `/opt/clashfeng/install-info.env` 复制
   - **新域名** + HTTPS（菜单 [4]）

4. 安装前会自动测试主库连接；失败时按屏幕检查清单排查

## 步骤三：客户端

```bash
sudo ./install.sh
# [9] → [4] 导出 endpoints.json
```

将 `primary` 改为 `https://新域名`，旧域名可放入 `backups`（若仍可用）。

## 常用命令

| 命令 | 作用 |
|------|------|
| `sudo ./install.sh` → **[9]** | 容灾菜单 |
| `sudo ./install.sh --show-topology` | 查看角色 / 主库 / 绑定 |
| `sudo ./install.sh --test-mysql` | 测试主库连接 |
| `sudo ./install.sh --export-endpoints` | 导出客户端配置 |
| `sudo ./install.sh --health` | 含远程主库检测（备用节点） |

## 注意

- **切勿**将 3306 对 `0.0.0.0/0` 开放；仅放行新 VPS IP
- 长期建议将 MySQL **迁移到新 VPS**，跨公网连库仅作过渡
- 管理后台路径每次安装可能不同，用 **[8] 查询管理后台入口**
