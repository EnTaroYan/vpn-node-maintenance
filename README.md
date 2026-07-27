# VPN Node Maintenance

## 已测试环境

本项目仅在 Ubuntu amd64 和 arm64 上完成测试。其他提供 apt、systemd、
ocserv 和 nftables 的平台可能兼容，但未经过验证；脚本不会按发行版、
版本或 CPU 架构提前拒绝安装。

## 文件

| 文件 | 用途 |
|---|---|
| `server/vpn-maintenance.sh` | DDNS、初始证书签发和手动续签检查 |
| `server/vpn-maintenance.env.example` | 配置模板 |
| `server/vpn-ddns.service` | systemd DDNS oneshot service |
| `server/vpn-ddns.timer` | systemd DDNS 定时器（每 5 分钟，开机后执行） |
| `server/ocserv-deploy.sh` | ocserv（OpenConnect/AnyConnect）一键安装、用户管理 |
| `tests/server/ocserv-deploy-test.sh` | `server/ocserv-deploy.sh` 的 Bash 测试套件 |

## 准备

```bash
sudo install -m 0755 server/vpn-maintenance.sh /usr/local/sbin/vpn-maintenance.sh
sudo install -m 0644 server/vpn-ddns.service server/vpn-ddns.timer /etc/systemd/system/
sudo install -m 0600 server/vpn-maintenance.env.example /etc/vpn-maintenance.env
sudo -e /etc/vpn-maintenance.env
```

已有 `/etc/vpn-maintenance.env` 时，增量追加新变量，不要整个文件覆盖。

## 1. DDNS（可选）

仅在公网 IP 不固定且需要通过域名追踪节点时执行。

在 `/etc/vpn-maintenance.env` 中填写：

```bash
CF_DDNS_API_TOKEN="replace-with-ddns-api-token"
CF_ZONE_ID="replace-with-32-character-zone-id"
CF_RECORD_NAMES=(
  "vpn.example.com"
)
```

```bash
sudo apt update
sudo apt install -y curl jq
sudo /usr/local/sbin/vpn-maintenance.sh ddns
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-ddns.timer
```

## 2. Let's Encrypt 证书（可选）

此步骤可选；使用 `OCSERV_CERT_MODE="selfsigned"` 时可跳过，无需域名和 Cloudflare。

在 `/etc/vpn-maintenance.env` 中填写：

```bash
CERT_NAME="example.com"
CERT_DOMAINS=(
  "*.example.com"
)
LE_EMAIL="admin@example.com"
CF_DNS_CREDENTIALS_FILE="/etc/letsencrypt/cloudflare-acme.ini"
LE_CONFIG_DIR="/etc/letsencrypt"
```

创建 `/etc/letsencrypt/cloudflare-acme.ini`：

```ini
dns_cloudflare_api_token = ACME_API_TOKEN
```

```bash
sudo apt install -y certbot python3-certbot-dns-cloudflare
sudo install -d -m 0700 /etc/letsencrypt
sudo -e /etc/letsencrypt/cloudflare-acme.ini
sudo chmod 600 /etc/letsencrypt/cloudflare-acme.ini
sudo /usr/local/sbin/vpn-maintenance.sh issue-cert
sudo systemctl enable --now certbot.timer
```

## 3. OpenConnect / ocserv 部署

在 `/etc/vpn-maintenance.env` 中填写：

```bash
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=(
  "8.8.4.4"
)
# letsencrypt | selfsigned
OCSERV_CERT_MODE="letsencrypt"
```

```bash
sudo ./server/ocserv-deploy.sh install
sudo ./server/ocserv-deploy.sh add-user USERNAME
sudo ./server/ocserv-deploy.sh del-user USERNAME
```

若 `/etc/ocserv/ocserv.conf` 已存在，安装器会要求输入 y 确认，先备份原配置，
再用新配置替换；无交互终端时会中止。

Azure 或云平台防火墙须同时放行 `OCSERV_PORT` 的 TCP 和 UDP 入站。

固定 IP/域名且使用 `selfsigned` 模式时可跳过步骤 1 和 2，直接执行此步骤。

## 4. SoftEther 部署

SoftEther 自动部署脚本尚未实现。计划使用 443，并与 ocserv 使用不同端口、
地址池和 nftables 表。

## 状态检查

```bash
systemctl status vpn-ddns.timer certbot.timer ocserv.service
sudo journalctl -u vpn-ddns.service -u ocserv.service -e
PORT=8443  # replace with your OCSERV_PORT
sudo ss -H -ltnp "sport = :${PORT}"
sudo ss -H -lunp "sport = :${PORT}"
sudo nft list table ip vpn_node_ocserv
```

## 安全提醒

- Cloudflare 记录须保持 DNS-only（灰云）。
- Token、env 文件、私钥、密码文件须为 root-only，不得提交到 Git。
- `selfsigned` 模式下服务端将完整自签证书以 `HY2_CERT_PEM_B64`（base64 PEM）写入客户端 env，客户端解码到 `/etc/homeproxy/certs/hy2-server.pem` 并信任；同时打印 `pin-sha256` 供核对。
- DDNS 和证书成功不等于 Azure 入站端口已放行。
