# ImmortalWrt 双栈公网入口设计

## 目标

ImmortalWrt 每次开机及 WAN 变化后检测公网 IPv4/IPv6，为 DDNS、WireGuard 与公网 LuCI 提供双栈入口。两种地址同时可用时发布 A+AAAA并开放双栈，由客户端选择；无域名时 WireGuard模板优先使用公网IPv4，否则使用IPv6。

## 检测

新增 `vpn-node-ingress` procd服务、hotplug和5分钟定时任务，使用锁与debounce。

- IPv4：从可用 PPPoE/DHCP逻辑接口取得地址；排除私网、100.64/10和保留地址；通过至少一个外部IPv4观察服务验证观察IP等于接口IP。观察服务不可用为 unknown，不误删DNS。
- IPv6：选择有默认路由的稳定GUA；排除 temporary、tentative、deprecated、ULA和link-local。
- 状态写入 `/var/run/vpn-node/ingress.env`，包含地址、available/unknown状态、优选族和时间。
- 检测失败不影响 netifd、PPPoE或DHCP。

## DDNS

同一 `HOME_DOMAIN` 同步 Cloudflare DNS-only A和AAAA。

- 明确可用时创建/更新，并写 `managed-by=vpn-node` comment。
- 明确不可用时仅删除带该comment的对应记录。
- unknown时保留现有记录并重试。
- 同类型出现多个记录时只操作受管记录；歧义时失败并记录日志。

## 服务

- WireGuard继续使用同一接口/UDP端口，fw4以 `family any` 开放；内层仍仅IPv4。
- 有域名时模板使用域名；无域名时优先IPv4字面量，否则括号IPv6。
- 公网LuCI独立uhttpd同时监听 `0.0.0.0:PORT` 与 `[::]:PORT`，fw4双栈开放。
- DNS-01域名证书与地址族无关；A/AAAA变化无需重签。
- 无域名自签名继续允许浏览器警告访问。

## 安全与测试

Cloudflare token保持root-only。测试使用mock ubus/ip/curl/Cloudflare，不修改真实网络或DNS。覆盖公网/私网/CGNAT IPv4、稳定/临时IPv6、双栈/单栈/unknown、A/AAAA生命周期、hotplug/cron锁、WG模板及LuCI双栈监听。
