#!/usr/bin/env bash

set -Eeuo pipefail

if ((EUID != 0)); then
  exec sudo --preserve-env=PATH bash "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/testlib.sh"
SCRIPT_PATH="$REPO_ROOT/client/immortalwrt-deploy.sh"

# Fail fast: each test runs in its own subshell (run_test wraps it in "(...)"),
# so exiting on the first failed assertion prevents a later passing command
# from masking an earlier failure in the same test.
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Every test runs against a per-run temp root: the config lives there, the
# deployer's live paths are confined under IMMORTALWRT_DEPLOY_ROOT, and the
# physical-interface enumeration is redirected to a fake sysfs tree, so nothing
# ever touches the real /etc/config, /etc/vpn-node, services, or host firewall.
new_fixture() {
  TEST_ROOT="$(mktemp -d)"
  export TEST_ROOT
  export IMMORTALWRT_DEPLOY_CONFIG="$TEST_ROOT/immortalwrt.env"
  export IMMORTALWRT_DEPLOY_ROOT="$TEST_ROOT/root"
  export IMMORTALWRT_SYSCLASSNET="$TEST_ROOT/sys/net"
  install -d -m 0700 "$IMMORTALWRT_DEPLOY_ROOT" "$TEST_ROOT/bin" \
    "$TEST_ROOT/ctl" "$IMMORTALWRT_SYSCLASSNET"
}

remove_fixture() {
  rm -rf -- "$TEST_ROOT"
}

write_config() {
  install -m 0600 /dev/null "$IMMORTALWRT_DEPLOY_CONFIG"
  printf '%s\n' "$1" >"$IMMORTALWRT_DEPLOY_CONFIG"
  chown root:root "$IMMORTALWRT_DEPLOY_CONFIG"
  chmod 0600 "$IMMORTALWRT_DEPLOY_CONFIG"
}

source_deployer() {
  IMMORTALWRT_DEPLOY_SOURCE_ONLY=1 source "$SCRIPT_PATH"
}

# A real self-signed certificate, base64-encoded, mirrors exactly what the
# server hands the client via HY2_CERT_PEM_B64 in its client env file.
_gen_test_cert_b64() {
  local d; d="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 \
    -subj "/CN=hy2-test" -keyout "$d/k.pem" -out "$d/c.pem" >/dev/null 2>&1
  base64 -w0 <"$d/c.pem"
  rm -rf -- "$d"
}
HY2_TEST_CERT_B64="$(_gen_test_cert_b64)"

VALID_CONFIG='
LAN_ADDRESS="10.192.0.1/24"
'

PPPOE_CONFIG='
LAN_ADDRESS="10.192.0.1/24"
PPPOE_USERNAME="user@isp"
PPPOE_PASSWORD="secret"
PPPOE_METRIC="10"
DHCP_METRIC="20"
'

PEER_CONFIG='
LAN_ADDRESS="10.192.0.1/24"
WG_GLOBAL_PEERS=(
"name=phone address=10.192.100.2"
)
'

# Full proxy parameters (as copied from the server client-params file), with a
# self-signed HY2 trust anchor delivered as base64-encoded PEM.
PROXY_CONFIG='
LAN_ADDRESS="10.192.0.1/24"
VPS_IPV4="203.0.113.7"
HY2_PORT="443"
HY2_PASSWORD="hy2pass"
HY2_OBFS_PASSWORD="salampass"
HY2_CERT_MODE="selfsigned"
HY2_CERT_PEM_B64="__HY2_CERT_B64__"
REALITY_PORT="443"
REALITY_UUID="11111111-2222-3333-4444-555555555555"
REALITY_PUBLIC_KEY="REALITYPUBKEY0001"
REALITY_SHORT_ID="0a1b2c3d"
REALITY_TARGET_NAME="www.microsoft.com"
'
PROXY_CONFIG="${PROXY_CONFIG//__HY2_CERT_B64__/$HY2_TEST_CERT_B64}"

# Proxy + optional Cloudflare AAAA DDNS.
DDNS_CONFIG='
LAN_ADDRESS="10.192.0.1/24"
VPS_IPV4="203.0.113.7"
HY2_PASSWORD="hy2pass"
HY2_OBFS_PASSWORD="salampass"
HY2_CERT_MODE="selfsigned"
HY2_CERT_PEM_B64="__HY2_CERT_B64__"
REALITY_UUID="11111111-2222-3333-4444-555555555555"
REALITY_PUBLIC_KEY="REALITYPUBKEY0001"
REALITY_SHORT_ID="0a1b2c3d"
REALITY_TARGET_NAME="www.microsoft.com"
HOME_DOMAIN="home.example.com"
CLOUDFLARE_ZONE_ID="zone123"
CLOUDFLARE_API_TOKEN="token456"
'
DDNS_CONFIG="${DDNS_CONFIG//__HY2_CERT_B64__/$HY2_TEST_CERT_B64}"

# Proxy + Let'\''s Encrypt for both HY2 (public CA) and public LuCI (DNS-01).
LE_CONFIG='
LAN_ADDRESS="10.192.0.1/24"
VPS_IPV4="203.0.113.7"
HY2_PASSWORD="hy2pass"
HY2_OBFS_PASSWORD="salampass"
HY2_CERT_MODE="letsencrypt"
HY2_SNI="hy2.example.com"
REALITY_UUID="11111111-2222-3333-4444-555555555555"
REALITY_PUBLIC_KEY="REALITYPUBKEY0001"
REALITY_SHORT_ID="0a1b2c3d"
REALITY_TARGET_NAME="www.microsoft.com"
HOME_DOMAIN="home.example.com"
CLOUDFLARE_ZONE_ID="zone123"
CLOUDFLARE_API_TOKEN="token456"
LUCI_CERT_MODE="letsencrypt"
'

_grep() { grep -qF "$1" "$2" || fail "expected to find: $1"; }
_grepe() { grep -qE "$1" "$2" || fail "expected to match: $1"; }
_ngrep() { ! grep -qF "$1" "$2" || fail "unexpected content: $1"; }

# ---------- fake sysfs network devices ----------

# type: phys | bridge | tun | wireguard | devtype-wireguard | nohw | lo
_add_net_dev() {
  local name="$1" type="${2:-phys}" d
  d="$IMMORTALWRT_SYSCLASSNET/$name"
  mkdir -p "$d"
  case "$type" in
    phys) mkdir -p "$d/device" ;;
    bridge) mkdir -p "$d/device" "$d/bridge" ;;
    tun) mkdir -p "$d/device"; : >"$d/tun_flags" ;;
    wireguard) mkdir -p "$d/device" "$d/wireguard" ;;
    devtype-wireguard)
      mkdir -p "$d/device"
      printf 'DEVTYPE=wireguard\n' >"$d/uevent" ;;
    nohw) : ;;
    lo) : ;;
  esac
}

# ---------- system-command mocks ----------
#
# Intercepts every real system command the installer touches under
# $TEST_ROOT/bin. openssl/sed/grep/etc. remain real; uci, wg, service, opkg,
# ip, and ubus are stubbed so no test applies UCI, reloads a service, installs
# a package, or changes host networking.
_write_mocks() {
  cat >"$TEST_ROOT/bin/uci" <<'EOF'
#!/usr/bin/env bash
log="$TEST_ROOT/uci-cmd.log"
ctl="$TEST_ROOT/ctl"
dir="$TEST_ROOT/root/etc/config"
args=()
while (( $# )); do
  case "$1" in
    -q) shift ;;
    -c) dir="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
cmd="${1:-}"; shift || true
live="$IMMORTALWRT_DEPLOY_ROOT/etc/config"
case "$cmd" in
  batch)
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf 'batch %s\n' "$line" >> "$log"
    done
    [[ -f "$ctl/uci_fail" ]] && exit 1
    exit 0 ;;
  set|add|add_list|del_list|delete|rename)
    printf '%s %s\n' "$cmd" "$*" >> "$log"
    [[ -f "$ctl/uci_fail" ]] && exit 1
    exit 0 ;;
  commit)
    printf 'commit %s\n' "$*" >> "$log"
    [[ -f "$ctl/uci_fail" ]] && exit 1
    if [[ "$dir" == "$live" && -f "$ctl/uci_commit_fail" ]]; then exit 1; fi
    for c in network firewall dhcp; do
      mkdir -p "$dir"
      printf '# uci-committed %s\n' "$c" >> "$dir/$c"
    done
    exit 0 ;;
  revert) printf 'revert %s\n' "$*" >> "$log"; exit 0 ;;
  show|get|export|changes|import) exit 0 ;;
  *) exit 0 ;;
esac
EOF

  cat >"$TEST_ROOT/bin/wg" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  genkey)
    f="$TEST_ROOT/ctl/wg_counter"
    n="$(cat "$f" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" >"$f"
    printf 'PRIVKEY%08d\n' "$n" ;;
  pubkey)
    read -r k
    printf 'PUB%s\n' "${k#PRIVKEY}" ;;
  *) exit 0 ;;
esac
EOF

  cat >"$TEST_ROOT/bin/service" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*" >> "$TEST_ROOT/service-args.log"
if [[ "${2:-}" == "reload" && -f "$TEST_ROOT/ctl/service_fail" ]]; then exit 1; fi
exit 0
EOF

  cat >"$TEST_ROOT/bin/opkg" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*" >> "$TEST_ROOT/opkg-args.log"
exit 0
EOF

  local m
  for m in ip ubus; do
    cat >"$TEST_ROOT/bin/$m" <<EOF
#!/usr/bin/env bash
printf 'ARGS: %s\n' "\$*" >> "$TEST_ROOT/$m-args.log"
exit 0
EOF
  done

  chmod +x "$TEST_ROOT/bin/"*
}

# Full valid config + mocks + PATH + two physical devices + resolved keys.
_prep() {
  local config="${1:-$VALID_CONFIG}"
  new_fixture
  write_config "$config"
  _write_mocks
  export PATH="$TEST_ROOT/bin:$PATH"
  _add_net_dev eth0 phys
  _add_net_dev eth1 phys
  source_deployer
  load_config
  validate_config
  WAN_DEVICE="eth0"
  LAN_DEVICE="eth1"
  resolve_wireguard_material
}

# ==================== Config security ====================

test_valid_config_passes() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  source_deployer
  load_config
  assert_success validate_config
}

test_config_must_be_root_owned() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  chown nobody "$IMMORTALWRT_DEPLOY_CONFIG"
  source_deployer
  assert_failure load_config
}

test_config_rejects_group_writable_perms() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  chmod 0644 "$IMMORTALWRT_DEPLOY_CONFIG"
  source_deployer
  assert_failure load_config
}

test_config_rejects_symlink() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  local real="$TEST_ROOT/real.env"
  cp "$IMMORTALWRT_DEPLOY_CONFIG" "$real"
  chown root:root "$real"; chmod 0600 "$real"
  rm -f "$IMMORTALWRT_DEPLOY_CONFIG"
  ln -s "$real" "$IMMORTALWRT_DEPLOY_CONFIG"
  source_deployer
  assert_failure load_config
}

# ==================== Field validation ====================

test_rejects_bad_lan_address() {
  new_fixture
  trap remove_fixture EXIT
  write_config 'LAN_ADDRESS="10.192.0.1"'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_pppoe_username_without_password() {
  new_fixture
  trap remove_fixture EXIT
  write_config 'PPPOE_USERNAME="user"'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_pppoe_metric_not_lower_than_dhcp() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
PPPOE_USERNAME="user"
PPPOE_PASSWORD="pass"
PPPOE_METRIC="30"
DHCP_METRIC="20"
'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_bad_wg_port() {
  new_fixture
  trap remove_fixture EXIT
  write_config 'WG_GLOBAL_PORT="70000"'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_equal_wg_ports() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
WG_GLOBAL_PORT="51820"
WG_LOCAL_PORT="51820"
'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_bad_wg_address() {
  new_fixture
  trap remove_fixture EXIT
  write_config 'WG_GLOBAL_ADDRESS="10.192.100.1"'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_bad_mtu() {
  new_fixture
  trap remove_fixture EXIT
  write_config 'WG_MTU="9000"'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_peer_missing_address() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
WG_GLOBAL_PEERS=(
"name=phone"
)
'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_duplicate_peer_address() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
WG_GLOBAL_PEERS=(
"name=a address=10.192.100.2"
"name=b address=10.192.100.2"
)
'
  source_deployer
  load_config
  assert_failure validate_config
}

test_accepts_valid_config_with_peers() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$PEER_CONFIG"
  source_deployer
  load_config
  assert_success validate_config
}

# ==================== Physical device filtering ====================

test_is_physical_accepts_ethernet() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev eth0 phys
  assert_success is_physical_device eth0
}

test_is_physical_rejects_loopback() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev lo lo
  assert_failure is_physical_device lo
}

test_is_physical_rejects_bridge() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev br-lan bridge
  assert_failure is_physical_device br-lan
}

test_is_physical_rejects_tun() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev tun0 tun
  assert_failure is_physical_device tun0
}

test_is_physical_rejects_wireguard_dir() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev wg0 wireguard
  assert_failure is_physical_device wg0
}

test_is_physical_rejects_wireguard_devtype() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev wgx devtype-wireguard
  assert_failure is_physical_device wgx
}

test_is_physical_rejects_no_hardware() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev virt0 nohw
  assert_failure is_physical_device virt0
}

test_is_physical_rejects_nonexistent() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  assert_failure is_physical_device nosuchdev
}

test_list_physical_filters_virtual() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev eth0 phys
  _add_net_dev eth1 phys
  _add_net_dev lo lo
  _add_net_dev br-lan bridge
  _add_net_dev wg0 wireguard
  local out
  out="$(list_physical_devices)"
  assert_eq $'eth0\neth1' "$out" "only physical devices listed"
}

# ==================== Device selection ====================

test_validate_selection_rejects_identical() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev eth0 phys
  assert_failure validate_device_selection eth0 eth0
}

test_validate_selection_rejects_nonexistent() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev eth0 phys
  assert_failure validate_device_selection eth0 ghost0
}

test_validate_selection_rejects_virtual() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev eth0 phys
  _add_net_dev br-lan bridge
  assert_failure validate_device_selection br-lan eth0
}

test_prompt_selects_wan_lan() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev eth0 phys
  _add_net_dev eth1 phys
  prompt_device_selection < <(printf '1\n2\n') 2>/dev/null
  assert_eq "eth0" "$WAN_DEVICE" "WAN device from selection 1"
  assert_eq "eth1" "$LAN_DEVICE" "LAN device from selection 2"
}

test_prompt_rejects_identical_selection() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev eth0 phys
  _add_net_dev eth1 phys
  assert_failure prompt_device_selection < <(printf '1\n1\n')
}

test_prompt_rejects_out_of_range() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev eth0 phys
  _add_net_dev eth1 phys
  assert_failure prompt_device_selection < <(printf '9\n1\n')
}

test_prompt_requires_two_devices() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  _add_net_dev eth0 phys
  assert_failure prompt_device_selection < <(printf '1\n1\n')
}

# ==================== Network UCI rendering ====================

test_network_dhcp_only() {
  _prep "$VALID_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/net.uci"
  render_network_batch "$out"
  _grep "set network.wan.proto='dhcp'" "$out"
  _grep "set network.wan.device='eth0'" "$out"
  _grep "set network.wan.metric='20'" "$out"
  _grep "set network.wan6.proto='dhcpv6'" "$out"
  _grep "set network.wan6.device='@wan'" "$out"
  _ngrep "network.wanpppoe" "$out"
}

test_network_pppoe_and_dhcp_metrics() {
  _prep "$PPPOE_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/net.uci"
  render_network_batch "$out"
  _grep "set network.wanpppoe.proto='pppoe'" "$out"
  _grep "set network.wanpppoe.device='eth0'" "$out"
  _grep "set network.wanpppoe.username='user@isp'" "$out"
  _grep "set network.wanpppoe.metric='10'" "$out"
  _grep "set network.wan.proto='dhcp'" "$out"
  _grep "set network.wan.metric='20'" "$out"
  _grep "set network.wanpppoe6.proto='dhcpv6'" "$out"
  _grep "set network.wanpppoe6.device='@wanpppoe'" "$out"
  # IPv6 is handled solely by the dedicated wanpppoe6 dhcpv6 interface, so the
  # PPPoE interface's own auto IPv6 sub-interface must be disabled (no
  # redundant/conflicting second IPv6 client on the same link).
  _grep "set network.wanpppoe.ipv6='0'" "$out"
  _ngrep "set network.wanpppoe.ipv6='auto'" "$out"
  # PPPoE metric must be lower (preferred) than the DHCP fallback metric.
  ((10#$PPPOE_METRIC < 10#$DHCP_METRIC)) ||
    fail "pppoe metric must be lower than dhcp metric"
}

test_network_lan() {
  _prep "$VALID_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/net.uci"
  render_network_batch "$out"
  _grep "set network.lan.proto='static'" "$out"
  _grep "set network.lan.ipaddr='10.192.0.1'" "$out"
  _grep "set network.lan.netmask='255.255.255.0'" "$out"
  _grep "set network.lan.device='eth1'" "$out"
}

test_network_wg_interfaces_differ() {
  _prep "$VALID_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/net.uci"
  render_network_batch "$out"
  _grep "set network.wg_global.proto='wireguard'" "$out"
  _grep "set network.wg_global.listen_port='51820'" "$out"
  _grep "set network.wg_global.mtu='1380'" "$out"
  _grep "add_list network.wg_global.addresses='10.192.100.1/24'" "$out"
  _grep "set network.wg_local.listen_port='51821'" "$out"
  _grep "add_list network.wg_local.addresses='10.192.200.1/24'" "$out"
}

test_network_wg_peer_slash32() {
  _prep "$PEER_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/net.uci"
  render_network_batch "$out"
  _grep "set network.wgpeer_wg_global_phone=wireguard_wg_global" "$out"
  _grep "add_list network.wgpeer_wg_global_phone.allowed_ips='10.192.100.2/32'" "$out"
  _grep "set network.wgpeer_wg_global_phone.route_allowed_ips='1'" "$out"
  _grepe "^set network.wgpeer_wg_global_phone.public_key='PUB" "$out"
}

test_no_hardcoded_device_names() {
  _prep "$PPPOE_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/net.uci"
  render_network_batch "$out"
  # DHCPv6 references logical interfaces via aliases, never pppoe-wan/eth0.
  _grep "set network.wan6.device='@wan'" "$out"
  _grep "set network.wanpppoe6.device='@wanpppoe'" "$out"
  _ngrep "pppoe-wan" "$out"
  ! grep -q "pppoe-wan" "$SCRIPT_PATH" || fail "script hardcodes pppoe-wan"
  ! grep -qw "eth0" "$SCRIPT_PATH" || fail "script hardcodes eth0"
}

# ==================== Firewall UCI rendering ====================

test_firewall_lan_zone_includes_wg() {
  _prep "$VALID_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/fw.uci"
  render_firewall_batch "$out"
  # Factory-default anonymous lan zone (@zone[0]) is reused, not duplicated.
  _grep "set firewall.@zone[0].name='lan'" "$out"
  _grep "delete firewall.@zone[0].network" "$out"
  _grep "add_list firewall.@zone[0].network='lan'" "$out"
  _grep "add_list firewall.@zone[0].network='wg_global'" "$out"
  _grep "add_list firewall.@zone[0].network='wg_local'" "$out"
  # Factory-default lan->wan forwarding (@forwarding[0]) is reused.
  _grep "set firewall.@forwarding[0].dest='wan'" "$out"
  # No second named "lan"/"wan" zone is created (that would break policy).
  _ngrep "firewall.lan_zone" "$out"
  _ngrep "firewall.wan_zone" "$out"
  _ngrep "firewall.lan_wan" "$out"
  # The default network list must be cleared before members are re-added.
  local del_ln add_ln
  del_ln="$(grep -nF "delete firewall.@zone[0].network" "$out" | head -1 | cut -d: -f1)"
  add_ln="$(grep -nF "add_list firewall.@zone[0].network='lan'" "$out" | head -1 | cut -d: -f1)"
  ((del_ln < add_ln)) ||
    fail "lan zone network list must be cleared before add_list"
}

test_firewall_wan_zone_includes_wan6() {
  _prep "$PPPOE_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/fw.uci"
  render_firewall_batch "$out"
  # Factory-default anonymous wan zone (@zone[1]) is reused, not duplicated.
  _grep "set firewall.@zone[1].name='wan'" "$out"
  _grep "set firewall.@zone[1].masq='1'" "$out"
  _grep "delete firewall.@zone[1].network" "$out"
  _grep "add_list firewall.@zone[1].network='wan'" "$out"
  _grep "add_list firewall.@zone[1].network='wan6'" "$out"
  _grep "add_list firewall.@zone[1].network='wanpppoe'" "$out"
  _grep "add_list firewall.@zone[1].network='wanpppoe6'" "$out"
  # The default network list must be cleared before members are re-added.
  local del_ln add_ln
  del_ln="$(grep -nF "delete firewall.@zone[1].network" "$out" | head -1 | cut -d: -f1)"
  add_ln="$(grep -nF "add_list firewall.@zone[1].network='wan'" "$out" | head -1 | cut -d: -f1)"
  ((del_ln < add_ln)) ||
    fail "wan zone network list must be cleared before add_list"
}

test_firewall_wg_rules_ipv6_only() {
  _prep "$VALID_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/fw.uci"
  render_firewall_batch "$out"
  _grep "set firewall.wg_global_in.family='ipv6'" "$out"
  _grep "set firewall.wg_global_in.proto='udp'" "$out"
  _grep "set firewall.wg_global_in.dest_port='51820'" "$out"
  _grep "set firewall.wg_global_in.target='ACCEPT'" "$out"
  _grep "set firewall.wg_local_in.family='ipv6'" "$out"
  _grep "set firewall.wg_local_in.dest_port='51821'" "$out"
}

# ==================== dnsmasq / IPv6 boundary ====================

test_dhcp_filters_aaaa_and_disables_lan_ipv6() {
  _prep "$VALID_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/dhcp.uci"
  render_dhcp_batch "$out"
  _grep "set dhcp.@dnsmasq[0].filter_aaaa='1'" "$out"
  _grep "set dhcp.lan.ra='disabled'" "$out"
  _grep "set dhcp.lan.dhcpv6='disabled'" "$out"
}

# ==================== WireGuard key generation / reuse ====================

test_server_keys_generated_when_absent() {
  _prep "$VALID_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/state.env"
  render_wg_state_file "$out"
  _grepe "^WG_GLOBAL_PRIVATE_KEY=" "$out"
  _grepe "^WG_GLOBAL_PUBLIC_KEY=" "$out"
  _grepe "^WG_LOCAL_PRIVATE_KEY=" "$out"
  [[ -n "$WG_GLOBAL_PRIVATE_KEY" && -n "$WG_LOCAL_PRIVATE_KEY" ]] ||
    fail "server keys must be non-empty"
  [[ "$WG_GLOBAL_PRIVATE_KEY" != "$WG_LOCAL_PRIVATE_KEY" ]] ||
    fail "two interfaces must use different keys"
}

test_server_keys_reused_from_state() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  _write_mocks
  export PATH="$TEST_ROOT/bin:$PATH"
  source_deployer
  load_config
  validate_config
  install -d -m 0700 "$(dirname "$WG_STATE_FILE")"
  cat >"$WG_STATE_FILE" <<'EOF'
WG_GLOBAL_PRIVATE_KEY='SEEDGLOBALPRIV'
WG_GLOBAL_PUBLIC_KEY='SEEDGLOBALPUB'
WG_LOCAL_PRIVATE_KEY='SEEDLOCALPRIV'
WG_LOCAL_PUBLIC_KEY='SEEDLOCALPUB'
EOF
  chmod 0600 "$WG_STATE_FILE"
  resolve_wireguard_material
  assert_eq "SEEDGLOBALPRIV" "$WG_GLOBAL_PRIVATE_KEY" "global private key reused"
  assert_eq "SEEDLOCALPUB" "$WG_LOCAL_PUBLIC_KEY" "local public key reused"
}

test_peer_without_pubkey_gets_generated_keypair() {
  _prep "$PEER_CONFIG"
  trap remove_fixture EXIT
  local dir="$TEST_ROOT/clients"
  render_all_peer_templates "$dir"
  local f="$dir/wg_global-phone.conf"
  [[ -f "$f" ]] || fail "peer template not generated"
  _grepe "^PrivateKey = PRIVKEY" "$f"
}

test_peer_with_pubkey_uses_placeholder_private() {
  _prep '
LAN_ADDRESS="10.192.0.1/24"
WG_GLOBAL_PEERS=(
"name=laptop address=10.192.100.3 public_key=PROVIDEDPUBKEY"
)
'
  trap remove_fixture EXIT
  local out="$TEST_ROOT/net.uci"
  render_network_batch "$out"
  _grep "set network.wgpeer_wg_global_laptop.public_key='PROVIDEDPUBKEY'" "$out"
  local dir="$TEST_ROOT/clients"
  render_all_peer_templates "$dir"
  _grep "PrivateKey = REPLACE_WITH_CLIENT_PRIVATE_KEY" "$dir/wg_global-laptop.conf"
}

# ==================== Client templates ====================

test_peer_template_content_and_mode() {
  _prep "$PEER_CONFIG"
  trap remove_fixture EXIT
  local dir="$TEST_ROOT/clients"
  render_all_peer_templates "$dir"
  local f="$dir/wg_global-phone.conf"
  assert_eq "600" "$(stat -c '%a' "$f")" "template mode 0600"
  _grepe "^Address = 10\.192\.100\.2/32$" "$f"
  _grepe "^AllowedIPs = 0\.0\.0\.0/0$" "$f"
  _grepe "^DNS = 10\.192\.100\.1$" "$f"
  _grepe "^MTU = 1380$" "$f"
  _grepe "^PublicKey = " "$f"
  # The default placeholder is not an IPv6 literal, so it is left unbracketed.
  _grep "Endpoint = YOUR_HOME_IPV6_OR_DDNS_DOMAIN:51820" "$f"
  _ngrep "Endpoint = [YOUR_HOME_IPV6_OR_DDNS_DOMAIN]:51820" "$f"
}

test_peer_endpoint_ipv6_literal_is_bracketed() {
  _prep '
LAN_ADDRESS="10.192.0.1/24"
WG_ENDPOINT_HOST="2001:db8::1"
WG_GLOBAL_PEERS=(
"name=phone address=10.192.100.2"
)
'
  trap remove_fixture EXIT
  local dir="$TEST_ROOT/clients"
  render_all_peer_templates "$dir"
  local f="$dir/wg_global-phone.conf"
  _grep "Endpoint = [2001:db8::1]:51820" "$f"
}

test_peer_endpoint_hostname_is_unbracketed() {
  _prep '
LAN_ADDRESS="10.192.0.1/24"
WG_ENDPOINT_HOST="home.example.com"
WG_GLOBAL_PEERS=(
"name=phone address=10.192.100.2"
)
'
  trap remove_fixture EXIT
  local dir="$TEST_ROOT/clients"
  render_all_peer_templates "$dir"
  local f="$dir/wg_global-phone.conf"
  _grep "Endpoint = home.example.com:51820" "$f"
  _ngrep "Endpoint = [home.example.com]:51820" "$f"
}

test_peer_endpoint_ipv4_literal_is_unbracketed() {
  _prep '
LAN_ADDRESS="10.192.0.1/24"
WG_ENDPOINT_HOST="203.0.113.10"
WG_GLOBAL_PEERS=(
"name=phone address=10.192.100.2"
)
'
  trap remove_fixture EXIT
  local dir="$TEST_ROOT/clients"
  render_all_peer_templates "$dir"
  local f="$dir/wg_global-phone.conf"
  _grep "Endpoint = 203.0.113.10:51820" "$f"
  _ngrep "Endpoint = [203.0.113.10]:51820" "$f"
}

# ==================== Transactional install + rollback ====================

test_successful_install_writes_all_artifacts() {
  _prep "$PEER_CONFIG"
  trap remove_fixture EXIT
  local rc=0
  ( install_client ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc == 0)) || fail "install_client must succeed"
  [[ -f "$WG_STATE_FILE" ]] || fail "wg state not installed"
  assert_eq "600" "$(stat -c '%a' "$WG_STATE_FILE")" "state mode"
  [[ -f "$CLIENT_TEMPLATE_DIR/wg_global-phone.conf" ]] ||
    fail "peer template not installed"
  assert_eq "600" "$(stat -c '%a' "$CLIENT_TEMPLATE_DIR/wg_global-phone.conf")" \
    "template mode"
  grep -q '^commit' "$TEST_ROOT/uci-cmd.log" || fail "uci commit must run"
  _grep "# uci-committed network" "$NETWORK_CONFIG"
  grep -q '^ARGS: network reload' "$TEST_ROOT/service-args.log" ||
    fail "network must be reloaded"
  grep -q '^ARGS: firewall reload' "$TEST_ROOT/service-args.log" ||
    fail "firewall must be reloaded"
  grep -q '^ARGS: dnsmasq reload' "$TEST_ROOT/service-args.log" ||
    fail "dnsmasq must be reloaded"
}

test_rollback_on_validation_failure_leaves_nothing() {
  _prep "$PEER_CONFIG"
  trap remove_fixture EXIT
  touch "$TEST_ROOT/ctl/uci_fail"
  local rc=0
  ( install_client ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc != 0)) || fail "install must fail when UCI validation fails"
  [[ ! -e "$WG_STATE_FILE" ]] || fail "no state file must be left behind"
  [[ ! -e "$CLIENT_TEMPLATE_DIR" ]] || fail "no client templates must be left"
  [[ -z "$(find "$TRANSACTION_DIR_ROOT" -mindepth 1 2>/dev/null)" ]] ||
    fail "transaction workspace must be cleaned up"
}

test_rollback_on_uci_commit_failure() {
  _prep "$PEER_CONFIG"
  trap remove_fixture EXIT
  install -d -m 0755 "$UCI_CONFIG_DIR"
  printf '# PRIOR-NETWORK\n' >"$NETWORK_CONFIG"
  touch "$TEST_ROOT/ctl/uci_commit_fail"
  local rc=0
  ( install_client ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc != 0)) || fail "install must fail when uci commit fails"
  _grep "# PRIOR-NETWORK" "$NETWORK_CONFIG"
  _ngrep "# uci-committed network" "$NETWORK_CONFIG"
  [[ ! -e "$WG_STATE_FILE" ]] || fail "state must not be installed on commit failure"
  [[ ! -e "$CLIENT_TEMPLATE_DIR" ]] || fail "templates must not be installed"
}

test_rollback_after_commit_restores_prior() {
  _prep "$PEER_CONFIG"
  trap remove_fixture EXIT
  install -d -m 0755 "$UCI_CONFIG_DIR"
  printf '# PRIOR-NETWORK\n' >"$NETWORK_CONFIG"
  # Commit succeeds (marker written) but the service reload fails, so rollback
  # must restore the exact prior config file and remove the new files.
  touch "$TEST_ROOT/ctl/service_fail"
  local rc=0
  ( install_client ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc != 0)) || fail "install must fail when a service reload fails"
  _grep "# PRIOR-NETWORK" "$NETWORK_CONFIG"
  ! grep -q '# uci-committed network' "$NETWORK_CONFIG" ||
    fail "committed marker must be rolled back to prior config"
  [[ ! -e "$WG_STATE_FILE" ]] || fail "new state file must be removed on rollback"
  [[ ! -e "$CLIENT_TEMPLATE_DIR" ]] ||
    fail "new client templates must be removed on rollback"
}

test_no_connectivity_wait_or_rollback() {
  _prep "$VALID_CONFIG"
  trap remove_fixture EXIT
  # No interface is ever "up"; install must still succeed (connectivity is
  # never a success criterion and never triggers rollback).
  local rc=0
  ( install_client ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc == 0)) || fail "install must not depend on WAN connectivity"
  # Static guarantee: no polling/carrier/ping/ubus status wait exists. The ubus
  # match targets an invoked `ubus` command (followed by whitespace), so the
  # public-LuCI uhttpd `ubus_prefix`/`/ubus` config tokens are not false hits.
  ! grep -Eq '\bping\b|operstate|carrier|\bubus[[:space:]]' "$SCRIPT_PATH" ||
    fail "script must not wait on connectivity"
}

# ==================== check performs no live mutation ====================

test_check_makes_no_live_mutation() {
  _prep "$PEER_CONFIG"
  trap remove_fixture EXIT
  local rc=0
  cmd_check < <(printf '1\n2\n') >/dev/null 2>&1 || rc=$?
  ((rc == 0)) || fail "check must succeed on a valid config"
  [[ ! -e "$NETWORK_CONFIG" ]] || fail "check must not write live network config"
  [[ ! -e "$WG_STATE_FILE" ]] || fail "check must not write the state file"
  [[ ! -e "$CLIENT_TEMPLATE_DIR" ]] || fail "check must not write client templates"
  [[ ! -e "$TEST_ROOT/service-args.log" ]] ||
    fail "check must not reload any service"
}

# ==================== show-wireguard ====================

test_show_wireguard_prints_after_install() {
  _prep "$PEER_CONFIG"
  trap remove_fixture EXIT
  ( install_client ) </dev/null >/dev/null 2>&1 || fail "install_client failed"
  local out
  out="$(cmd_show_wireguard)"
  grep -qF "wg_global" <<<"$out" || fail "output must include wg_global"
  grep -qF "$WG_GLOBAL_PUBLIC_KEY" <<<"$out" ||
    fail "output must include the server public key"
  grep -qF "wg_global-phone.conf" <<<"$out" ||
    fail "output must list the client template"
}

test_show_wireguard_missing_state_fails() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  source_deployer
  assert_failure cmd_show_wireguard
}

# ==================== Dependencies / packages ====================

test_ensure_packages_installs_wireguard_tools() {
  _prep "$VALID_CONFIG"
  trap remove_fixture EXIT
  ensure_packages >/dev/null 2>&1
  _grep "install wireguard-tools" "$TEST_ROOT/opkg-args.log"
}

test_ensure_packages_adds_pppoe_when_configured() {
  _prep "$PPPOE_CONFIG"
  trap remove_fixture EXIT
  ensure_packages >/dev/null 2>&1
  grep -q 'ppp-mod-pppoe' "$TEST_ROOT/opkg-args.log" ||
    fail "pppoe packages must be installed when PPPoE is configured"
}

test_ensure_packages_uses_luci_app_homeproxy() {
  _prep "$PROXY_CONFIG"
  trap remove_fixture EXIT
  ensure_packages >/dev/null 2>&1
  local log="$TEST_ROOT/opkg-args.log"
  # Must install the LuCI app package, not the bare 'homeproxy' name.
  grep -qE '(^| )luci-app-homeproxy( |$)' "$log" ||
    fail "must install luci-app-homeproxy"
  ! grep -qE '(^| )homeproxy( |$)' "$log" ||
    fail "must not install the bare 'homeproxy' package name"
  # The Cloudflare updater is self-contained, so ddns-scripts must not be pulled.
  ! grep -qE '(^| )ddns-scripts( |$)' "$log" ||
    fail "unused ddns-scripts must not be installed"
}

# ==================== HomeProxy config / nodes ====================

test_rejects_bad_hy2_cert_mode() {
  new_fixture
  trap remove_fixture EXIT
  write_config 'HY2_CERT_MODE="bogus"'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_bad_luci_cert_mode() {
  new_fixture
  trap remove_fixture EXIT
  write_config 'LUCI_CERT_MODE="bogus"'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_bad_luci_port() {
  new_fixture
  trap remove_fixture EXIT
  write_config 'LUCI_PUBLIC_PORT="70000"'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_proxy_without_password() {
  new_fixture
  trap remove_fixture EXIT
  write_config 'VPS_IPV4="203.0.113.7"'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_selfsigned_without_pem() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
VPS_IPV4="203.0.113.7"
HY2_PASSWORD="p"
HY2_OBFS_PASSWORD="o"
REALITY_UUID="11111111-2222-3333-4444-555555555555"
REALITY_PUBLIC_KEY="k"
REALITY_SHORT_ID="s"
REALITY_TARGET_NAME="www.microsoft.com"
HY2_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  assert_failure validate_config
}

# Legacy HY2_CERT_PIN was a misleading name (it actually held a raw PEM). It is
# now HY2_CERT_PEM_B64 (base64 PEM); a leftover HY2_CERT_PIN must fail loudly.
test_rejects_legacy_hy2_cert_pin() {
  new_fixture
  trap remove_fixture EXIT
  local cfg='
VPS_IPV4="203.0.113.7"
HY2_PASSWORD="p"
HY2_OBFS_PASSWORD="o"
REALITY_UUID="11111111-2222-3333-4444-555555555555"
REALITY_PUBLIC_KEY="k"
REALITY_SHORT_ID="s"
REALITY_TARGET_NAME="www.microsoft.com"
HY2_CERT_MODE="selfsigned"
HY2_CERT_PEM_B64="__HY2_CERT_B64__"
HY2_CERT_PIN="-----BEGIN CERTIFICATE-----
LEGACY
-----END CERTIFICATE-----"
'
  cfg="${cfg//__HY2_CERT_B64__/$HY2_TEST_CERT_B64}"
  write_config "$cfg"
  source_deployer
  load_config
  assert_failure validate_config
}

# A malformed base64 blob must be rejected rather than written as junk.
test_rejects_selfsigned_bad_base64() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
VPS_IPV4="203.0.113.7"
HY2_PASSWORD="p"
HY2_OBFS_PASSWORD="o"
REALITY_UUID="11111111-2222-3333-4444-555555555555"
REALITY_PUBLIC_KEY="k"
REALITY_SHORT_ID="s"
REALITY_TARGET_NAME="www.microsoft.com"
HY2_CERT_MODE="selfsigned"
HY2_CERT_PEM_B64="not*valid*base64*!!"
'
  source_deployer
  load_config
  assert_failure validate_config
}

# The base64 PEM must decode to /etc/homeproxy/certs/hy2-server.pem at mode 0644.
test_hy2_ca_file_decoded_to_pem_0644() {
  _prep "$PROXY_CONFIG"
  trap remove_fixture EXIT
  local dest="$TEST_ROOT/hy2-server.pem"
  write_hy2_ca_file "$dest"
  [[ -f "$dest" ]] || fail "trust anchor was not written"
  assert_eq "644" "$(stat -c '%a' "$dest")" "trust anchor mode"
  openssl x509 -in "$dest" -noout >/dev/null 2>&1 ||
    fail "decoded trust anchor must be a valid certificate"
}

test_accepts_full_proxy_config() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$PROXY_CONFIG"
  source_deployer
  load_config
  assert_success validate_config
}

test_rejects_home_domain_without_token() {
  new_fixture
  trap remove_fixture EXIT
  write_config 'HOME_DOMAIN="home.example.com"'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_le_luci_without_domain() {
  new_fixture
  trap remove_fixture EXIT
  write_config 'LUCI_CERT_MODE="letsencrypt"'
  source_deployer
  load_config
  assert_failure validate_config
}

test_homeproxy_gfwlist_ipv4_only() {
  _prep "$PROXY_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/hp.uci"
  : >"$out"
  render_homeproxy_batch "$out"
  _grep "set homeproxy.config.proxy_mode='redirect_tproxy'" "$out"
  _grep "set homeproxy.config.routing_mode='gfwlist'" "$out"
  _grep "set homeproxy.config.ipv6_support='0'" "$out"
  _grep "set homeproxy.config.main_node='hp_hy2'" "$out"
  _grep "set homeproxy.config.main_udp_node='same'" "$out"
  _grep "set homeproxy.dns.dns_strategy='ipv4_only'" "$out"
}

test_homeproxy_resource_cron() {
  _prep "$PROXY_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/hp.uci"
  : >"$out"
  render_homeproxy_batch "$out"
  _grep "set homeproxy.subscription.auto_update='1'" "$out"
  _grepe "^set homeproxy.subscription.auto_update_time='[0-9]+'$" "$out"
}

test_homeproxy_wg_global_source_global_proxy() {
  _prep "$PROXY_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/hp.uci"
  : >"$out"
  render_homeproxy_batch "$out"
  _grep "set homeproxy.control.lan_proxy_mode='disabled'" "$out"
  _grep "delete homeproxy.control.lan_global_proxy_ipv4_ips" "$out"
  _grep "add_list homeproxy.control.lan_global_proxy_ipv4_ips='10.192.100.0/24'" "$out"
  # wg-local subnet is NOT globally proxied (it follows GFWList like the LAN).
  _ngrep "lan_global_proxy_ipv4_ips='10.192.200.0/24'" "$out"
  # The delete must precede the add so re-runs stay idempotent.
  local del_ln add_ln
  del_ln="$(grep -nF "delete homeproxy.control.lan_global_proxy_ipv4_ips" "$out" | head -1 | cut -d: -f1)"
  add_ln="$(grep -nF "add_list homeproxy.control.lan_global_proxy_ipv4_ips" "$out" | head -1 | cut -d: -f1)"
  ((del_ln < add_ln)) || fail "global-proxy list must be cleared before add_list"
}

test_homeproxy_manual_lists_preserved() {
  _prep "$PROXY_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/hp.uci"
  : >"$out"
  render_homeproxy_batch "$out"
  # Only our own global-proxy list is cleared; manual proxy/direct lists survive.
  _ngrep "delete homeproxy.control.wan_proxy_ipv4_ips" "$out"
  _ngrep "delete homeproxy.control.wan_proxy_ipv6_ips" "$out"
  _ngrep "delete homeproxy.control.lan_direct_ipv4_ips" "$out"
  _ngrep "delete homeproxy.control.lan_direct_ipv6_ips" "$out"
}

test_homeproxy_hy2_node_selfsigned() {
  _prep "$PROXY_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/hp.uci"
  : >"$out"
  render_homeproxy_batch "$out"
  _grep "set homeproxy.hp_hy2=node" "$out"
  _grep "set homeproxy.hp_hy2.type='hysteria2'" "$out"
  _grep "set homeproxy.hp_hy2.address='203.0.113.7'" "$out"
  _grep "set homeproxy.hp_hy2.port='443'" "$out"
  _grep "set homeproxy.hp_hy2.password='hy2pass'" "$out"
  _grep "set homeproxy.hp_hy2.hysteria_obfs_type='salamander'" "$out"
  _grep "set homeproxy.hp_hy2.hysteria_obfs_password='salampass'" "$out"
  _grep "set homeproxy.hp_hy2.tls='1'" "$out"
  _grep "set homeproxy.hp_hy2.tls_sni='203.0.113.7'" "$out"
  _grep "set homeproxy.hp_hy2.tls_insecure='0'" "$out"
  _grep "set homeproxy.hp_hy2.tls_self_sign='1'" "$out"
  _grep "set homeproxy.hp_hy2.tls_cert_path=" "$out"
  _grep "/etc/homeproxy/certs/hy2-server.pem" "$out"
  # Never fall back to insecure TLS.
  _ngrep "set homeproxy.hp_hy2.tls_insecure='1'" "$out"
}

test_homeproxy_hy2_letsencrypt_no_selfsign() {
  _prep "$LE_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/hp.uci"
  : >"$out"
  render_homeproxy_batch "$out"
  _grep "set homeproxy.hp_hy2.tls='1'" "$out"
  _grep "set homeproxy.hp_hy2.tls_insecure='0'" "$out"
  _grep "set homeproxy.hp_hy2.tls_sni='hy2.example.com'" "$out"
  _ngrep "set homeproxy.hp_hy2.tls_self_sign='1'" "$out"
  _ngrep "set homeproxy.hp_hy2.tls_cert_path=" "$out"
}

test_homeproxy_reality_node() {
  _prep "$PROXY_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/hp.uci"
  : >"$out"
  render_homeproxy_batch "$out"
  _grep "set homeproxy.hp_reality=node" "$out"
  _grep "set homeproxy.hp_reality.type='vless'" "$out"
  _grep "set homeproxy.hp_reality.uuid='11111111-2222-3333-4444-555555555555'" "$out"
  _grep "set homeproxy.hp_reality.vless_flow='xtls-rprx-vision'" "$out"
  _grep "set homeproxy.hp_reality.tls='1'" "$out"
  _grep "set homeproxy.hp_reality.tls_sni='www.microsoft.com'" "$out"
  _grep "set homeproxy.hp_reality.tls_reality='1'" "$out"
  _grep "set homeproxy.hp_reality.tls_reality_public_key='REALITYPUBKEY0001'" "$out"
  _grep "set homeproxy.hp_reality.tls_reality_short_id='0a1b2c3d'" "$out"
  _grep "set homeproxy.hp_reality.tls_utls='chrome'" "$out"
  _grep "set homeproxy.hp_reality.tls_insecure='0'" "$out"
}

test_homeproxy_main_node_switchable() {
  _prep "$PROXY_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/hp.uci"
  : >"$out"
  render_homeproxy_batch "$out"
  # Both nodes exist so the user can switch main_node in LuCI; HY2 is default.
  _grep "set homeproxy.hp_hy2=node" "$out"
  _grep "set homeproxy.hp_reality=node" "$out"
  _grep "set homeproxy.config.main_node='hp_hy2'" "$out"
}

test_homeproxy_hopping_ports() {
  local cfg='
LAN_ADDRESS="10.192.0.1/24"
VPS_IPV4="203.0.113.7"
HY2_PORT="443"
HY2_PORTS="20000:30000"
HY2_PASSWORD="hy2pass"
HY2_OBFS_PASSWORD="salampass"
HY2_CERT_MODE="selfsigned"
HY2_CERT_PEM_B64="__HY2_CERT_B64__"
REALITY_UUID="11111111-2222-3333-4444-555555555555"
REALITY_PUBLIC_KEY="k"
REALITY_SHORT_ID="s"
REALITY_TARGET_NAME="www.microsoft.com"
'
  cfg="${cfg//__HY2_CERT_B64__/$HY2_TEST_CERT_B64}"
  _prep "$cfg"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/hp.uci"
  : >"$out"
  render_homeproxy_batch "$out"
  _grep "add_list homeproxy.hp_hy2.hysteria_hopping_port='20000:30000'" "$out"
}

test_homeproxy_absent_without_vps() {
  _prep "$VALID_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/hp.uci"
  : >"$out"
  render_homeproxy_batch "$out"
  _ngrep "homeproxy.config" "$out"
  _ngrep "=node" "$out"
}

# ==================== Firewall / uhttpd / acme ====================

test_firewall_luci_public_ipv6_only() {
  _prep "$VALID_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/fw.uci"
  render_firewall_batch "$out"
  _grep "set firewall.luci_public_in.src='wan'" "$out"
  _grep "set firewall.luci_public_in.proto='tcp'" "$out"
  _grep "set firewall.luci_public_in.dest_port='10443'" "$out"
  _grep "set firewall.luci_public_in.family='ipv6'" "$out"
  _grep "set firewall.luci_public_in.target='ACCEPT'" "$out"
}

test_uhttpd_ipv6_only_https() {
  _prep "$VALID_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/uh.uci"
  : >"$out"
  render_uhttpd_batch "$out"
  _grep "set uhttpd.vpnpublic=uhttpd" "$out"
  _grep "add_list uhttpd.vpnpublic.listen_https='[::]:10443'" "$out"
  _grep "set uhttpd.vpnpublic.redirect_https='0'" "$out"
  _grep "delete uhttpd.vpnpublic.listen_http" "$out"
  _grep "luci-public.crt" "$out"
  _grep "luci-public.key" "$out"
  # No plain-HTTP listener and no IPv4 bind.
  _ngrep "uhttpd.vpnpublic.listen_http='" "$out"
  _ngrep "0.0.0.0:" "$out"
}

test_uhttpd_letsencrypt_cert_path() {
  _prep "$LE_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/uh.uci"
  : >"$out"
  render_uhttpd_batch "$out"
  _grep "/etc/acme/home.example.com/fullchain.cer" "$out"
  _grep "/etc/acme/home.example.com/home.example.com.key" "$out"
}

test_uhttpd_ubus_prefix_for_luci() {
  _prep "$VALID_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/uh.uci"
  : >"$out"
  render_uhttpd_batch "$out"
  # ubus_prefix is what makes LuCI's ubus-rpc calls resolve on this instance;
  # max_requests/max_connections mirror the factory 'main' uhttpd instance.
  _grep "set uhttpd.vpnpublic.ubus_prefix='/ubus'" "$out"
  _grep "set uhttpd.vpnpublic.max_requests='3'" "$out"
  _grep "set uhttpd.vpnpublic.max_connections='100'" "$out"
  _grep "set uhttpd.vpnpublic.cgi_prefix='/cgi-bin'" "$out"
}

test_acme_letsencrypt_dns_cf() {
  _prep "$LE_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/acme.uci"
  : >"$out"
  render_acme_batch "$out"
  _grep "set acme.luci_public=cert" "$out"
  _grep "set acme.luci_public.validation_method='dns'" "$out"
  _grep "set acme.luci_public.dns='dns_cf'" "$out"
  _grep "add_list acme.luci_public.domains='home.example.com'" "$out"
  _grep "add_list acme.luci_public.credentials='CF_Token=token456'" "$out"
  _grep "add_list acme.luci_public.credentials='CF_Zone_ID=zone123'" "$out"
}

test_acme_absent_when_selfsigned() {
  _prep "$PROXY_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/acme.uci"
  : >"$out"
  render_acme_batch "$out"
  _ngrep "acme.luci_public" "$out"
}

# ==================== Cloudflare AAAA DDNS ====================

test_ddns_enabled_gating() {
  _prep "$DDNS_CONFIG"
  trap remove_fixture EXIT
  assert_success ddns_enabled
}

test_ddns_disabled_without_domain() {
  _prep "$PROXY_CONFIG"
  trap remove_fixture EXIT
  assert_failure ddns_enabled
}

test_ddns_updater_stable_gua_dns_only() {
  _prep "$DDNS_CONFIG"
  trap remove_fixture EXIT
  local f="$TEST_ROOT/ddns.sh"
  render_ddns_updater "$f"
  assert_eq "700" "$(stat -c '%a' "$f")" "updater mode 0700"
  _grep "api.cloudflare.com" "$f"
  _grep '"proxied":false' "$f"
  _grep "home.example.com" "$f"
  _grep "token456" "$f"
  _grep "zone123" "$f"
  # Stable-GUA selection skips temporary/deprecated addresses.
  _grep "scope global" "$f"
  _grep "temporary" "$f"
  _grep "deprecated" "$f"
}

test_ddns_updater_uses_bearer_api_token() {
  _prep "$DDNS_CONFIG"
  trap remove_fixture EXIT
  local f="$TEST_ROOT/ddns.sh"
  render_ddns_updater "$f"
  # The Cloudflare auth header must reference the API_TOKEN variable (Bearer
  # scheme), and the token must be defined exactly once via API_TOKEN=.
  _grep 'auth="Authorization: Bearer ${API_TOKEN}"' "$f"
  _grep 'API_TOKEN=' "$f"
  # curl must send the header through the $auth variable, never a literal token.
  _grep 'curl -fsS -H "$auth"' "$f"
  # The secret value must never be inlined on the Authorization header line.
  local auth_line
  auth_line="$(grep -F 'Authorization:' "$f" || true)"
  case "$auth_line" in
    *token456*) fail "the token must not appear in the Authorization header line" ;;
  esac
}

test_ddns_hotplug_triggers_on_wan6() {
  _prep "$DDNS_CONFIG"
  trap remove_fixture EXIT
  local f="$TEST_ROOT/hotplug"
  render_ddns_hotplug "$f"
  assert_eq "755" "$(stat -c '%a' "$f")" "hotplug mode 0755"
  _grep 'ifup' "$f"
  _grep 'wan6' "$f"
  _grep 'wanpppoe6' "$f"
  _grep "cloudflare-aaaa.sh" "$f"
}

test_ddns_crontab_entry() {
  _prep "$DDNS_CONFIG"
  trap remove_fixture EXIT
  local f="$TEST_ROOT/cron"
  render_ddns_crontab "$f"
  _grep "cloudflare-aaaa.sh" "$f"
  _grep "#vpn-node-ddns" "$f"
  _grepe "^\*/[0-9]+ " "$f"
}

# ==================== Full install (Task-4 artifacts) ====================

test_install_writes_proxy_luci_ddns_artifacts() {
  _prep "$DDNS_CONFIG"
  trap remove_fixture EXIT
  local rc=0
  ( install_client ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc == 0)) || fail "install_client must succeed for a full proxy+ddns config"
  grep -q "homeproxy.config.routing_mode='gfwlist'" "$TEST_ROOT/uci-cmd.log" ||
    fail "homeproxy config must be applied"
  grep -q "uhttpd.vpnpublic" "$TEST_ROOT/uci-cmd.log" ||
    fail "public uhttpd instance must be applied"
  [[ -f "$HY2_CA_FILE" ]] || fail "HY2 self-signed trust anchor not installed"
  [[ -f "$LUCI_PUBLIC_CRT" && -f "$LUCI_PUBLIC_KEY_FILE" ]] ||
    fail "public LuCI self-signed cert/key not installed"
  [[ -f "$DDNS_UPDATER" ]] || fail "DDNS updater not installed"
  assert_eq "700" "$(stat -c '%a' "$DDNS_UPDATER")" "updater mode"
  [[ -f "$DDNS_HOTPLUG" ]] || fail "DDNS hotplug hook not installed"
  grep -q "#vpn-node-ddns" "$CRONTAB_ROOT" || fail "DDNS cron entry not installed"
  grep -q '^ARGS: uhttpd reload' "$TEST_ROOT/service-args.log" ||
    fail "public uhttpd must be reloaded"
  grep -q '^ARGS: homeproxy restart' "$TEST_ROOT/service-args.log" ||
    fail "homeproxy must be restarted"
  grep -q '^ARGS: cron restart' "$TEST_ROOT/service-args.log" ||
    fail "cron must be restarted for the DDNS job"
}

test_install_selfsigned_luci_has_no_acme() {
  _prep "$PROXY_CONFIG"
  trap remove_fixture EXIT
  local rc=0
  ( install_client ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc == 0)) || fail "install_client must succeed"
  [[ -f "$LUCI_PUBLIC_CRT" ]] || fail "self-signed LuCI cert must be generated"
  ! grep -q "acme.luci_public" "$TEST_ROOT/uci-cmd.log" ||
    fail "no acme config in self-signed mode"
  # DDNS not configured here.
  [[ ! -e "$DDNS_UPDATER" ]] || fail "no DDNS updater without a home domain"
}

test_rollback_removes_task4_artifacts() {
  _prep "$DDNS_CONFIG"
  trap remove_fixture EXIT
  install -d -m 0755 "$UCI_CONFIG_DIR"
  printf '# PRIOR-NETWORK\n' >"$NETWORK_CONFIG"
  # Commit succeeds; a service reload fails, so rollback must remove every new
  # Task-4 artifact and restore the prior config.
  touch "$TEST_ROOT/ctl/service_fail"
  local rc=0
  ( install_client ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc != 0)) || fail "install must fail when a service reload fails"
  _grep "# PRIOR-NETWORK" "$NETWORK_CONFIG"
  [[ ! -e "$HY2_CA_FILE" ]] || fail "HY2 trust anchor must be rolled back"
  [[ ! -e "$LUCI_PUBLIC_CRT" ]] || fail "LuCI cert must be rolled back"
  [[ ! -e "$DDNS_UPDATER" ]] || fail "DDNS updater must be rolled back"
  [[ ! -e "$DDNS_HOTPLUG" ]] || fail "DDNS hotplug must be rolled back"
}

test_no_login_lockout_mechanism() {
  # The design explicitly forbids a login-attempt lockout for public LuCI.
  ! grep -qi 'fail2ban' "$SCRIPT_PATH" || fail "must not implement fail2ban"
  ! grep -qi 'lockout' "$SCRIPT_PATH" || fail "must not implement a login lockout"
}

# ==================== Runner ====================

run_test "valid config passes" test_valid_config_passes
run_test "config must be root-owned" test_config_must_be_root_owned
run_test "config rejects group-writable perms" test_config_rejects_group_writable_perms
run_test "config rejects symlink" test_config_rejects_symlink

run_test "rejects bad LAN_ADDRESS" test_rejects_bad_lan_address
run_test "rejects PPPoE username without password" test_rejects_pppoe_username_without_password
run_test "rejects PPPoE metric not lower than DHCP" test_rejects_pppoe_metric_not_lower_than_dhcp
run_test "rejects bad WG port" test_rejects_bad_wg_port
run_test "rejects equal WG ports" test_rejects_equal_wg_ports
run_test "rejects bad WG address" test_rejects_bad_wg_address
run_test "rejects bad MTU" test_rejects_bad_mtu
run_test "rejects peer missing address" test_rejects_peer_missing_address
run_test "rejects duplicate peer address" test_rejects_duplicate_peer_address
run_test "accepts valid config with peers" test_accepts_valid_config_with_peers

run_test "is_physical accepts ethernet" test_is_physical_accepts_ethernet
run_test "is_physical rejects loopback" test_is_physical_rejects_loopback
run_test "is_physical rejects bridge" test_is_physical_rejects_bridge
run_test "is_physical rejects tun" test_is_physical_rejects_tun
run_test "is_physical rejects wireguard dir" test_is_physical_rejects_wireguard_dir
run_test "is_physical rejects wireguard devtype" test_is_physical_rejects_wireguard_devtype
run_test "is_physical rejects no hardware" test_is_physical_rejects_no_hardware
run_test "is_physical rejects nonexistent" test_is_physical_rejects_nonexistent
run_test "list_physical filters virtual" test_list_physical_filters_virtual

run_test "validate selection rejects identical" test_validate_selection_rejects_identical
run_test "validate selection rejects nonexistent" test_validate_selection_rejects_nonexistent
run_test "validate selection rejects virtual" test_validate_selection_rejects_virtual
run_test "prompt selects WAN and LAN" test_prompt_selects_wan_lan
run_test "prompt rejects identical selection" test_prompt_rejects_identical_selection
run_test "prompt rejects out-of-range" test_prompt_rejects_out_of_range
run_test "prompt requires two devices" test_prompt_requires_two_devices

run_test "network DHCP-only" test_network_dhcp_only
run_test "network PPPoE and DHCP metrics" test_network_pppoe_and_dhcp_metrics
run_test "network LAN" test_network_lan
run_test "network WG interfaces differ" test_network_wg_interfaces_differ
run_test "network WG peer /32" test_network_wg_peer_slash32
run_test "no hardcoded device names" test_no_hardcoded_device_names

run_test "firewall LAN zone includes WG" test_firewall_lan_zone_includes_wg
run_test "firewall WAN zone includes WAN6" test_firewall_wan_zone_includes_wan6
run_test "firewall WG rules IPv6-only" test_firewall_wg_rules_ipv6_only

run_test "dhcp filters AAAA and disables LAN IPv6" test_dhcp_filters_aaaa_and_disables_lan_ipv6

run_test "server keys generated when absent" test_server_keys_generated_when_absent
run_test "server keys reused from state" test_server_keys_reused_from_state
run_test "peer without pubkey gets generated keypair" test_peer_without_pubkey_gets_generated_keypair
run_test "peer with pubkey uses placeholder private" test_peer_with_pubkey_uses_placeholder_private

run_test "peer template content and mode" test_peer_template_content_and_mode
run_test "peer endpoint IPv6 literal is bracketed" test_peer_endpoint_ipv6_literal_is_bracketed
run_test "peer endpoint hostname is unbracketed" test_peer_endpoint_hostname_is_unbracketed
run_test "peer endpoint IPv4 literal is unbracketed" test_peer_endpoint_ipv4_literal_is_unbracketed

run_test "successful install writes all artifacts" test_successful_install_writes_all_artifacts
run_test "rollback on validation failure leaves nothing" test_rollback_on_validation_failure_leaves_nothing
run_test "rollback on uci commit failure" test_rollback_on_uci_commit_failure
run_test "rollback after commit restores prior" test_rollback_after_commit_restores_prior
run_test "no connectivity wait or rollback" test_no_connectivity_wait_or_rollback

run_test "check makes no live mutation" test_check_makes_no_live_mutation

run_test "show-wireguard prints after install" test_show_wireguard_prints_after_install
run_test "show-wireguard missing state fails" test_show_wireguard_missing_state_fails

run_test "ensure_packages installs wireguard-tools" test_ensure_packages_installs_wireguard_tools
run_test "ensure_packages adds pppoe when configured" test_ensure_packages_adds_pppoe_when_configured
run_test "ensure_packages uses luci-app-homeproxy" test_ensure_packages_uses_luci_app_homeproxy

run_test "rejects bad HY2_CERT_MODE" test_rejects_bad_hy2_cert_mode
run_test "rejects bad LUCI_CERT_MODE" test_rejects_bad_luci_cert_mode
run_test "rejects bad LUCI_PUBLIC_PORT" test_rejects_bad_luci_port
run_test "rejects proxy without password" test_rejects_proxy_without_password
run_test "rejects selfsigned without pem" test_rejects_selfsigned_without_pem
run_test "rejects legacy HY2_CERT_PIN" test_rejects_legacy_hy2_cert_pin
run_test "rejects selfsigned bad base64" test_rejects_selfsigned_bad_base64
run_test "hy2 trust anchor decoded to pem 0644" test_hy2_ca_file_decoded_to_pem_0644
run_test "accepts full proxy config" test_accepts_full_proxy_config
run_test "rejects home domain without token" test_rejects_home_domain_without_token
run_test "rejects LE LuCI without domain" test_rejects_le_luci_without_domain

run_test "homeproxy gfwlist IPv4-only" test_homeproxy_gfwlist_ipv4_only
run_test "homeproxy resource cron" test_homeproxy_resource_cron
run_test "homeproxy wg-global source global proxy" test_homeproxy_wg_global_source_global_proxy
run_test "homeproxy manual lists preserved" test_homeproxy_manual_lists_preserved
run_test "homeproxy HY2 node selfsigned" test_homeproxy_hy2_node_selfsigned
run_test "homeproxy HY2 letsencrypt no selfsign" test_homeproxy_hy2_letsencrypt_no_selfsign
run_test "homeproxy REALITY node" test_homeproxy_reality_node
run_test "homeproxy main node switchable" test_homeproxy_main_node_switchable
run_test "homeproxy hopping ports" test_homeproxy_hopping_ports
run_test "homeproxy absent without VPS" test_homeproxy_absent_without_vps

run_test "firewall LuCI public IPv6-only" test_firewall_luci_public_ipv6_only
run_test "uhttpd IPv6-only HTTPS" test_uhttpd_ipv6_only_https
run_test "uhttpd letsencrypt cert path" test_uhttpd_letsencrypt_cert_path
run_test "uhttpd ubus_prefix for LuCI" test_uhttpd_ubus_prefix_for_luci
run_test "acme letsencrypt dns_cf" test_acme_letsencrypt_dns_cf
run_test "acme absent when selfsigned" test_acme_absent_when_selfsigned

run_test "ddns enabled gating" test_ddns_enabled_gating
run_test "ddns disabled without domain" test_ddns_disabled_without_domain
run_test "ddns updater stable GUA DNS-only" test_ddns_updater_stable_gua_dns_only
run_test "ddns updater uses Bearer API_TOKEN" test_ddns_updater_uses_bearer_api_token
run_test "ddns hotplug triggers on wan6" test_ddns_hotplug_triggers_on_wan6
run_test "ddns crontab entry" test_ddns_crontab_entry

run_test "install writes proxy/LuCI/DDNS artifacts" test_install_writes_proxy_luci_ddns_artifacts
run_test "install selfsigned LuCI has no acme" test_install_selfsigned_luci_has_no_acme
run_test "rollback removes Task-4 artifacts" test_rollback_removes_task4_artifacts
run_test "no login lockout mechanism" test_no_login_lockout_mechanism

finish_tests
