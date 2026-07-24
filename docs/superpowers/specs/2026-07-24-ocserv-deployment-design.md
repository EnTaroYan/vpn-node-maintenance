# ocserv 一键部署设计

## 目标

在现有 `vpn-node-maintenance` 项目中增加一个独立的一键部署脚本，为 Ubuntu 22.04 和 24.04 安装并配置 ocserv。部署完成后：

- ocserv 随系统开机自动启动。
- TCP 和 UDP 使用同一个可配置端口，默认 `8443`。
- 客户端使用独立 `ocpasswd` 用户名和密码认证。
- 客户端获得 `10.66.0.0/24` 地址并使用全隧道 IPv4 NAT 上网。
- 支持 Let's Encrypt 和自签名两种服务器证书模式。
- Let's Encrypt 证书路径复用 `/etc/vpn-maintenance.env` 中的 `LE_CONFIG_DIR` 与 `CERT_NAME`。
- 与未来占用 `443` 的 SoftEther 共存，不修改系统 INPUT 默认策略。

## 非目标

首版不实现：

- IPv6 地址池或 IPv6 出口。
- PAM、RADIUS、LDAP 或客户端证书认证。
- 分流路由、伪桥接或局域网二层桥接。
- Azure NSG 或其他云厂商防火墙自动配置。
- SoftEther 安装或配置。
- 容器化部署。
- 自动卸载。

## 支持环境

- Ubuntu 22.04 LTS 或 Ubuntu 24.04 LTS。
- `amd64` 和 `arm64` 架构。
- 使用 Ubuntu 仓库提供的 `ocserv` 软件包，不自行编译。
- 服务器具有可用的默认 IPv4 出口路由。
- Azure 或其他云防火墙由用户开放 `OCSERV_PORT` 的 TCP 和 UDP 入站。

## 文件与职责

### 仓库文件

| 文件 | 职责 |
|---|---|
| `ocserv-deploy.sh` | 安装、配置和用户管理入口 |
| `vpn-maintenance.env.example` | DDNS、证书和 ocserv 的共享配置模板 |
| `README.md` | 安装、配置、运行和故障排查说明 |

### 部署生成文件

| 路径 | 职责 |
|---|---|
| `/etc/ocserv/ocserv.conf` | 带管理标记的 ocserv 配置 |
| `/etc/ocserv/ocpasswd` | 独立 VPN 用户密码库 |
| `/etc/ocserv/ssl/selfsigned-cert.pem` | 自签名模式服务器证书 |
| `/etc/ocserv/ssl/selfsigned-key.pem` | 自签名模式私钥 |
| `/usr/local/libexec/vpn-node/ocserv-network` | ocserv 启停时管理 IPv4 转发和专用 nftables 表 |
| `/etc/systemd/system/ocserv.service.d/10-network.conf` | 把网络 helper 接入发行版 `ocserv.service` |
| `/etc/letsencrypt/renewal-hooks/deploy/20-ocserv` | Let's Encrypt 续签成功后让 ocserv 热加载证书 |

不直接修改 Ubuntu 软件包提供的 systemd unit。

## 共享配置

`vpn-maintenance.env.example` 增加：

```bash
# OpenConnect / ocserv settings.
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=(
  "8.8.4.4"
)

# Allowed values: letsencrypt | selfsigned
OCSERV_CERT_MODE="letsencrypt"
```

字段语义：

- `OCSERV_ENDPOINT` 可以是合法 DNS 名称或 IPv4 地址，用于连接提示和证书身份校验。
- `OCSERV_PORT` 必须是 `1..65535`。允许配置 `443`，但安装前必须检查端口是否已被其他进程占用。
- `OCSERV_IPV4_NETWORK` 首版固定要求 IPv4 `/24` 网络；默认 `10.66.0.0/24`，不得与服务器现有路由或其他 VPN 地址池重叠。
- `OCSERV_DNS` 至少包含一个合法 IPv4 DNS 地址。
- `OCSERV_CERT_MODE` 仅允许 `letsencrypt` 或 `selfsigned`。

配置文件继续要求 root 所有、权限 `0600` 或 `0400`，且不能是符号链接。

## 命令接口

```text
sudo ./ocserv-deploy.sh install
sudo ./ocserv-deploy.sh add-user [USERNAME]
sudo ./ocserv-deploy.sh del-user [USERNAME]
sudo ./ocserv-deploy.sh help
```

### `install`

完成包安装、证书选择、配置生成、网络接入、首个用户创建和服务启动。

### `add-user`

- 未提供用户名时交互输入。
- 用户名只允许安全的有限字符集，并拒绝空值或选项注入。
- 密码隐藏输入并要求确认。
- 密码通过标准输入传给 `ocpasswd`，不得出现在命令参数、进程列表或日志中。

### `del-user`

- 未提供用户名时交互输入。
- 验证用户存在后调用 `ocpasswd -d`。
- 不删除密码库或其他用户。

## 安装流程

`install` 按以下顺序执行：

1. 获取独占安装锁并确认以 root 运行。
2. 校验 Ubuntu 版本、共享 env 的所有权与权限，以及所有 ocserv 配置字段。
3. 记录调用前是否已存在 `/etc/ocserv/ocserv.conf`。
4. 检查地址池是否与主机现有 IPv4 路由重叠。
5. 检查目标 TCP/UDP 端口：
   - 新安装时，任何占用都导致停止。
   - 更新受管安装时，只允许当前 ocserv 自身占用原端口。
6. `apt-get update` 并安装 `ocserv`、`nftables`、`openssl` 及运行所需基础包。
7. 选择并验证服务器证书。
8. 渲染临时 ocserv 配置、网络 helper、systemd drop-in 和可选 Certbot hook。
9. 使用 `ocserv -c "$TEMP_CONF" --test-config` 检查临时配置。
10. 调用 `ocserv-network check`，使用当前默认出口和 nftables check 模式验证渲染后的网络规则，但不应用规则。
11. 原子安装生成文件并执行 `systemctl daemon-reload`。
12. 密码库为空时，在激活新配置前交互创建首个用户；已有用户时保留密码库。用户取消或创建失败时恢复本次调用前的文件状态。
13. 执行 `systemctl enable ocserv.service`，再 restart 服务，使首次安装和配置更新都立即生效。
14. 确认服务处于 active 状态并确认配置端口正在监听。
15. 输出客户端连接地址、Azure NSG 提示和证书信息。

## 证书设计

ocserv 的 TLS 控制通道始终需要服务器证书；“不使用 Let's Encrypt”对应自签名模式，而不是真正无证书。

### Let's Encrypt 模式

从共享 env 派生：

```bash
CERT_LIVE_DIR="${LE_CONFIG_DIR:-/etc/letsencrypt}/live/${CERT_NAME}"
CERT_FULLCHAIN_FILE="${CERT_LIVE_DIR}/fullchain.pem"
CERT_PRIVATE_KEY_FILE="${CERT_LIVE_DIR}/privkey.pem"
```

安装器必须：

- 要求两个文件已经存在；缺失时明确报错并提示先运行 `vpn-maintenance.sh issue-cert`，不自动签发。
- 验证证书当前有效。
- 验证证书公钥与私钥匹配。
- 当 endpoint 是 DNS 名称时，使用证书主机名校验确认 SAN 匹配，包括合法通配符。
- 当 endpoint 是 IPv4 时，要求证书具有匹配的 IP SAN；域名证书不能用于裸 IP 连接。
- 直接把稳定的 Certbot `live/` 路径写入 `ocserv.conf`，不复制私钥。

deploy hook 使用 Bash，因为共享 env 包含 Bash 数组。它读取同一个 env，确认 `RENEWED_LINEAGE` 等于派生目录后，执行 `systemctl reload ocserv.service`，由发行版 unit 的 `ExecReload` 向 systemd 跟踪的主进程发送 `SIGHUP`。Certbot 原子更新 `live/` 软链接，因此续签无需重写 ocserv 配置。

### 自签名模式

- 使用 OpenSSL 生成无密码 RSA 3072 位私钥和 SHA-256 自签名服务器证书。
- DNS endpoint 写入 DNS SAN；IPv4 endpoint 写入 IP SAN。
- 默认有效期十年。
- 私钥权限为 `0600`，证书权限为 `0644`，目录仅允许 root 写入。
- 重复安装时复用现有自签名证书；若 SAN 与当前 endpoint 不匹配则停止，不静默覆盖。
- 安装完成后输出 SHA-256 证书指纹，供客户端固定或人工确认。
- 自签名模式不安装 Certbot deploy hook；从 Let's Encrypt 切换到自签名时，删除且仅删除带脚本管理标记的旧 ocserv hook。

## ocserv 配置

生成配置至少包含：

- `auth = "plain[/etc/ocserv/ocpasswd]"`。
- `tcp-port` 和 `udp-port` 均使用 `OCSERV_PORT`。
- `server-cert` 与 `server-key` 使用所选证书路径。
- `device = vpns`。
- IPv4 网络与掩码从 `OCSERV_IPV4_NETWORK` 派生；默认分别为 `10.66.0.0` 和 `255.255.255.0`。
- `route = default`，向客户端下发全隧道路由。
- 每个 `OCSERV_DNS` 项生成一个 `dns` 配置。
- 启用 Cisco AnyConnect/OpenConnect 客户端兼容配置。
- 使用安全的 TLS 默认值，禁用旧版 SSL/TLS。
- 设置合理的连接数、同用户连接数、DPD、空闲超时和日志级别。

配置首行加入稳定管理标记：

```text
# Managed by vpn-node-maintenance: ocserv-deploy.sh
```

## 网络与 NAT

不启用主机入站防火墙，也不设置 INPUT 规则或默认 DROP 策略。外部端口访问由 Azure NSG 或其他云防火墙控制。

网络 helper 提供 `check`、`up`、`down` 三个子命令。`check` 与 `up` 都在调用时通过默认 IPv4 路由动态识别当前出口接口，并渲染同一份规则；`check` 使用 `nft --check` 只验证语法，`up` 才应用规则。

`ocserv-network up`：

1. 执行 `sysctl -w net.ipv4.ip_forward=1`。
2. 通过默认 IPv4 路由动态识别出口接口。
3. 检查现有 `ip vpn_node_ocserv` 表；只有包含 `_managed_by_vpn_node_maintenance` 哨兵 chain 时才能替换，未知同名表导致启动失败。
4. 删除脚本拥有的旧表，创建同名专用 nftables 表及哨兵 chain。
5. 为 ocserv 地址池到出口及返回方向的 established/related 流量添加转发规则。该表的 FORWARD base chain 必须使用 `policy accept`，不得对非 ocserv 转发流量产生 DROP verdict。
6. 仅对 ocserv 地址池在默认出口执行 masquerade。

`ocserv-network down` 验证哨兵 chain 后只删除 `ip vpn_node_ocserv` 表，不把 `net.ipv4.ip_forward` 改回 `0`，避免影响未来 SoftEther 或其他 VPN。

systemd drop-in：

- 在 `ocserv.service` 启动前执行 `ocserv-network up`。
- 在服务停止后执行 `ocserv-network down`。
- 等待 `network-online.target` 和 `nftables.service`。
- 设置 `PartOf=nftables.service`，使显式 restart nftables 服务时 ocserv 同步重启，并在 nftables 之后恢复专用表。
- 网络 helper 失败时阻止 ocserv 启动，避免出现“VPN 可连接但无法上网”的半成功状态。

网络表名称和地址池专属于 ocserv，未来 SoftEther 使用不同地址池和表名。

## 幂等性与已有配置

- 首次调用前不存在 `ocserv.conf` 时，可以替换软件包安装过程生成的默认配置。
- 调用前已存在且包含管理标记时，视为受管安装，可以安全更新。
- 调用前已存在但没有管理标记时，创建时间戳备份并停止；不得覆盖未知或人工配置。
- 所有配置先写入同目录临时文件，通过验证后使用 `install`/原子替换。
- 更新时保留 `/etc/ocserv/ocpasswd`。
- 安装前记录所有受管配置、helper、drop-in 和 hook 的状态；若配置检查或服务启动失败，按文件恢复本次调用前的状态并再次加载 systemd。软件包安装本身不回滚。
- `ERR`、`INT` 和 `TERM` 信号使用同一个幂等回滚函数；用户在密码输入阶段取消也不得留下半激活配置。
- 脚本只删除明确拥有的 nftables 表和临时文件。

## 错误处理与安全

- 使用 `set -Eeuo pipefail`，错误立即失败。
- 不使用宽泛的成功回退，不吞掉包管理、证书、配置、nftables 或 systemd 错误。
- API Token、证书私钥和用户密码不得写入日志。
- 不通过命令参数传递 VPN 用户密码。
- 私钥和密码库保持 root-only。
- endpoint、用户名、端口、CIDR、DNS 和接口名必须先验证再进入生成文件或命令。
- 只允许操作明确的绝对路径，不递归删除配置根目录。
- 成功消息只能在配置检查、服务 active 和端口监听全部成立后输出。

## 测试设计

### 自动化 Shell 测试

使用临时目录和命令 mock，不接触真实系统配置，覆盖：

- Ubuntu 22.04/24.04 接受及其他系统拒绝。
- 默认配置和自定义端口渲染。
- 域名 endpoint、IPv4 endpoint 与非法值。
- Let's Encrypt 文件缺失、密钥不匹配、SAN 不匹配及成功路径。
- 自签名 DNS SAN 与 IP SAN 生成。
- 两种证书模式产生正确的 hook 行为。
- 首个用户创建、密码确认失败、添加和删除用户。
- 未知配置备份后停止。
- 受管配置重复安装并保留密码库。
- 端口被其他进程占用。
- 网络规则只包含所选地址池与动态出口接口。
- 配置检查或服务启动失败时恢复旧配置。

### 目标机验证

在 Ubuntu 24.04 ARM64 目标机上执行：

- `bash -n ocserv-deploy.sh`。
- `ocserv -c /etc/ocserv/ocserv.conf --test-config`。
- nftables check 模式。
- `systemctl is-enabled ocserv.service`。
- `systemctl is-active ocserv.service`。
- 检查配置端口的 TCP 和 UDP 监听。
- 使用测试账户从 OpenConnect 客户端登录。
- 验证客户端公网出口为服务器公网地址。
- 在 Let's Encrypt 模式下模拟 deploy hook 并确认 ocserv 重载。

## 成功标准

1. 用户只需准备共享 env、选择有效证书模式并运行 `install`。
2. 主机内部不再需要手动配置 ocserv、IP 转发或 NAT。
3. 重启服务器后 ocserv 和所需网络规则自动恢复。
4. OpenConnect/AnyConnect 客户端可以通过 `OCSERV_ENDPOINT:OCSERV_PORT` 登录并访问互联网。
5. Let's Encrypt 续签后 ocserv 无需改路径即可加载新证书。
6. SoftEther 后续可以使用 `443` 和独立地址池，不与 ocserv 配置互相覆盖。
