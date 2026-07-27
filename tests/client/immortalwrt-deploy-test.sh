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
  _grep "add_list firewall.lan_zone.network='lan'" "$out"
  _grep "add_list firewall.lan_zone.network='wg_global'" "$out"
  _grep "add_list firewall.lan_zone.network='wg_local'" "$out"
  _grep "set firewall.lan_wan.dest='wan'" "$out"
}

test_firewall_wan_zone_includes_wan6() {
  _prep "$PPPOE_CONFIG"
  trap remove_fixture EXIT
  local out="$TEST_ROOT/fw.uci"
  render_firewall_batch "$out"
  _grep "add_list firewall.wan_zone.network='wan'" "$out"
  _grep "add_list firewall.wan_zone.network='wan6'" "$out"
  _grep "add_list firewall.wan_zone.network='wanpppoe'" "$out"
  _grep "add_list firewall.wan_zone.network='wanpppoe6'" "$out"
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
  _grep "Endpoint = [YOUR_HOME_IPV6_OR_DDNS_DOMAIN]:51820" "$f"
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
  # Static guarantee: no polling/carrier/ping/ubus status wait exists.
  ! grep -Eq '\bping\b|operstate|carrier|ubus' "$SCRIPT_PATH" ||
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

finish_tests
