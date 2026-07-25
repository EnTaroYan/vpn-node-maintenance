# VPN Node Maintenance

用于维护单机双 VPN 节点的基础项目：

- `vpn.example.com:443`：预留给 SoftEther。
- `vpn.example.com:8443`：预留给 ocserv（OpenConnect/AnyConnect）。
- Cloudflare DDNS：公网 IPv4 变化后自动更新同一 Zone 下的多个 A 记录。
- Let's Encrypt：通过 Cloudflare DNS-01 签发和自动续签根域名及通配符证书，不占用 80 或 443。

项目包含 DDNS、证书生命周期管理，以及 `ocserv-deploy.sh`（OpenConnect/AnyConnect 服务端一键部署）。SoftEther 的安装脚本将在后续加入。

## 工作方式

```text
vpn-ddns.timer
  -> vpn-maintenance.sh ddns
  -> 更新多个 Cloudflare DNS-only A 记录

certbot.timer
  -> certbot renew
  -> DNS-01 验证成功
  -> 更新 /etc/letsencrypt/live/example.com/
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
| `ocserv-deploy.sh` | ocserv（OpenConnect/AnyConnect）一键安装、用户管理 |
| `tests/ocserv-deploy-test.sh` | `ocserv-deploy.sh` 的 Bash 测试套件 |

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

1. DDNS Token：供脚本查询和更新配置的多个 A 记录。
2. ACME Token：供 Certbot 创建和删除 `_acme-challenge.example.com` TXT 记录。

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
CF_RECORD_NAMES=(
  "vpn.example.com"
  "node.example.com"
)
CERT_NAME="example.com"
CERT_DOMAINS=(
  "example.com"
  "*.example.com"
)
LE_EMAIL="admin@example.com"
```

`CF_RECORD_NAMES` 是 Bash 数组，其中所有记录必须属于 `CF_ZONE_ID` 指定的同一个 Cloudflare Zone。脚本获取一次公网 IPv4，然后依次创建或更新每个 DNS-only A 记录。旧配置 `CF_RECORD_NAME="vpn.example.com"` 仍然兼容。

`CERT_NAME` 是 Certbot lineage 名称，决定证书目录；`CERT_DOMAINS` 是证书实际包含的 SAN：

- `example.com` 覆盖根域名本身。
- `*.example.com` 覆盖 `vpn.example.com`、`node.example.com` 等一级子域名。
- `*.example.com` **不覆盖** `a.b.example.com`，也不自动覆盖 `example.com`，因此示例中同时列出两项。

普通的 `example.com` 证书不能给 `vpn.example.com` 使用；必须显式申请 `*.example.com` 通配符 SAN，或逐个列出三级域名。

通配符必须写在引号中，避免 Shell 将 `*` 展开成本地文件名。

#### 证书路径的单一配置源

后续的 ocserv 和 SoftEther 部署脚本不应分别硬编码 Certbot 路径。统一读取 `/etc/vpn-maintenance.env` 中的 `LE_CONFIG_DIR` 和 `CERT_NAME`，再派生证书路径：

```bash
source /etc/vpn-maintenance.env

CERT_LIVE_DIR="${LE_CONFIG_DIR:-/etc/letsencrypt}/live/${CERT_NAME}"
CERT_FULLCHAIN_FILE="${CERT_LIVE_DIR}/fullchain.pem"
CERT_PRIVATE_KEY_FILE="${CERT_LIVE_DIR}/privkey.pem"
```

- SoftEther 安装脚本和 Certbot deploy hook 可以直接使用 `CERT_FULLCHAIN_FILE`、`CERT_PRIVATE_KEY_FILE` 调用 `vpncmd ServerCertSet`。
- ocserv 配置文件不会展开 Shell 变量，因此 ocserv 部署脚本应读取 env，并把派生后的实际路径写入 `ocserv.conf`。
- Certbot 续签只会原子更新 `live/` 目录中的软链接；只要 `CERT_NAME` 不变，ocserv 配置和 SoftEther hook 都不需要修改路径。
- `/etc/vpn-maintenance.env` 为 root-only 文件，读取它的安装脚本和 hook 也应以 root 运行。

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
/etc/letsencrypt/live/example.com/fullchain.pem
/etc/letsencrypt/live/example.com/privkey.pem
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

- `ddns`：获取一次当前公网 IPv4，必要时创建或更新配置的全部 Cloudflare A 记录。
- `issue-cert`：通过 Cloudflare DNS-01 签发证书；已有同名且域名集合较小的 lineage 时扩展证书 SAN。
- `renew-cert`：手动要求 Certbot检查指定证书是否需要续签。

Certbot 会把成功签发时的 SAN 集合写入 renewal 配置，之后的自动续签会沿用该集合。修改 `CERT_DOMAINS` 后，需要再次手动运行 `issue-cert` 才会扩展现有证书。

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

ocserv 部署脚本读取 env 后，生成的配置直接引用稳定的 Certbot `live/` 路径。例如：

```ini
server-cert = /etc/letsencrypt/live/example.com/fullchain.pem
server-key = /etc/letsencrypt/live/example.com/privkey.pem
```

创建 `/etc/letsencrypt/renewal-hooks/deploy/20-ocserv`：

```sh
#!/bin/sh

CONFIG_FILE="${VPN_MAINTENANCE_CONFIG:-/etc/vpn-maintenance.env}"
. "$CONFIG_FILE"

CERT_LIVE_DIR="${LE_CONFIG_DIR:-/etc/letsencrypt}/live/${CERT_NAME}"
[ "$RENEWED_LINEAGE" = "$CERT_LIVE_DIR" ] || exit 0

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

该 hook 同样读取 `/etc/vpn-maintenance.env` 并派生 `CERT_FULLCHAIN_FILE` 和 `CERT_PRIVATE_KEY_FILE`，再传给 `vpncmd`。SoftEther 安装脚本应先导入一次当前证书，再创建 hook。管理员凭据不得写入 env 或仓库，应放在独立的 root-only 凭据文件中。

## ocserv 部署（OpenConnect / AnyConnect）

`ocserv-deploy.sh` 是幂等、事务化的一键安装脚本：安装步骤失败时自动回滚到安装前的文件和服务状态，成功后原子替换所有受管文件。

### 支持的系统

- 操作系统：Ubuntu 22.04 或 24.04（通过 `/etc/os-release` 的 `ID`/`VERSION_ID` 检测，其他发行版或版本直接拒绝）。
- 架构：`amd64` 或 `arm64`（通过 `dpkg --print-architecture` 检测）。
- 依赖包由脚本在 `install` 时自动安装：`ocserv`、`nftables`、`openssl`、`iproute2`、`util-linux`。

### 新增的 5 个配置项

在 `/etc/vpn-maintenance.env` 中追加（默认值见 `vpn-maintenance.env.example`）：

| 变量 | 默认示例 | 说明 |
|---|---|---|
| `OCSERV_ENDPOINT` | `"vpn.example.com"` | 客户端连接的域名或裸 IPv4 地址，同时用于证书 SAN 匹配。 |
| `OCSERV_PORT` | `"8443"` | TCP 与 UDP 共用同一个端口号（`tcp-port`/`udp-port`）。 |
| `OCSERV_IPV4_NETWORK` | `"10.66.0.0/24"` | 分配给 VPN 客户端的 IPv4 网段，必须是 `/24` 网络地址，且不得与现有路由重叠。 |
| `OCSERV_DNS` | `OCSERV_DNS=("8.8.4.4")` | 下发给客户端的 DNS 服务器，Bash 索引数组，可写多个，不能为空。 |
| `OCSERV_CERT_MODE` | `"letsencrypt"` | 证书模式，只能是 `letsencrypt` 或 `selfsigned`。 |

`OCSERV_PORT` 必须在 1-65535 之间；`OCSERV_IPV4_NETWORK` 只接受 `/24`；`OCSERV_DNS` 必须声明为索引数组（`OCSERV_DNS="8.8.4.4"` 这种标量写法会被拒绝）。

### 证书模式

#### `letsencrypt` 模式

- 前置条件：已通过本项目的 `vpn-maintenance.sh issue-cert` 成功签发证书，且 `CERT_DOMAINS`／`CERT_NAME` 覆盖 `OCSERV_ENDPOINT`（域名场景通常需要 `*.example.com` 通配符 SAN）。
- 证书路径由 `LE_CONFIG_DIR`（默认 `/etc/letsencrypt`）和 `CERT_NAME` 派生：`live/${CERT_NAME}/fullchain.pem` 与 `.../privkey.pem`。
- **`install` 不会代为签发证书**：证书或私钥文件缺失、证书与私钥不匹配、证书已过期、或证书 SAN 与 `OCSERV_ENDPOINT` 不匹配，都会导致安装立即失败退出（`die`），不会创建或修改任何受管文件。
- 安装成功后会创建 Certbot deploy hook `/etc/letsencrypt/renewal-hooks/deploy/20-ocserv`，证书续签后自动 `systemctl reload ocserv.service`。

#### `selfsigned` 模式

- 完全独立于 DDNS、Cloudflare 和 Certbot：不需要 `CF_*`、`CERT_NAME`、`CERT_DOMAINS`、`LE_EMAIL` 等任何一项配置。
- 首次安装会生成一张 10 年有效期的自签名证书（`/etc/ocserv/ssl/selfsigned-{cert,key}.pem`），CN/SAN 绑定到 `OCSERV_ENDPOINT`；再次安装会复用已存在且匹配的证书/私钥对。
- **不会创建任何 Certbot hook**。如果之前是 `letsencrypt` 模式且已经创建了受管 hook，切换到 `selfsigned` 时该 hook 会被自动删除；如果 hook 路径上存在非本工具管理的文件，则原样保留、不做任何改动。

### 域名 vs 裸 IP 端点的证书行为

`OCSERV_ENDPOINT` 是否为合法 IPv4 字面量决定证书校验方式：

- 裸 IP（如 `104.46.217.92`）：自签名证书使用 `IP` 类型的 SAN 生成，校验时用 `openssl x509 -checkip`。
- 域名（如 `vpn.example.com`）：自签名证书使用 `DNS` 类型的 SAN，校验时用 `openssl x509 -checkhost`。

两种校验在 `letsencrypt` 模式下同样适用于已有证书。公共 CA 通常不为 IPv4 地址签发证书，因此裸 IP 端点应使用 `selfsigned` 模式；只有域名端点才适合 `letsencrypt` 模式。

### 命令

```bash
sudo ./ocserv-deploy.sh install
sudo ./ocserv-deploy.sh add-user [USERNAME]
sudo ./ocserv-deploy.sh del-user [USERNAME]
sudo ./ocserv-deploy.sh help
```

- `install`：校验配置、安装依赖包、生成/复用证书、渲染并原子替换所有受管文件、启用并重启 `ocserv.service`、验证 TCP/UDP 监听。首次安装且密码库为空时会交互式提示创建一个初始 VPN 用户。任一步骤失败都会完整回滚（恢复文件、systemd 启用/激活状态）。同一时刻只允许一个 `install` 实例运行（`/run/lock/ocserv-deploy.lock`）。
- `add-user [USERNAME]`：省略用户名时交互式提示；交互式输入两次密码并确认一致后写入 `ocpasswd`；用户名已存在会失败。
- `del-user [USERNAME]`：省略用户名时交互式提示；删除不存在的用户名会失败。

### 生成的文件与管理标记

| 路径 | 内容 |
|---|---|
| `/etc/ocserv/ocserv.conf` | ocserv 主配置 |
| `/etc/ocserv/ocpasswd` | `ocpasswd` 格式的用户密码库，跨多次 `install` 保留 |
| `/etc/ocserv/ssl/selfsigned-cert.pem`、`selfsigned-key.pem` | 仅 `selfsigned` 模式生成 |
| `/usr/local/libexec/vpn-node/ocserv-network` | nftables 生命周期辅助脚本（`check`/`up`/`down`） |
| `/etc/systemd/system/ocserv.service.d/10-network.conf` | systemd 服务 drop-in，绑定 nftables 生命周期 |
| `/etc/letsencrypt/renewal-hooks/deploy/20-ocserv` | 仅 `letsencrypt` 模式生成的 Certbot deploy hook |

除 `ocpasswd`（用户密码库需要跨版本保留）外，以上每个受管文件的第一行都写入固定标记：

```text
# Managed by vpn-node-maintenance: ocserv-deploy.sh
```

`install` 在覆盖任何目标前都会检查：路径不存在则可以创建；路径存在但不含该标记，则视为"非本工具管理"，直接拒绝安装并原样保留该文件（`ocserv.conf` 额外备份一份到 `.pre-vpn-node-<UTC时间戳>.bak` 后再报错退出）。这保证了 `ocserv-deploy.sh` 永远不会静默覆盖手工维护或第三方工具生成的配置。

### 全隧道、NAT 与防火墙

- 客户端配置固定 `route = default`，即全隧道（所有客户端流量经由 VPN 出口）。
- 脚本渲染并应用专用 nftables 表 `vpn_node_ocserv`（`ip` 协议族），包含：
  - `_managed_by_vpn_node_maintenance`：空的哨兵链，仅用于标识该表由本工具管理。
  - `forward` 链（`hook forward`，`policy accept`）：仅放行 VPN 网段经出口网卡向外**发起**的流量（`ip saddr <VPN 网段> oifname <出口网卡> accept`）；反向仅放行**已建立/相关**（`ct state established,related`）的回程流量（`ip daddr <VPN 网段> iifname <出口网卡> ct state established,related accept`），即由出口网卡侧**新发起**的连接不会被转发进 VPN 网段。
  - `postrouting` 链（`hook postrouting`，`policy accept`）：对经出口网卡离开的 VPN 网段流量做 `masquerade`。
- 出口网卡通过 `ip -4 route get 1.1.1.1` 在每次 `ocserv-network up`/`down`/`check` 时动态探测，始终跟随当前默认路由。
- **脚本不安装任何 `INPUT` 链或过滤策略**——不会新增、也不会收紧本机现有的入站防火墙规则；对 `OCSERV_PORT` 的入站放行完全依赖操作系统/云平台已有的防火墙或安全组配置。
- `ocserv-network` 只会创建、替换或删除携带哨兵链的 `vpn_node_ocserv` 表；若发现同名但不含哨兵链的表，直接拒绝操作，不做任何修改或删除。

### Azure NSG 要求

`OCSERV_ENDPOINT`/`OCSERV_PORT` 对应的 TCP **和** UDP 必须同时在 Azure 网络安全组（NSG）中放行入站（AnyConnect 协议同时使用两者，UDP 用于 DTLS 数据通道）。仅放行 TCP 会导致连接建立但数据通道回退或体验下降。安装脚本结束时会打印 `Azure NSG required: allow TCP <port> and UDP <port>` 作为提示。

### 开机行为

- 安装成功后执行 `systemctl daemon-reload && systemctl enable ocserv.service && systemctl restart ocserv.service`，因此重启后 `ocserv.service` 会随系统自启动。
- `10-network.conf` drop-in 通过 `ExecStartPre=.../ocserv-network up` 和 `ExecStopPost=.../ocserv-network down` 把 nftables 表的生命周期绑定到 `ocserv.service` 的启动/停止，保证每次开机、重启或手动 `systemctl restart ocserv` 时专用 nftables 表都会重新建立。

### 故障排查

```bash
systemctl status ocserv.service
journalctl -u ocserv.service -e
sudo ss -H -ltnp "sport = :$OCSERV_PORT"
sudo ss -H -lunp "sport = :$OCSERV_PORT"
sudo nft list table ip vpn_node_ocserv
sudo occtl show status
sudo occtl show users
```

- `systemctl status` / `journalctl`：查看服务是否激活、启动失败原因。
- `ss -H -ltnp "sport = :$OCSERV_PORT"` / `ss -H -lunp "sport = :$OCSERV_PORT"`：用精确的 `sport` 过滤器分别确认 TCP 和 UDP 均在 `OCSERV_PORT` 上监听（避免用 `grep` 端口号误匹配到位数相同、包含相同数字的其它端口）。
- `nft list table ip vpn_node_ocserv`：确认哨兵链、`forward`、`postrouting`（含 `masquerade`）规则均存在。
- `occtl`：查看当前连接的用户、流量与会话状态（需要 `use-occtl = true`，脚本已默认开启）。

### 与 SoftEther 共存

在同一台主机上部署 ocserv 与 SoftEther 时，必须为两者预留不同的：

- **端口**：本项目约定 SoftEther 使用 `443`，ocserv 使用 `OCSERV_PORT`（默认 `8443`）；两者不能共用同一 TCP/UDP 端口。
- **地址池**：`OCSERV_IPV4_NETWORK`（默认 `10.66.0.0/24`）必须与 SoftEther 的虚拟 DHCP/地址池网段不重叠，否则 `check_route_overlap` 会在 `install` 时直接拒绝。
- **nftables 表**：ocserv 使用专属表名 `vpn_node_ocserv`，不会触碰其他表；SoftEther 若也使用 nftables/iptables 管理转发规则，应使用不同的表名，避免互相覆盖。

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
- `/etc/ocserv/ocpasswd`、自签名私钥 `/etc/ocserv/ssl/selfsigned-key.pem` 均以 `0600` 安装，不得提交到仓库。
- `selfsigned` 模式下客户端必须使用安装完成时打印的 `pin-sha256` 公钥指纹（`--servercert pin-sha256:...`）连接，不要绕过证书校验。
