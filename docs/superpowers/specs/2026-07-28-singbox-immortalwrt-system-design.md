# sing-box + ImmortalWrt 家庭网络系统设计

## 目标

构建一套由海外 VPS 与家中 ImmortalWrt 组成的双端系统：

- Hysteria2 + Salamander 作为默认高速代理链路。
- VLESS + REALITY + Vision 作为 LuCI 手动切换的 TCP 备用链路。
- 保留现有 ocserv 作为独立应急协议。
- 家中 LAN 与远程 WireGuard 客户端按 GFWList 分流。
- 第二个 WireGuard 入口强制全局走 VPS。
- 家宽没有公网 IPv4时，通过动态公网 IPv6提供 WireGuard与LuCI入站。
- IPv6仅用于 WireGuard外层和LuCI入站；其他流量均为 IPv4。
- 支持裸 ImmortalWrt 上 DHCP或 PPPoE优先、DHCP后备的网络配置。

## 仓库结构

现有根目录脚本移动到 `server/`，根目录不保留包装脚本或符号链接：

```text
server/
├─ sing-box-deploy.sh
├─ sing-box.env.example
├─ vpn-maintenance.sh
├─ vpn-maintenance.env.example
├─ vpn-ddns.service
├─ vpn-ddns.timer
└─ ocserv-deploy.sh

client/
├─ immortalwrt-deploy.sh
└─ immortalwrt.env.example

tests/
├─ server/
│  ├─ ocserv-deploy-test.sh
│  └─ sing-box-deploy-test.sh
├─ client/
│  └─ immortalwrt-deploy-test.sh
└─ testlib.sh
```

README及所有测试、计划和服务安装命令使用新路径。

## VPS设计

### 独立脚本

服务器功能分开执行：

- `server/vpn-maintenance.sh`：可选 DDNS及证书签发/续签。
- `server/sing-box-deploy.sh`：仅部署 sing-box 双协议。
- `server/ocserv-deploy.sh`：独立部署/维护 ocserv。

sing-box脚本不得自动调用另外两个脚本。

### sing-box入站

单个 sing-box进程：

```text
UDP 443  Hysteria2 + Salamander
TCP 443  VLESS + REALITY + Vision
TCP/UDP 58443  ocserv（独立进程）
```

TCP与UDP可使用相同端口号，不冲突。

Hysteria2支持可选 `server_ports`范围和 nftables UDP DNAT端口跳跃；未配置范围时只开放 UDP 443。

### 证书

`server/sing-box.env`：

- `HY2_CERT_MODE=letsencrypt`：只读取已有证书，缺失则失败。
- `HY2_CERT_MODE=selfsigned`：生成绑定 VPS IPv4 SAN的证书，并输出公钥 pin；客户端不得使用 `insecure=true`。

REALITY不依赖自有域名或证书。客户端可使用 VPS IPv4字面量。

### 密钥与输出

env中密码/密钥字段为空时，部署脚本生成：

- HY2用户密码
- Salamander密码
- VLESS UUID
- REALITY私钥/公钥
- REALITY short ID

生成值写入 root-only状态文件。部署完成后生成 root-only客户端参数文件，用户手工复制到 `client/immortalwrt.env`。

### 资源

- ARM双核1GB可运行 sing-box与现有 ocserv。
- 不使用 Docker或管理面板。
- 日志级别默认 `warn`。
- 建议 512MB swap；脚本可选创建，不覆盖已有 swap。
- systemd启用自动重启。

## ImmortalWrt地址规划

```text
LAN          10.192.0.0/24    路由器 10.192.0.1
预留         10.192.10.0/24
预留         10.192.20.0/24
wg-global    10.192.100.0/24  路由器 10.192.100.1
wg-local     10.192.200.0/24  路由器 10.192.200.1
```

HY2和REALITY是代理协议，`redirect_tproxy`模式不为其创建虚拟网卡；10.192.10/20仅预留。

## ImmortalWrt安装输入

除网卡外，用户先编辑 root-only `client/immortalwrt.env`。

安装时交互列出物理网卡，并分别选择 WAN与LAN设备。脚本必须拒绝：

- 相同WAN/LAN设备
- 不存在设备
- loopback、bridge、tun、WireGuard等非物理设备

## WAN逻辑

### 无PPPoE账号

只创建 DHCP逻辑WAN。

### 有PPPoE账号

同一物理WAN设备同时创建：

- PPPoE逻辑接口，较低 metric，优先默认路由。
- DHCP逻辑接口，较高 metric，作为后备。

安装器不等待或判断PPPoE/DHCP是否成功，不因联网失败回滚。

为两个可能的WAN路径创建相应 DHCPv6-PD逻辑接口；实际可用路径由 netifd路由与接口状态决定。

防火墙、DDNS与其他服务引用逻辑接口/zone，不写死 `eth0` 或 `pppoe-wan`。

脚本自身写入、UCI解析或模板验证失败时恢复修改前配置；联网失败不触发恢复。

## IPv4/IPv6边界

- LAN不发布IPv6 RA/DHCPv6。
- dnsmasq过滤AAAA。
- HomeProxy设置 `ipv6_support=0`。
- 家中到VPS强制 IPv4。
- 代理出口只处理 IPv4。
- WAN6仅提供：
  - WireGuard IPv6入站
  - LuCI IPv6入站

没有公网IPv6或远端客户端没有IPv6时，WireGuard/LuCI公网入口不可用。

## HomeProxy

### 工作模式

- `proxy_mode=redirect_tproxy`
- `routing_mode=gfwlist`
- IPv4-only
- `main_node=HY2` 默认
- 用户在 LuCI手动切换 HY2或REALITY
- 不部署自动 watchdog

HomeProxy官方 `main_node`支持直接选择节点或 URLTest；本设计只使用直接节点选择。

### 规则优先级

```text
1. 私网、路由器管理地址、VPS endpoint  → 直连
2. 手工代理域名/IP                     → 代理
3. 手工直连域名/IP                     → 直连
4. 来源 10.192.100.0/24（wg-global）    → 其余全部代理
5. 自动 GFW 域名与动态解析IP           → 代理
6. 未命中                              → 家宽直连
```

LAN与 `wg-local` 使用第1、2、3、5、6条；未命中直连。

### 自动规则

使用 HomeProxy内建资源更新：

- `Loyalsoldier/v2ray-rules-dat` 的 `gfw.txt`
- dnsmasq为GFW域名使用干净代理DNS
- 解析结果动态写入 `homeproxy_gfw_list_v4`

不能只使用静态被墙IP表，因为 CDN共享IP、DNS污染与IP变化会造成误判。

自动更新使用 HomeProxy cron。手工代理与手工直连列表在 LuCI维护，并位于自动规则之前。

## DNS

- LAN与两个WireGuard客户端的DNS均指向 ImmortalWrt。
- GFW域名通过 HomeProxy代理DNS解析。
- 其他域名使用本地/运营商或用户指定国内DNS。
- dnsmasq过滤AAAA与HTTPS/SVCB中可能触发IPv6/QUIC绕过的记录，具体以当前HomeProxy支持项为准。

## WireGuard

两个接口监听不同UDP端口：

- `wg-global`：10.192.100.1/24
- `wg-local`：10.192.200.1/24

外层：

- Endpoint为家中公网IPv6或动态AAAA。
- 仅通过WAN6防火墙开放。

内层：

- 仅IPv4。
- 客户端 `AllowedIPs=0.0.0.0/0`。
- MTU默认1380。
- NAT侧peer建议 `PersistentKeepalive=25`。
- 两个配置不能同时启用。

同一WireGuard接口内peer使用唯一 `/32` AllowedIPs，并允许peer-to-peer forwarding；可通过IPv4直接联机。不提供二层广播发现。

## 家中IPv6 DDNS

`HOME_DOMAIN`和Cloudflare凭据可选：

- 配置时，从当前可用WAN6逻辑接口选择全局IPv6，更新 DNS-only AAAA。
- 由 hotplug与定时任务触发。
- 不发布隐私临时地址；优先稳定地址。

无域名时不配置DDNS，用户使用当前IPv6字面量。

## 公网LuCI

- 单独 uhttpd实例。
- IPv6-only HTTPS监听 `[::]:${LUCI_PUBLIC_PORT}`，默认10443。
- 与LAN管理实例分离。
- 有域名时可使用DNS-01证书。
- 无域名时使用自签名证书，用户接受浏览器警告。
- fw4仅在WAN6开放该TCP端口。
- root密码必须由用户设置为强且唯一。
- uhttpd没有可靠的登录失败次数锁定；非标准端口只减少噪声，不是安全边界。

## 防火墙

- LAN zone包含LAN及两个WireGuard逻辑接口所需转发关系。
- WAN zone包含 DHCP/PPPoE及对应WAN6逻辑接口。
- 只开放：
  - 两个WireGuard IPv6 UDP端口
  - LuCI IPv6 TCP端口
- HomeProxy使用 fw4/nftables。
- 不创建重复iptables规则。

## 客户端安装行为

`client/immortalwrt-deploy.sh` 假设裸 ImmortalWrt：

1. 校验env权限与字段。
2. 交互选择WAN/LAN物理网卡。
3. 安装必要包。
4. 备份 network/firewall/dhcp/uhttpd/homeproxy/ddns/acme配置。
5. 使用UCI批量生成配置。
6. 执行 UCI、脚本和 sing-box/HomeProxy生成配置的静态验证。
7. 提交并重载服务。
8. LAN地址变化后提示用户重新连接 10.192.0.1。

PPPoE/DHCP连通性不属于安装成功判定。

## 测试

### 仓库迁移

- 所有旧根目录脚本移动到server。
- README、systemd source路径、测试路径全部更新。
- 根目录不存在旧脚本。

### VPS

- 两种证书模式
- 密钥生成/复用
- HY2与REALITY配置
- 端口冲突
- nftables端口跳跃
- systemd启停与回滚
- 不自动调用可选脚本

### ImmortalWrt

在临时root中mock `uci`、`ubus`、`opkg/apk`、`ip`、`service`：

- 物理网卡选择
- DHCP-only
- PPPoE优先+DHCP后备
- 不因WAN失败回滚
- LAN/WG网段生成
- GFWList与手工优先级
- wg-global/wg-local差异
- IPv4-only与AAAA过滤
- DDNS有/无域名
- LuCI有/无域名
- 配置写入失败回滚

测试不得修改真实VPS服务、ImmortalWrt配置或主机防火墙。

## 已知边界

- 单VPS IP被封时，HY2、REALITY与ocserv同时受影响。
- 无协议保证长期绕过封锁。
- Hysteria2可能受跨境UDP QoS或整体封锁。
- 公网LuCI存在完整root管理面风险。
- 远端无IPv6时无法使用家中WireGuard/LuCI入口。
