# VPN Node Maintenance

用于维护单机双 VPN 节点的基础项目：

- `vpn.example.com:443`：预留给 SoftEther。
- `vpn.example.com:8443`：预留给 ocserv（OpenConnect/AnyConnect）。
- Cloudflare DDNS：公网 IPv4 变化后自动更新同一域名的 A 记录。
- Let's Encrypt：通过 Cloudflare DNS-01 签发和自动续签证书，不占用 80 或 443。

当前项目只包含 DDNS 和证书生命周期管理。ocserv 与 SoftEther 的安装脚本将在后续加入。

## 工作方式

```text
vpn-ddns.timer
  -> vpn-maintenance.sh ddns
  -> 更新 Cloudflare DNS-only A 记录

certbot.timer
  -> certbot renew
  -> DNS-01 验证成功
  -> 更新 /etc/letsencrypt/live/vpn.example.com/
  -> 执行 deploy hooks
  -> 通知 ocserv 和 SoftEther 加载新证书
```

推荐使用 systemd timer，而不是让 Shell 脚本常驻循环：

- DDNS 每 5 分钟检查一次，并在开机后执行。
- 证书续签使用 Certbot 自带 timer。
- Certbot deploy hook 仅在证书签发或续签成功后执行。

## 文件

| 文件 | 用途 |
|---|---|
| `vpn-maintenance.sh` | DDNS、初始证书签发和手动续签检查 |
| `vpn-maintenance.env.example` | 非敏感配置模板 |
| `vpn-ddns.service` | systemd DDNS oneshot service |
| `vpn-ddns.timer` | systemd DDNS 定时器 |

## 前置条件

目标系统为 Ubuntu 24.04 或兼容的 Debian/Ubuntu 系统。

```bash
sudo apt update
sudo apt install -y curl jq certbot python3-certbot-dns-cloudflare
```

`flock` 由 Ubuntu 默认的 `util-linux` 软件包提供。

## Cloudflare 配置

域名记录必须设置为 **DNS only（灰云）**。普通 Cloudflare HTTP 代理不能转发 SoftEther 或 ocserv 的 VPN 流量。

建议创建两个独立 API Token，并都只授权目标 Zone：

1. DDNS Token：供脚本查询和更新 `vpn.example.com` 的 A 记录。
2. ACME Token：供 Certbot 创建和删除 `_acme-challenge.vpn.example.com` TXT 记录。

不要使用 Global API Key，也不要把 Token 写入 Git 仓库。

## 安装

### 1. 安装脚本和 DDNS timer

```bash
sudo install -m 0755 vpn-maintenance.sh /usr/local/sbin/vpn-maintenance.sh
sudo install -m 0644 vpn-ddns.service /etc/systemd/system/vpn-ddns.service
sudo install -m 0644 vpn-ddns.timer /etc/systemd/system/vpn-ddns.timer
```

### 2. 创建维护配置

```bash
sudo install -m 0600 vpn-maintenance.env.example /etc/vpn-maintenance.env
sudoedit /etc/vpn-maintenance.env
```

需要填写：

```ini
CF_DDNS_API_TOKEN="DDNS_API_TOKEN"
CF_ZONE_ID="CLOUDFLARE_ZONE_ID"
CF_RECORD_NAME="vpn.example.com"
CERT_NAME="vpn.example.com"
LE_EMAIL="admin@example.com"
```

脚本要求 `/etc/vpn-maintenance.env`：

- 所有者为 `root`。
- 权限为 `0600` 或 `0400`。
- 不能是符号链接。

### 3. 创建 Certbot Cloudflare 凭据

```bash
sudo install -d -m 0700 /etc/letsencrypt
sudoedit /etc/letsencrypt/cloudflare-acme.ini
sudo chmod 0600 /etc/letsencrypt/cloudflare-acme.ini
```

文件内容：

```ini
dns_cloudflare_api_token = ACME_API_TOKEN
```

### 4. 首次运行

先同步 DDNS：

```bash
sudo /usr/local/sbin/vpn-maintenance.sh ddns
```

再签发证书：

```bash
sudo /usr/local/sbin/vpn-maintenance.sh issue-cert
```

证书将位于：

```text
/etc/letsencrypt/live/vpn.example.com/fullchain.pem
/etc/letsencrypt/live/vpn.example.com/privkey.pem
```

### 5. 启用定时任务

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-ddns.timer
sudo systemctl enable --now certbot.timer
```

如果使用 Snap 版本 Certbot，续签 timer 通常名为 `snap.certbot.renew.timer`，不要同时启用重复的 Certbot 定时任务。

## 脚本命令

```bash
sudo vpn-maintenance.sh ddns
sudo vpn-maintenance.sh issue-cert
sudo vpn-maintenance.sh renew-cert
```

- `ddns`：获取当前公网 IPv4，必要时创建或更新 Cloudflare A 记录。
- `issue-cert`：首次通过 Cloudflare DNS-01 签发证书。已有同名 Certbot lineage 时不会重复签发。
- `renew-cert`：手动要求 Certbot检查指定证书是否需要续签。

## Certbot hook

Certbot 支持三类 hook：

| 目录 | 触发时机 |
|---|---|
| `/etc/letsencrypt/renewal-hooks/pre/` | 开始续签尝试前 |
| `/etc/letsencrypt/renewal-hooks/deploy/` | 某张证书成功签发或续签后 |
| `/etc/letsencrypt/renewal-hooks/post/` | 本轮续签检查结束后 |

服务加载新证书应使用 `deploy` hook。Certbot 会先更新 `live/` 下的证书软链接，再执行 hook，并提供：

- `RENEWED_LINEAGE`：本次更新的证书目录。
- `RENEWED_DOMAINS`：证书覆盖的域名。

### ocserv 示例

ocserv 配置直接引用 Certbot 文件：

```ini
server-cert = /etc/letsencrypt/live/vpn.example.com/fullchain.pem
server-key = /etc/letsencrypt/live/vpn.example.com/privkey.pem
```

创建 `/etc/letsencrypt/renewal-hooks/deploy/20-ocserv`：

```sh
#!/bin/sh

[ "$RENEWED_LINEAGE" = \
  "/etc/letsencrypt/live/vpn.example.com" ] || exit 0

if systemctl is-active --quiet ocserv.service; then
  systemctl kill --kill-who=main --signal=HUP ocserv.service
fi
```

```bash
sudo chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/20-ocserv
```

签发时使用 `--reuse-key`，可降低 ocserv 热加载证书期间出现连接失败的风险。

### SoftEther 示例

SoftEther 不会持续读取 Certbot 文件，需要在另一个 deploy hook 中通过 `vpncmd ServerCertSet` 导入：

```text
/etc/letsencrypt/renewal-hooks/deploy/30-softether
```

SoftEther 安装脚本应先导入一次当前证书，再创建该 hook。管理员凭据不得硬编码进仓库。

## 状态与日志

```bash
systemctl list-timers vpn-ddns.timer certbot.timer
journalctl -u vpn-ddns.service
sudo certbot certificates
sudo certbot renew --dry-run
```

DDNS 日志会显示记录未变化、创建或更新结果，但不会输出 API Token。

## 安全注意事项

- Cloudflare 记录必须保持 `proxied=false`。
- 两个 API Token 均使用最小权限并限制到目标 Zone。
- `/etc/vpn-maintenance.env` 和 Cloudflare ACME 凭据必须为 root-only。
- 不要提交 API Token、私钥、证书或 SoftEther 管理密码。
- 如果服务器位于 NAT 后面，需要固定内网地址并转发 `443/TCP`、`8443/TCP` 和 `8443/UDP`。
- 如果公网地址属于 CGNAT，DDNS 无法使服务器接受公网入站连接。
