# VPN Node Maintenance

海外 VPS（ocserv + sing-box）与家中 ImmortalWrt（网络 + WireGuard + HomeProxy）
两端相互独立的部署脚本集合。服务器与客户端可以分别安装、分别验证；客户端仅在
需要 HomeProxy 代理时才依赖服务器生成的参数，其余功能（LAN/PPPoE/DHCP/
WireGuard/公网 LuCI）与服务器完全无关。

## ⚠️ 安装前必读

- **裸 ImmortalWrt 上执行 `client/immortalwrt-deploy.sh install` 会立即把 LAN
  地址改为 `LAN_ADDRESS`（默认 `10.192.0.1/24`）。** 当前通过默认 LAN
  （通常 `192.168.1.1`）管理路由器的连接会断开；安装完成后请改用新地址
  （默认 `10.192.0.1`）重新连接管理界面。安装器不会为此回滚。
- **公网 LuCI（`LUCI_PUBLIC_PORT`，默认 10443）会把完整的 root 管理面暴露在
  公网 IPv6 上。** 非标准端口只是减少扫描噪声，不是安全边界；`uhttpd`
  没有登录失败次数锁定。开启前必须把 LuCI/root 密码设置为强且唯一的密码，
  并清楚这是可接受的风险后再启用。
- WAN 的 PPPoE/DHCP 拨号成功与否**不参与安装成功判定**：脚本不等待、不检测
  联网结果，也不会因为联不通网而回滚已写入的配置（回滚仅在脚本自身的写入、
  UCI 解析或渲染校验失败时触发）。
- 两个 WireGuard 接口（`wg-global`、`wg-local`）服务端会同时渲染并监听；但
  **同一台远程客户端设备应当只启用其中一个 profile 的隧道**，不要在同一台
  设备上同时激活 wg-global 和 wg-local，两者的 `AllowedIPs=0.0.0.0/0`
  会互相冲突路由。

## 已测试环境

- **服务器**（`server/`）：仅在 Ubuntu amd64 和 arm64 上完成测试。其他提供
  apt、systemd、ocserv/sing-box 和 nftables 的平台可能兼容，但未经验证；
  脚本不会按发行版、版本或 CPU 架构提前拒绝安装。
- **客户端**（`client/`）：`tests/client/immortalwrt-deploy-test.sh` 在临时
  root 中用桩程序模拟 `uci`、`ubus`、`opkg`/`apk`、`ip`、`service`，验证渲染
  的 UCI 配置和脚本逻辑；未在真实 ImmortalWrt/OpenWrt 硬件上做过端到端安装
  验证，安装前建议先在测试路由器或备用设备上试运行。

## 仓库结构

| 路径 | 用途 |
|---|---|
| `server/vpn-maintenance.sh` | DDNS、初始证书签发和手动续签检查（可选） |
| `server/vpn-maintenance.env.example` | `vpn-maintenance.sh` 配置模板 |
| `server/vpn-ddns.service` / `server/vpn-ddns.timer` | systemd DDNS oneshot service / 定时器（每 5 分钟） |
| `server/ocserv-deploy.sh` | ocserv（OpenConnect/AnyConnect）一键安装、用户管理，独立保留 |
| `server/sing-box-deploy.sh` | sing-box 双协议（Hysteria2 + VLESS REALITY）一键安装 |
| `server/sing-box.env.example` | `sing-box-deploy.sh` 配置模板 |
| `client/immortalwrt-deploy.sh` | ImmortalWrt 基础网络 + WireGuard + HomeProxy + DDNS + 公网 LuCI 一键安装 |
| `client/immortalwrt.env.example` | `immortalwrt-deploy.sh` 配置模板 |
| `tests/server/ocserv-deploy-test.sh` | `server/ocserv-deploy.sh` 的 Bash 测试套件 |
| `tests/server/sing-box-deploy-test.sh` | `server/sing-box-deploy.sh` 的 Bash 测试套件 |
| `tests/client/immortalwrt-deploy-test.sh` | `client/immortalwrt-deploy.sh` 的 Bash 测试套件 |
| `tests/testlib.sh` | 三个测试套件共用的断言辅助函数 |

根目录不再保留旧脚本、包装脚本或符号链接；所有安装、systemd `ExecStart` 和
测试都使用上表中的新路径。

## 服务器（VPS）部署

三个服务器脚本相互独立执行，**互不自动调用**：

- `server/vpn-maintenance.sh`：可选的 DDNS 和 Let's Encrypt 证书签发/续签。
- `server/sing-box-deploy.sh`：仅部署 sing-box（Hysteria2 + VLESS REALITY）。
- `server/ocserv-deploy.sh`：独立部署/维护 ocserv，与 sing-box 使用不同端口。

### 准备

```bash
sudo install -m 0755 server/vpn-maintenance.sh /usr/local/sbin/vpn-maintenance.sh
sudo install -m 0644 server/vpn-ddns.service server/vpn-ddns.timer /etc/systemd/system/
sudo install -m 0600 server/vpn-maintenance.env.example /etc/vpn-maintenance.env
sudo -e /etc/vpn-maintenance.env
```

已有 `/etc/vpn-maintenance.env` 时，增量追加新变量，不要整个文件覆盖。

### 1. DDNS（可选）

仅在公网 IP 不固定且需要通过域名追踪节点时执行；不需要域名时可跳过本步骤，
直接使用当前公网 IPv4 字面量作为客户端 endpoint。

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

### 2. Let's Encrypt 证书（可选）

此步骤可选；ocserv 使用 `OCSERV_CERT_MODE="selfsigned"`、sing-box 使用
`HY2_CERT_MODE="selfsigned"` 时都可以跳过，无需域名和 Cloudflare、也不安装
证书续签 hook。

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

### 3. sing-box（Hysteria2 + VLESS REALITY）部署

```bash
sudo install -d -m 0700 /etc/vpn-node
sudo install -m 0600 server/sing-box.env.example /etc/vpn-node/sing-box.env
sudo chown root:root /etc/vpn-node/sing-box.env
sudo -e /etc/vpn-node/sing-box.env
```

必填/关键变量：

| 变量 | 说明 |
|---|---|
| `SERVER_IPV4` | VPS 公网 IPv4，作为 Hysteria2 自签证书 SAN 和客户端连接地址 |
| `REALITY_TARGET` | REALITY 借用握手的真实站点（如 `www.microsoft.com`），无需自有域名/证书 |
| `HY2_PORT` / `HY2_PORTS` | Hysteria2 UDP 端口，可选 `START:END` 端口跳跃范围（留空则只开放 `HY2_PORT`） |
| `HY2_CERT_MODE` | `letsencrypt`（读取已有证书，缺失即失败）或 `selfsigned`（默认，生成绑定 `SERVER_IPV4` 的证书） |
| `REALITY_PORT` | VLESS + REALITY 的 TCP 端口，可与 `HY2_PORT` 相同数字（TCP/UDP 不冲突） |
| 密码/密钥字段 | 留空由安装器自动生成并持久化到 `/etc/vpn-node/sing-box-state.env`（0600），重复运行保持不变 |

```bash
sudo ./server/sing-box-deploy.sh install
sudo ./server/sing-box-deploy.sh check         # 只校验渲染结果，不做任何修改
sudo ./server/sing-box-deploy.sh show-client   # 打印客户端参数
```

`install` 生成 `/etc/sing-box/config.json`、`/etc/vpn-node/sing-box-state.env`
（持久化的密钥）、`/etc/vpn-node/sing-box-client.env`（root-only 客户端参数
文件）和 `sing-box.service`。**`show-client` 打印的内容需要手工复制到
`client/immortalwrt.env` 对应字段**（字段名不完全一致，映射关系见
`client/immortalwrt.env.example` 顶部的对照表），安装脚本不会替你传输这份
文件，也不会互相调用。`selfsigned` 模式下，服务端会把完整自签证书以
`HY2_CERT_PEM_B64`（base64 PEM）写入客户端参数文件，客户端脚本会解码并写入
`/etc/homeproxy/certs/hy2-server.pem`（0644）后信任该证书，同时打印
`pin-sha256` 仅供人工核对，两端都不会使用 `insecure=true`。

### 4. OpenConnect / ocserv 部署（独立保留）

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

ocserv 与 sing-box 使用不同端口、不同 nftables 表，二者互不影响，可以同时
在同一台 VPS 上运行。Azure 或云平台防火墙须同时放行 `OCSERV_PORT` 的 TCP 和
UDP 入站（sing-box 的 `HY2_PORT`/`REALITY_PORT` 同理）。

固定 IP/域名且使用 `selfsigned` 模式时可跳过步骤 1 和 2，直接执行本步骤或
上一步骤。

### 服务器状态检查

```bash
systemctl status vpn-ddns.timer certbot.timer ocserv.service sing-box.service
sudo journalctl -u vpn-ddns.service -u ocserv.service -u sing-box.service -e
PORT=8443  # replace with your OCSERV_PORT
sudo ss -H -ltnp "sport = :${PORT}"
sudo ss -H -lunp "sport = :${PORT}"
sudo nft list table ip vpn_node_ocserv
```

## 客户端（家中 ImmortalWrt）部署

`client/immortalwrt-deploy.sh` 假设一台**裸 ImmortalWrt**（除物理网卡外，
LAN/WAN/WireGuard/HomeProxy 均未配置）。安装前先编辑 root-only 的
`/etc/vpn-node/immortalwrt.env`；WAN/LAN 物理网卡不写在 env 里，安装时交互
选择。

```bash
install -d -m 0700 /etc/vpn-node
install -m 0600 client/immortalwrt.env.example /etc/vpn-node/immortalwrt.env
chown root:root /etc/vpn-node/immortalwrt.env
vi /etc/vpn-node/immortalwrt.env

./client/immortalwrt-deploy.sh install         # 交互选择 WAN/LAN 网卡后安装
./client/immortalwrt-deploy.sh check           # 只渲染并校验，不修改任何实机配置
./client/immortalwrt-deploy.sh show-wireguard  # 打印服务端公钥和客户端模板
```

安装时交互列出 `/sys/class/net` 下的物理网卡，供分别选择 WAN 和 LAN；脚本会
拒绝：相同的 WAN/LAN 选择、不存在的设备，以及 loopback、bridge、tun、
WireGuard 等非物理设备。选错网卡会在配置阶段直接失败，不会误将虚拟接口用作
WAN/LAN。

### LAN

`LAN_ADDRESS`（默认 `10.192.0.1/24`）替换路由器原有 LAN 地址；LAN 上关闭
IPv6 RA/DHCPv6 广播，dnsmasq 过滤 AAAA 应答（家中到 VPS 及代理出口强制走
IPv4；公网 IPv6 仅用于 WireGuard/公网 LuCI 的双栈入站之一）。**安装后必须改用新
LAN 地址重新连接管理界面**（见上方"安装前必读"）。

### WAN：PPPoE 与 DHCP 同时下发

- `PPPOE_USERNAME`/`PPPOE_PASSWORD` 都留空：只创建 DHCP 逻辑 WAN 接口。
- 两者都填写：在**同一块物理 WAN 网卡**上同时创建 PPPoE 逻辑接口（较低
  metric，`PPPOE_METRIC` 默认 10，优先作为默认路由）和 DHCP 逻辑接口（较高
  metric，`DHCP_METRIC` 默认 20，作为后备）；两个逻辑接口的 DHCPv6-PD 也会
  一并创建，最终生效哪一条路径由 netifd 路由状态决定。
- **⚠️ 同一物理网卡上 PPPoE 与 DHCP 双拨的行为高度依赖具体 ISP 与 netifd/固件
  版本，目前仅通过渲染测试验证 UCI 配置，尚未在真实 ImmortalWrt/OpenWrt 硬件上
  端到端验证；上生产前必须在目标硬件上实测两条逻辑接口的拨号、路由 metric 生效
  与故障切换。由于安装器不做联网检测、也不会因联网失败回滚（见下条），错误的双拨
  配置不会被自动发现，只能靠硬件实测暴露。**
- 安装器**不等待、不检测 PPPoE 或 DHCP 是否拨号/获取地址成功**，也不会因为
  联网失败回滚已写入的配置；只有安装脚本自身的写入、UCI 解析或渲染校验失败
  时才会恢复安装前的配置。防火墙/DDNS 等其他配置引用的是逻辑接口而非固定的
  `eth0`/`pppoe-wan` 名称。

### WireGuard：两个 profile

| 接口 | 内网地址 | 端口 | 用途 |
|---|---|---|---|
| `wg-global` | `10.192.100.1/24` | `51820` | 客户端流量强制经由 VPS 代理出口（HomeProxy 按来源网段识别） |
| `wg-local` | `10.192.200.1/24` | `51821` | 按 GFWList 分流（与 LAN 同策略），适合仅需访问家中局域网设备（例如局域网内游戏主机/NAS）的场景 |

- **外层**（WireGuard UDP 监听）由 fw4 以 `family any` 双栈开放，可经由**家中
  公网 IPv4 或公网 IPv6**入站（两者任一可用即可，客户端自行选择）；两者都没有
  时这两个入口才不可用。`WG_ENDPOINT_HOST` 留空时，模板依次取：DDNS `HOME_DOMAIN`
  （其 A+AAAA 同时覆盖双栈）→ 入口探测器记录的优选公网字面量（公网 IPv4 优先，
  否则全局 IPv6）→ 占位符（需自行填写）。
- **内层**隧道流量仍仅 IPv4（`AllowedIPs=0.0.0.0/0`），因此客户端设备本身不
  需要支持 IPv6 即可通过 wg-local 直接访问家中局域网（含仅支持 IPv4 的
  游戏主机等设备）；MTU 默认 `1380`，为外层 IPv6 报头留出余量。
- 密钥缺失时自动生成并持久化；对端使用 `/32` AllowedIPs，允许 peer 之间和
  与 LAN 互访；客户端模板为 root-only 文件，见 `show-wireguard` 输出。
- **同一台远程设备一次只应启用其中一个 profile**，不要同时激活 wg-global
  和 wg-local 两条隧道（见上方"安装前必读"）。

### HomeProxy（代理客户端）

仅当 `client/immortalwrt.env` 中 `VPS_IPV4` 已填写（即已从服务器
`show-client` 输出复制参数）时才会配置 HomeProxy；留空则只安装基础网络和
WireGuard，不涉及代理。

- 模式：`proxy_mode=redirect_tproxy`、`routing_mode=gfwlist`、
  `ipv6_support=0`（代理出口 IPv4-only）。
- 默认主节点 `main_node` 为 Hysteria2（HY2，高速默认链路）；**REALITY
  （VLESS + REALITY + Vision）作为手动切换的 TCP 备用链路，需要在 LuCI
  的 HomeProxy 页面手动将 main_node 切换为 REALITY 节点**，脚本不会自动
  切换、也不部署自动故障切换/watchdog。
- GFWList 自动规则：使用 HomeProxy 内建的 `Loyalsoldier/v2ray-rules-dat`
  资源更新（`gfw.txt`），配合 dnsmasq 将命中域名动态写入
  `homeproxy_gfw_list_v4` nftset；资源更新走 HomeProxy 自带 cron
  （`subscription.auto_update=1`），不使用静态被墙 IP 表（避免 CDN 共享 IP、
  DNS 污染和 IP 变化造成误判）。
- **规则优先级**（数字越小越先匹配）：
  1. 私网地址、路由器管理地址、VPS endpoint → 直连
  2. LuCI 中手工维护的代理域名/IP 列表 → 代理
  3. LuCI 中手工维护的直连域名/IP 列表 → 直连
  4. 来源为 `wg-global`（`10.192.100.0/24`）→ 其余流量全部代理
  5. 自动 GFWList 域名与动态解析 IP → 代理
  6. 未命中以上任何规则 → 家宽直连
  - LAN 与 `wg-local` 只经过第 1、2、3、5、6 条（不強制全局代理）。
  - 安装/重装只会 `delete` 并重建脚本自己写入的 `wg-global` 网段这一条
    global-proxy 列表，**LuCI 中手工添加的代理/直连列表会被保留**，不会被
    覆盖或清空。

### 入口探测与可选：家中双栈 DDNS（A + AAAA）

每次开机（procd 服务 `vpn-node-ingress`）、WAN 逻辑接口 `ifup`（hotplug）以及
每 5 分钟（cron）运行 `/usr/libexec/vpn-node/ingress-update`，用锁 + debounce
去抖，探测家中公网入口并写入 `/var/run/vpn-node/ingress.env`（含地址、
available/unknown/unavailable 状态、优选族和时间），供 WireGuard 模板选择使用；
探测失败不影响 netifd、PPPoE 或 DHCP。

- **IPv4**：从 `wan`/`wanpppoe` 逻辑接口取地址，排除私网、CGNAT（100.64/10）和
  保留地址；再经至少一个外部观察服务确认「观察到的 IP == 接口 IP」才判定
  available。观察服务全部不可达或观察值不一致时判为 **unknown**，**不删除**已有
  DNS 记录，等待下次重试。
- **IPv6**：选取带默认路由的稳定全局 GUA，跳过 temporary/deprecated/tentative、
  ULA 和 link-local。

`HOME_DOMAIN`、`CLOUDFLARE_ZONE_ID`、`CLOUDFLARE_API_TOKEN` 三者都填写时，同一
探测器还会以 DNS-only（灰云）方式同步 Cloudflare **A 和 AAAA**：

- 明确 available：创建/更新记录，并写入 `managed-by=vpn-node` comment。
- 明确 unavailable：仅删除带该 comment 的对应记录，不动任何手工/第三方记录。
- unknown：保留现有记录并重试。
- 同类型出现多个受管记录时视为歧义，跳过并记日志。

任一 Cloudflare 变量为空则不做 DNS 同步（探测器仍记录状态，客户端模板改用探测
到的优选公网字面量或占位符）。

### 公网 LuCI（务必先设强密码）

安装会在 `0.0.0.0:${LUCI_PUBLIC_PORT}` 与 `[::]:${LUCI_PUBLIC_PORT}`（默认
`10443`）上开启一个与 LAN 管理界面**分离**的双栈 uhttpd 实例，由单条
`family any` 的 fw4 规则在 WAN 放行这一个 TCP 端口。

- `LUCI_CERT_MODE=selfsigned`（默认）：自签名证书，浏览器会提示不受信任
  警告，属预期行为。
- `LUCI_CERT_MODE=letsencrypt`：使用 ACME + Cloudflare DNS-01 签发证书，
  需要已配置 `HOME_DOMAIN` 及 Cloudflare 凭据；DNS-01 证书与地址族无关，
  A/AAAA 变化无需重签。
- **这是完整的 root 管理面，直接暴露在公网（IPv4/IPv6）上**；非标准端口仅减少
  扫描噪声，不构成安全边界，且 `uhttpd` 没有登录失败次数锁定。启用前务必
  将 LuCI/root 密码设置为强且唯一的密码，并自行评估暴露 root 管理面到公网
  的风险。

### 客户端状态检查

```bash
./client/immortalwrt-deploy.sh show-wireguard
uci show homeproxy
uci show network
cat /var/run/vpn-node/ingress.env
logread | grep vpn-node-ingress
```

## 验证 / 测试

```bash
bash -n server/*.sh client/*.sh
sudo bash tests/server/ocserv-deploy-test.sh
sudo bash tests/server/sing-box-deploy-test.sh
sudo bash tests/client/immortalwrt-deploy-test.sh
git diff --check
```

所有测试套件都在临时目录 / mocked root 中运行，使用桩程序模拟
`uci`/`ubus`/`ip`/`curl`/`service`/`opkg`/`apk`，**不会修改任何真实的 VPS 服务、
ImmortalWrt 配置、Cloudflare DNS 或主机防火墙**；渲染出的入口探测器也仅在临时
根目录（`VPN_NODE_INGRESS_ROOT`）下执行，`check` 子命令同样只在临时目录渲染和
校验，不做任何实机改动。

## 已知边界

- 单个 VPS IP 被封锁时，HY2、REALITY 和 ocserv 会同时受影响（三者共用同一
  出口 IP）；没有协议可以保证长期绕过封锁，Hysteria2 尤其可能受跨境 UDP
  QoS 限速或整体封锁影响。
- 家中既没有可用公网 IPv4（经外部观察确认）也没有稳定公网 IPv6 时，WireGuard
  与公网 LuCI 的公网入口才不可用；两者任一可用即可入站（fw4 以 `family any`
  双栈开放）。外部 IPv4 观察服务不可达时入口状态记为 unknown，此时保留既有 DNS
  记录、不做误删。
- SoftEther 自动部署脚本尚未实现。计划使用 443 端口，并与 ocserv/sing-box
  使用不同端口、地址池和 nftables 表，避免冲突。

## 安全提醒

- Cloudflare 记录须保持 DNS-only（灰云）。
- Token、env 文件、私钥、密码文件须为 root-only，不得提交到 Git。
- `selfsigned` 模式下 sing-box 服务端将完整自签证书以 `HY2_CERT_PEM_B64`
  （base64 PEM）写入客户端 env，客户端解码到
  `/etc/homeproxy/certs/hy2-server.pem` 并信任；同时打印 `pin-sha256`
  供核对，两端都不使用 `insecure=true`。
- DDNS 和证书成功不等于云平台入站端口已放行；请在 Azure NSG（或对应云
  平台防火墙）中同时放行 TCP 和 UDP。
- 公网 LuCI 和裸 ImmortalWrt 安装的 LAN 地址变更风险见上方"安装前必读"。
