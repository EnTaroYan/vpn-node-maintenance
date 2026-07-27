# sing-box + ImmortalWrt System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add independent VPS sing-box and bare-ImmortalWrt installers, reorganize existing scripts into server/client directories, and configure HY2/REALITY, HomeProxy GFWList routing, dual IPv4-inner WireGuard entry points, optional IPv6 DDNS, and public IPv6 LuCI.

**Architecture:** VPS and router are configured by separate root-only env files and independent scripts. The VPS runs one sing-box process with UDP HY2 and TCP REALITY while retaining ocserv; ImmortalWrt uses fw4/HomeProxy `redirect_tproxy`, GFWList, source-subnet global proxying, PPPoE-priority/DHCP-fallback logical interfaces, and IPv6 only for WireGuard/LuCI ingress.

**Tech Stack:** Bash, sing-box, ImmortalWrt/OpenWrt UCI/netifd/fw4/uhttpd/dnsmasq/HomeProxy, WireGuard, systemd, nftables, Cloudflare DDNS/ACME.

## Global Constraints

- Root contains no compatibility copies of moved scripts.
- Existing installed absolute paths remain valid; repository path changes only affect installation commands/tests.
- Server DDNS/certificate, sing-box, and ocserv scripts remain independent.
- HY2 defaults to UDP 443 + Salamander; REALITY defaults to TCP 443 + Vision.
- HY2 supports LE existing cert or pinned self-signed IP-SAN cert.
- No generated secret appears in argv, logs, Git, or world-readable files.
- Client installer assumes bare ImmortalWrt and never hardcodes physical NIC names.
- NICs are always selected interactively; all other fields come from root-only env.
- PPPoE credentials absent means DHCP-only; present means PPPoE lower metric plus DHCP higher metric.
- WAN connectivity failure never rolls back client config; only write/parse/validation failures do.
- LAN and proxy traffic are IPv4-only; IPv6 is only WireGuard/LuCI outer ingress.
- HomeProxy uses `redirect_tproxy`, `gfwlist`, HY2 default, manual REALITY switch, no watchdog.
- Unmatched LAN/wg-local traffic is direct; wg-global unmatched traffic is proxied.
- Tests never apply real VPS/router service, firewall, network, or UCI changes.

---

### Task 1: Repository Migration

**Files:**
- Move: `vpn-maintenance.sh` → `server/vpn-maintenance.sh`
- Move: `vpn-maintenance.env.example` → `server/vpn-maintenance.env.example`
- Move: `vpn-ddns.service` → `server/vpn-ddns.service`
- Move: `vpn-ddns.timer` → `server/vpn-ddns.timer`
- Move: `ocserv-deploy.sh` → `server/ocserv-deploy.sh`
- Move: `tests/ocserv-deploy-test.sh` → `tests/server/ocserv-deploy-test.sh`
- Keep: `tests/testlib.sh`
- Modify: moved test path resolution, README references, service source instructions

**Interfaces:**
- Produces stable `server/`, `client/`, `tests/server/`, `tests/client/` layout.

- [ ] Move files with `git mv`; create `client/` and test directories.
- [ ] Update the moved ocserv test:

```bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/testlib.sh"
SCRIPT_PATH="$REPO_ROOT/server/ocserv-deploy.sh"
```

- [ ] Update any test/source references from root paths to `server/`.
- [ ] Verify root scripts are absent:

```bash
for f in vpn-maintenance.sh vpn-maintenance.env.example vpn-ddns.service \
  vpn-ddns.timer ocserv-deploy.sh; do
  [[ ! -e "$f" ]]
done
```

- [ ] Run:

```bash
bash -n server/vpn-maintenance.sh
bash -n server/ocserv-deploy.sh
sudo bash tests/server/ocserv-deploy-test.sh
git diff --check
```

- [ ] Commit: `Reorganize server and client scripts`.

---

### Task 2: VPS sing-box Installer

**Files:**
- Create: `server/sing-box-deploy.sh`
- Create: `server/sing-box.env.example`
- Create: `tests/server/sing-box-deploy-test.sh`

**Interfaces:**
- Input: `${SINGBOX_DEPLOY_CONFIG:-/etc/vpn-node/sing-box.env}` root-owned 0400/0600.
- Output: `/etc/sing-box/config.json`, `/etc/vpn-node/sing-box-state.env`, `/etc/vpn-node/sing-box-client.env`, `/etc/systemd/system/sing-box.service`, optional nft include for HY2 hopping.
- Commands: `install`, `check`, `show-client`.

- [ ] Write failing tests for config security, port validation, LE missing/matching cert, self-signed IP SAN/pin, generated secret persistence, JSON shape, systemd unit, optional hopping, collision refusal, rollback, and no optional-script invocation.
- [ ] Confirm RED.
- [ ] Implement strict env loading and validated fields:

```bash
SERVER_IPV4=""
HY2_PORT="443"
HY2_PORTS=""
HY2_CERT_MODE="selfsigned"   # letsencrypt | selfsigned
HY2_CERT_FILE=""
HY2_KEY_FILE=""
HY2_UP_MBPS=""
HY2_DOWN_MBPS=""
REALITY_PORT="443"
REALITY_TARGET=""
REALITY_SERVER_NAME=""
CREATE_SWAP_MB="0"
```

- [ ] Generate missing secrets using `openssl rand`, UUID generation, and:

```bash
sing-box generate reality-keypair
```

Persist exact shell-escaped values in mode 0600 state/client files.

- [ ] Render sing-box JSON containing:

```json
{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "hysteria2", "listen": "0.0.0.0", "listen_port": 443},
    {"type": "vless", "listen": "0.0.0.0", "listen_port": 443,
     "users": [{"uuid": "...", "flow": "xtls-rprx-vision"}]}
  ],
  "outbounds": [{"type": "direct", "tag": "direct-out"}],
  "route": {"final": "direct-out"}
}
```

Include HY2 TLS/obfs/users and REALITY handshake/private key/short IDs.

- [ ] Self-signed mode generates RSA 3072 IP-SAN certificate and client pin; LE mode validates existing cert/key/IP-or-domain identity.
- [ ] Optional `HY2_PORTS` renders nftables DNAT range only after ownership marker/sentinel validation; empty means UDP 443 only.
- [ ] Render hardened systemd unit, validate with:

```bash
sing-box check -c "$STAGED_CONFIG"
systemd-analyze verify "$STAGED_UNIT"
```

- [ ] Transactionally install, enable/restart, and wait for TCP+UDP listeners. `check` performs no mutation.
- [ ] Run GREEN tests and commit: `Add sing-box dual-protocol server installer`.

---

### Task 3: ImmortalWrt Base Network and WireGuard

**Files:**
- Create: `client/immortalwrt-deploy.sh`
- Create: `client/immortalwrt.env.example`
- Create: `tests/client/immortalwrt-deploy-test.sh`

**Interfaces:**
- Input: `${IMMORTALWRT_DEPLOY_CONFIG:-/etc/vpn-node/immortalwrt.env}` plus interactive WAN/LAN selection.
- Commands: `install`, `check`, `show-wireguard`.
- Output: UCI network/firewall/dhcp and root-only peer template files.

- [ ] Define env:

```bash
LAN_ADDRESS="10.192.0.1/24"
PPPOE_USERNAME=""
PPPOE_PASSWORD=""
PPPOE_METRIC="10"
DHCP_METRIC="20"
WG_GLOBAL_ADDRESS="10.192.100.1/24"
WG_GLOBAL_PORT="51820"
WG_LOCAL_ADDRESS="10.192.200.1/24"
WG_LOCAL_PORT="51821"
WG_MTU="1380"
WG_GLOBAL_PEERS=()
WG_LOCAL_PEERS=()
```

- [ ] Write RED tests with mocked `uci`, `ubus`, `ip`, package manager, and service commands for env security, physical NIC filtering/selection, identical NIC rejection, DHCP-only, PPPoE+DHCP metrics, UCI failure rollback, and no connectivity rollback.
- [ ] Implement interactive numbered device selection from `/sys/class/net`, rejecting virtual devices by type/path and WAN=LAN.
- [ ] Render UCI:
  - LAN `10.192.0.1/24`
  - DHCP WAN always
  - PPPoE WAN only with credentials
  - DHCPv6 logical interfaces tied to each possible WAN
  - firewall WAN zone includes all WAN/WAN6 logical interfaces
- [ ] Configure dnsmasq to suppress AAAA and LAN IPv6 RA/DHCPv6 off.
- [ ] Generate WireGuard server keys when absent, two interfaces, peer `/32` AllowedIPs, MTU 1380, and IPv6-only WAN input rules.
- [ ] Permit peer-to-peer and LAN access as specified; generate root-only client templates using IPv4 tunnel addresses and IPv6 endpoint placeholder/domain.
- [ ] Back up exact UCI files and restore only on command/render/validation failures; never wait for WAN connectivity.
- [ ] GREEN tests and commit: `Add ImmortalWrt network and WireGuard installer`.

---

### Task 4: HomeProxy, DDNS, and Public LuCI

**Files:**
- Modify: `client/immortalwrt-deploy.sh`
- Modify: `client/immortalwrt.env.example`
- Modify: `tests/client/immortalwrt-deploy-test.sh`

**Interfaces:**
- Consumes server client parameters copied into client env.
- Produces HomeProxy UCI, resource cron, optional Cloudflare AAAA DDNS/hotplug, separate uhttpd instance, ACME/self-signed cert config.

- [ ] Extend env:

```bash
VPS_IPV4=""
HY2_PASSWORD=""
HY2_OBFS_PASSWORD=""
HY2_CERT_MODE=""
HY2_CERT_PIN=""
REALITY_UUID=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""
REALITY_TARGET_NAME=""
HOME_DOMAIN=""
CLOUDFLARE_ZONE_ID=""
CLOUDFLARE_API_TOKEN=""
LUCI_PUBLIC_PORT="10443"
LUCI_CERT_MODE="selfsigned"
```

- [ ] Add RED tests for exact HomeProxy nodes, HY2 default, manual main-node switchability, GFWList, manual lists, wg-global source global proxy, wg-local/LAN default direct, IPv4-only, optional DDNS, stable GUA filtering, LuCI IPv6-only HTTPS, self-signed/LE modes, and WAN6 firewall ports.
- [ ] Install/require `homeproxy`, `sing-box`, `luci-proto-wireguard`, `wireguard-tools`, `ddns-scripts`, and TLS packages using detected `opkg` or `apk`.
- [ ] Configure HomeProxy:

```text
proxy_mode=redirect_tproxy
routing_mode=gfwlist
ipv6_support=0
main_node=HY2 node
main_udp_node=same
lan_global_proxy_ipv4_ips=10.192.100.0/24
manual proxy/direct lists preserved
resource cron enabled
```

- [ ] Add HY2 and VLESS Reality nodes from env; configure IPv4-only dial and fixed HY2 certificate pin/self-signed trust.
- [ ] Configure local/proxy DNS and dnsmasq GFW dynamic nftset flow using HomeProxy-supported resources; no China allow-list.
- [ ] Optional Cloudflare AAAA updater selects stable GUA from active WAN6 logical interfaces, DNS-only, hotplug+cron; absent domain/token means no DDNS.
- [ ] Configure separate uhttpd IPv6-only HTTPS instance on `[::]:10443`; LE DNS-01 only if configured, else self-signed. Add WAN IPv6 TCP allow rule. Do not implement login-attempt lockout.
- [ ] GREEN tests and commit: `Configure HomeProxy DDNS and public LuCI`.

---

### Task 5: Documentation and Full Validation

**Files:**
- Rewrite: `README.md`
- Update: all moved/new test runners

- [ ] Document new repository layout and independent server/client workflows.
- [ ] Document server env modes, manual copy of client parameters, optional DDNS/cert, retained ocserv.
- [ ] Document bare ImmortalWrt install warning: LAN changes to 10.192.0.1 and admin connection drops.
- [ ] Document PPPoE/DHCP simultaneous behavior without connectivity rollback.
- [ ] Document HomeProxy LuCI manual HY2/REALITY switch, GFWList updater, manual rule precedence.
- [ ] Document WireGuard IPv6 outer/IPv4 inner profiles, no simultaneous activation, IPv6 requirement, IPv4 LAN gaming.
- [ ] Document public LuCI root-risk warning.
- [ ] Run:

```bash
bash -n server/*.sh client/*.sh
sudo bash tests/server/ocserv-deploy-test.sh
sudo bash tests/server/sing-box-deploy-test.sh
sudo bash tests/client/immortalwrt-deploy-test.sh
git diff --check
```

- [ ] Ensure no real server/router state changed.
- [ ] Commit: `Document sing-box ImmortalWrt deployment`.
