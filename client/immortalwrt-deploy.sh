#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# ==================== Constants and paths ====================

readonly MANAGED_MARKER_TEXT="Managed by vpn-node-maintenance: immortalwrt-deploy.sh"
readonly MANAGED_MARKER="# ${MANAGED_MARKER_TEXT}"

readonly CONFIG_FILE="${IMMORTALWRT_DEPLOY_CONFIG:-/etc/vpn-node/immortalwrt.env}"
readonly ROOT_PREFIX="${IMMORTALWRT_DEPLOY_ROOT:-}"

# Live (prefixed) target paths. Under a test root ($IMMORTALWRT_DEPLOY_ROOT set)
# every path is confined below that root so tests never touch real files; in
# production ROOT_PREFIX is empty and these are the real absolute paths.
readonly UCI_CONFIG_DIR="${ROOT_PREFIX}/etc/config"
readonly NETWORK_CONFIG="${UCI_CONFIG_DIR}/network"
readonly FIREWALL_CONFIG="${UCI_CONFIG_DIR}/firewall"
readonly DHCP_CONFIG="${UCI_CONFIG_DIR}/dhcp"
readonly WG_STATE_FILE="${ROOT_PREFIX}/etc/vpn-node/immortalwrt-wg-state.env"
readonly CLIENT_TEMPLATE_DIR="${ROOT_PREFIX}/etc/vpn-node/wg-clients"
readonly INSTALL_LOCK="${ROOT_PREFIX}/run/lock/immortalwrt-deploy.lock"
readonly TRANSACTION_DIR_ROOT="${ROOT_PREFIX}/run/immortalwrt-deploy"

# Logical interface / section names (never the physical device names).
readonly WAN_IFACE="wan"
readonly WAN6_IFACE="wan6"
readonly PPPOE_IFACE="wanpppoe"
readonly PPPOE6_IFACE="wanpppoe6"
readonly WG_GLOBAL_IFACE="wg_global"
readonly WG_LOCAL_IFACE="wg_local"

# Interactive device selection results.
WAN_DEVICE=""
LAN_DEVICE=""

# Transaction state.
TXN_DIR=""
STAGED_BATCH=""
STAGED_STATE=""
STAGED_CLIENTS=""
TRANSACTION_ACTIVE=0
ROLLBACK_RUNNING=0
declare -ga SNAPSHOT_TARGETS=()
declare -gA SNAPSHOT_EXISTED=()
declare -gA SNAPSHOT_MODE=()
declare -gA SNAPSHOT_ISDIR=()

# Resolved WireGuard material (populated at run time).
WG_GLOBAL_PRIVATE_KEY=""
WG_GLOBAL_PUBLIC_KEY=""
WG_LOCAL_PRIVATE_KEY=""
WG_LOCAL_PUBLIC_KEY=""
declare -ga PEER_IFACE=()
declare -ga PEER_NAME=()
declare -ga PEER_ADDR=()
declare -ga PEER_PUB=()
declare -ga PEER_PRIV=()
declare -ga PEER_PSK=()
declare -ga PEER_KEEPALIVE=()
declare -ga PEER_PROVIDED_PUB=()
declare -ga PEER_STATEKEY=()

log() {
  printf '%s [immortalwrt-deploy] %s\n' "$(date --iso-8601=seconds)" "$*"
}

die() {
  log "ERROR: $*" >&2
  if ((TRANSACTION_ACTIVE)); then
    rollback_transaction 1
  fi
  exit 1
}

require_root() {
  ((EUID == 0)) || die "run as root"
}

# ==================== Seams (overridable by tests) ====================

# Where physical interfaces are enumerated. /sys cannot be PATH-shadowed, so a
# function seam lets tests point at a fake sysfs tree. Production reads the
# kernel's real interface list.
sysfs_net_dir() { printf '%s' "${IMMORTALWRT_SYSCLASSNET:-/sys/class/net}"; }

# WireGuard key helpers. Real binaries in production; tests PATH-shadow `wg`.
wg_genkey() { wg genkey; }
wg_pubkey() { wg pubkey; }

# ==================== Configuration loading and validation ====================

load_config() {
  [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] ||
    die "configuration must be a regular non-symlink file: $CONFIG_FILE"
  [[ "$(stat -c '%u' "$CONFIG_FILE")" == "0" ]] ||
    die "configuration must be owned by root"
  case "$(stat -c '%a' "$CONFIG_FILE")" in
    400|600) ;;
    *) die "configuration permissions must be 400 or 600" ;;
  esac
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  apply_defaults
}

apply_defaults() {
  LAN_ADDRESS="${LAN_ADDRESS:-10.192.0.1/24}"
  PPPOE_USERNAME="${PPPOE_USERNAME:-}"
  PPPOE_PASSWORD="${PPPOE_PASSWORD:-}"
  PPPOE_METRIC="${PPPOE_METRIC:-10}"
  DHCP_METRIC="${DHCP_METRIC:-20}"
  WG_GLOBAL_ADDRESS="${WG_GLOBAL_ADDRESS:-10.192.100.1/24}"
  WG_GLOBAL_PORT="${WG_GLOBAL_PORT:-51820}"
  WG_LOCAL_ADDRESS="${WG_LOCAL_ADDRESS:-10.192.200.1/24}"
  WG_LOCAL_PORT="${WG_LOCAL_PORT:-51821}"
  WG_MTU="${WG_MTU:-1380}"
  WG_ENDPOINT_HOST="${WG_ENDPOINT_HOST:-}"
  if ! declare -p WG_GLOBAL_PEERS >/dev/null 2>&1; then
    declare -ga WG_GLOBAL_PEERS=()
  fi
  if ! declare -p WG_LOCAL_PEERS >/dev/null 2>&1; then
    declare -ga WG_LOCAL_PEERS=()
  fi
  # Persisted/generated WireGuard material may already be sourced from state.
  WG_GLOBAL_PRIVATE_KEY="${WG_GLOBAL_PRIVATE_KEY:-}"
  WG_GLOBAL_PUBLIC_KEY="${WG_GLOBAL_PUBLIC_KEY:-}"
  WG_LOCAL_PRIVATE_KEY="${WG_LOCAL_PRIVATE_KEY:-}"
  WG_LOCAL_PUBLIC_KEY="${WG_LOCAL_PUBLIC_KEY:-}"
}

valid_ipv4() {
  local ip="$1" octet
  local -a parts
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a parts <<<"$ip"
  for octet in "${parts[@]}"; do
    ((10#"$octet" <= 255)) || return 1
  done
}

valid_ipv4_cidr() {
  local value="$1" ip prefix
  [[ "$value" == */* ]] || return 1
  ip="${value%/*}"
  prefix="${value#*/}"
  valid_ipv4 "$ip" || return 1
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  ((10#$prefix >= 0 && 10#$prefix <= 32)) || return 1
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

valid_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

prefix_to_netmask() {
  local prefix="$1" i mask="" bits octet
  for i in 0 1 2 3; do
    if ((prefix >= 8)); then
      bits=8
    elif ((prefix <= 0)); then
      bits=0
    else
      bits=$prefix
    fi
    if ((bits == 0)); then
      octet=0
    else
      octet=$((256 - 2 ** (8 - bits)))
    fi
    mask+="$octet"
    ((i < 3)) && mask+="."
    prefix=$((prefix - 8))
  done
  printf '%s' "$mask"
}

validate_config() {
  valid_ipv4_cidr "$LAN_ADDRESS" ||
    die "LAN_ADDRESS must be an IPv4 address in CIDR form (e.g. 10.192.0.1/24)"

  valid_uint "$PPPOE_METRIC" || die "PPPOE_METRIC must be a non-negative integer"
  valid_uint "$DHCP_METRIC" || die "DHCP_METRIC must be a non-negative integer"

  if [[ -n "$PPPOE_USERNAME" || -n "$PPPOE_PASSWORD" ]]; then
    [[ -n "$PPPOE_USERNAME" && -n "$PPPOE_PASSWORD" ]] ||
      die "PPPOE_USERNAME and PPPOE_PASSWORD must be set together"
    ((10#$PPPOE_METRIC < 10#$DHCP_METRIC)) ||
      die "PPPOE_METRIC must be lower than DHCP_METRIC so PPPoE is preferred"
  fi

  valid_ipv4_cidr "$WG_GLOBAL_ADDRESS" ||
    die "WG_GLOBAL_ADDRESS must be an IPv4 address in CIDR form"
  valid_ipv4_cidr "$WG_LOCAL_ADDRESS" ||
    die "WG_LOCAL_ADDRESS must be an IPv4 address in CIDR form"
  valid_port "$WG_GLOBAL_PORT" || die "WG_GLOBAL_PORT must be between 1 and 65535"
  valid_port "$WG_LOCAL_PORT" || die "WG_LOCAL_PORT must be between 1 and 65535"
  [[ "$WG_GLOBAL_PORT" != "$WG_LOCAL_PORT" ]] ||
    die "WG_GLOBAL_PORT and WG_LOCAL_PORT must differ"

  valid_uint "$WG_MTU" && ((10#$WG_MTU >= 1280 && 10#$WG_MTU <= 1500)) ||
    die "WG_MTU must be between 1280 and 1500"

  validate_peer_entries "$WG_GLOBAL_IFACE" WG_GLOBAL_PEERS
  validate_peer_entries "$WG_LOCAL_IFACE" WG_LOCAL_PEERS
}

# Validates the raw peer array (name/address required, unique /32 per iface)
# without resolving keys. The array is passed by name.
validate_peer_entries() {
  local iface="$1" array_name="$2"
  local -n arr="$array_name"
  local entry name addr token key value
  local -a seen=()
  ((${#arr[@]} == 0)) && return 0
  for entry in "${arr[@]}"; do
    name=""
    addr=""
    for token in $entry; do
      key="${token%%=*}"
      value="${token#*=}"
      case "$key" in
        name) name="$value" ;;
        address) addr="$value" ;;
        public_key | pubkey | preshared_key | psk | keepalive) ;;
        *) die "unknown peer field '$key' in ${array_name} entry: $entry" ;;
      esac
    done
    [[ -n "$name" ]] || die "peer entry in ${array_name} is missing name=: $entry"
    [[ -n "$addr" ]] || die "peer '$name' in ${array_name} is missing address="
    valid_ipv4 "$addr" || die "peer '$name' address is not a valid IPv4: $addr"
    local s
    for s in "${seen[@]}"; do
      [[ "$s" == "$addr" ]] && die "duplicate peer address on ${iface}: $addr"
    done
    seen+=("$addr")
  done
}

# ==================== Device selection ====================

# A device is physical when it exists, is not the loopback, is not a bridge /
# tun / wireguard / other virtual type (by path markers and DEVTYPE), and is
# backed by real hardware (a "device" symlink under sysfs).
is_physical_device() {
  local dev="$1" base devtype
  base="$(sysfs_net_dir)/$dev"
  [[ -n "$dev" && -e "$base" ]] || return 1
  [[ "$dev" == "lo" ]] && return 1
  [[ -d "$base/bridge" ]] && return 1
  [[ -d "$base/wireguard" ]] && return 1
  [[ -e "$base/tun_flags" ]] && return 1
  if [[ -r "$base/uevent" ]]; then
    devtype="$(sed -n 's/^DEVTYPE=//p' "$base/uevent" 2>/dev/null || true)"
    case "$devtype" in
      bridge | wireguard | vlan | tun | bond | dummy) return 1 ;;
    esac
  fi
  [[ -e "$base/device" ]] || return 1
  return 0
}

list_physical_devices() {
  local base d name
  base="$(sysfs_net_dir)"
  [[ -d "$base" ]] || return 0
  for d in "$base"/*; do
    [[ -e "$d" ]] || continue
    name="$(basename "$d")"
    is_physical_device "$name" && printf '%s\n' "$name"
  done | sort
}

validate_device_selection() {
  local wan="$1" lan="$2"
  [[ -n "$wan" && -n "$lan" ]] || die "both WAN and LAN devices are required"
  is_physical_device "$wan" ||
    die "WAN device is not a valid physical device: $wan"
  is_physical_device "$lan" ||
    die "LAN device is not a valid physical device: $lan"
  [[ "$wan" != "$lan" ]] ||
    die "WAN and LAN must be different physical devices: $wan"
}

_valid_choice() {
  local choice="$1" count="$2"
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  ((10#$choice >= 1 && 10#$choice <= count))
}

prompt_device_selection() {
  local -a devs=()
  mapfile -t devs < <(list_physical_devices)
  ((${#devs[@]} >= 2)) ||
    die "need at least two physical network devices; found ${#devs[@]}"
  {
    printf 'Available physical network devices:\n'
    local i
    for i in "${!devs[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${devs[i]}"
    done
  } >&2
  local wan_choice lan_choice
  read -r -p 'Select WAN device number: ' wan_choice ||
    die "no WAN device selection provided"
  read -r -p 'Select LAN device number: ' lan_choice ||
    die "no LAN device selection provided"
  _valid_choice "$wan_choice" "${#devs[@]}" ||
    die "invalid WAN selection: $wan_choice"
  _valid_choice "$lan_choice" "${#devs[@]}" ||
    die "invalid LAN selection: $lan_choice"
  WAN_DEVICE="${devs[$((wan_choice - 1))]}"
  LAN_DEVICE="${devs[$((lan_choice - 1))]}"
  validate_device_selection "$WAN_DEVICE" "$LAN_DEVICE"
  log "selected WAN=${WAN_DEVICE} LAN=${LAN_DEVICE}"
}

# ==================== WireGuard material ====================

_ident() { printf '%s' "$1" | tr -cs 'A-Za-z0-9' '_'; }
_upper() { printf '%s' "${1^^}"; }

resolve_wireguard_material() {
  if [[ -f "$WG_STATE_FILE" && ! -L "$WG_STATE_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$WG_STATE_FILE"
  fi
  [[ -n "$WG_GLOBAL_PRIVATE_KEY" ]] || WG_GLOBAL_PRIVATE_KEY="$(wg_genkey)"
  [[ -n "$WG_GLOBAL_PUBLIC_KEY" ]] ||
    WG_GLOBAL_PUBLIC_KEY="$(printf '%s' "$WG_GLOBAL_PRIVATE_KEY" | wg_pubkey)"
  [[ -n "$WG_LOCAL_PRIVATE_KEY" ]] || WG_LOCAL_PRIVATE_KEY="$(wg_genkey)"
  [[ -n "$WG_LOCAL_PUBLIC_KEY" ]] ||
    WG_LOCAL_PUBLIC_KEY="$(printf '%s' "$WG_LOCAL_PRIVATE_KEY" | wg_pubkey)"
  [[ -n "$WG_GLOBAL_PRIVATE_KEY" && -n "$WG_GLOBAL_PUBLIC_KEY" &&
    -n "$WG_LOCAL_PRIVATE_KEY" && -n "$WG_LOCAL_PUBLIC_KEY" ]] ||
    die "failed to resolve WireGuard server keys"

  PEER_IFACE=()
  PEER_NAME=()
  PEER_ADDR=()
  PEER_PUB=()
  PEER_PRIV=()
  PEER_PSK=()
  PEER_KEEPALIVE=()
  PEER_PROVIDED_PUB=()
  PEER_STATEKEY=()
  _resolve_peer_array "$WG_GLOBAL_IFACE" WG_GLOBAL_PEERS
  _resolve_peer_array "$WG_LOCAL_IFACE" WG_LOCAL_PEERS
}

_resolve_peer_array() {
  local iface="$1" array_name="$2"
  local -n arr="$array_name"
  ((${#arr[@]} == 0)) && return 0
  local entry
  for entry in "${arr[@]}"; do
    _resolve_peer_entry "$iface" "$entry"
  done
}

_resolve_peer_entry() {
  local iface="$1" entry="$2"
  local name="" addr="" pub="" psk="" keepalive="25" token key value
  for token in $entry; do
    key="${token%%=*}"
    value="${token#*=}"
    case "$key" in
      name) name="$value" ;;
      address) addr="$value" ;;
      public_key | pubkey) pub="$value" ;;
      preshared_key | psk) psk="$value" ;;
      keepalive) keepalive="$value" ;;
    esac
  done
  local provided=0 priv="" statekey=""
  if [[ -n "$pub" ]]; then
    provided=1
  else
    statekey="WG_PEER_$(_upper "$(_ident "$iface")")_$(_upper "$(_ident "$name")")"
    local priv_var="${statekey}_PRIVATE" pub_var="${statekey}_PUBLIC"
    priv="${!priv_var:-}"
    pub="${!pub_var:-}"
    if [[ -z "$priv" ]]; then
      priv="$(wg_genkey)"
      pub="$(printf '%s' "$priv" | wg_pubkey)"
    elif [[ -z "$pub" ]]; then
      pub="$(printf '%s' "$priv" | wg_pubkey)"
    fi
  fi
  PEER_IFACE+=("$iface")
  PEER_NAME+=("$name")
  PEER_ADDR+=("$addr")
  PEER_PUB+=("$pub")
  PEER_PRIV+=("$priv")
  PEER_PSK+=("$psk")
  PEER_KEEPALIVE+=("$keepalive")
  PEER_PROVIDED_PUB+=("$provided")
  PEER_STATEKEY+=("$statekey")
}

render_wg_state_file() {
  local out="$1" i
  {
    printf '%s\n' "$MANAGED_MARKER"
    printf 'WG_GLOBAL_PRIVATE_KEY=%q\n' "$WG_GLOBAL_PRIVATE_KEY"
    printf 'WG_GLOBAL_PUBLIC_KEY=%q\n' "$WG_GLOBAL_PUBLIC_KEY"
    printf 'WG_LOCAL_PRIVATE_KEY=%q\n' "$WG_LOCAL_PRIVATE_KEY"
    printf 'WG_LOCAL_PUBLIC_KEY=%q\n' "$WG_LOCAL_PUBLIC_KEY"
    for i in "${!PEER_IFACE[@]}"; do
      [[ "${PEER_PROVIDED_PUB[i]}" == "0" && -n "${PEER_STATEKEY[i]}" ]] || continue
      printf '%s_PRIVATE=%q\n' "${PEER_STATEKEY[i]}" "${PEER_PRIV[i]}"
      printf '%s_PUBLIC=%q\n' "${PEER_STATEKEY[i]}" "${PEER_PUB[i]}"
    done
  } >"$out"
  chmod 0600 "$out"
}

# ==================== UCI batch rendering ====================

# Single-quote a value for a uci batch line, escaping embedded single quotes.
_q() {
  local s="${1//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

_set() { printf 'set %s=%s\n' "$1" "$2"; }
_setq() { printf 'set %s=%s\n' "$1" "$(_q "$2")"; }
_addlist() { printf 'add_list %s=%s\n' "$1" "$(_q "$2")"; }
_del() { printf 'delete %s\n' "$1"; }

# Format a WireGuard endpoint host for a client template. IPv6 literals (which
# contain a colon) must be wrapped in brackets; hostnames, DDNS domains, and
# IPv4 literals are emitted verbatim.
_format_wg_endpoint_host() {
  local host="$1"
  if [[ "$host" == *:* ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

_render_wg_interface_batch() {
  local iface="$1" address="$2" port="$3" privkey="$4"
  _set "network.${iface}" "interface"
  _setq "network.${iface}.proto" "wireguard"
  _setq "network.${iface}.private_key" "$privkey"
  _setq "network.${iface}.listen_port" "$port"
  _setq "network.${iface}.mtu" "$WG_MTU"
  _addlist "network.${iface}.addresses" "$address"
}

_render_wg_peers_batch() {
  local i iface name addr pub psk keepalive sec
  for i in "${!PEER_IFACE[@]}"; do
    iface="${PEER_IFACE[i]}"
    name="${PEER_NAME[i]}"
    addr="${PEER_ADDR[i]}"
    pub="${PEER_PUB[i]}"
    psk="${PEER_PSK[i]}"
    keepalive="${PEER_KEEPALIVE[i]}"
    sec="wgpeer_${iface}_$(_ident "$name")"
    _set "network.${sec}" "wireguard_${iface}"
    _setq "network.${sec}.public_key" "$pub"
    _setq "network.${sec}.description" "$name"
    _addlist "network.${sec}.allowed_ips" "${addr}/32"
    [[ -n "$psk" ]] && _setq "network.${sec}.preshared_key" "$psk"
    _setq "network.${sec}.persistent_keepalive" "${keepalive:-25}"
    _setq "network.${sec}.route_allowed_ips" "1"
  done
}

render_network_batch() {
  local out="$1" lan_ip lan_prefix lan_mask
  lan_ip="${LAN_ADDRESS%/*}"
  lan_prefix="${LAN_ADDRESS#*/}"
  lan_mask="$(prefix_to_netmask "$lan_prefix")"
  {
    # LAN
    _set "network.lan" "interface"
    _setq "network.lan.proto" "static"
    _setq "network.lan.device" "$LAN_DEVICE"
    _setq "network.lan.ipaddr" "$lan_ip"
    _setq "network.lan.netmask" "$lan_mask"

    # DHCP WAN (always) on the physical WAN device.
    _set "network.${WAN_IFACE}" "interface"
    _setq "network.${WAN_IFACE}.proto" "dhcp"
    _setq "network.${WAN_IFACE}.device" "$WAN_DEVICE"
    _setq "network.${WAN_IFACE}.metric" "$DHCP_METRIC"

    # DHCPv6-PD tied to the DHCP WAN path (references the logical interface).
    _set "network.${WAN6_IFACE}" "interface"
    _setq "network.${WAN6_IFACE}.proto" "dhcpv6"
    _setq "network.${WAN6_IFACE}.device" "@${WAN_IFACE}"
    _setq "network.${WAN6_IFACE}.reqaddress" "try"
    _setq "network.${WAN6_IFACE}.reqprefix" "auto"

    if [[ -n "$PPPOE_USERNAME" ]]; then
      # PPPoE WAN on the same physical device, preferred via a lower metric.
      _set "network.${PPPOE_IFACE}" "interface"
      _setq "network.${PPPOE_IFACE}.proto" "pppoe"
      _setq "network.${PPPOE_IFACE}.device" "$WAN_DEVICE"
      _setq "network.${PPPOE_IFACE}.username" "$PPPOE_USERNAME"
      _setq "network.${PPPOE_IFACE}.password" "$PPPOE_PASSWORD"
      _setq "network.${PPPOE_IFACE}.metric" "$PPPOE_METRIC"
      # IPv6 on the PPPoE link is handled by the dedicated wanpppoe6 dhcpv6
      # logical interface below, so disable the PPPoE interface's own automatic
      # IPv6 sub-interface to avoid a redundant/conflicting second IPv6 client.
      _setq "network.${PPPOE_IFACE}.ipv6" "0"

      # DHCPv6-PD tied to the PPPoE WAN path.
      _set "network.${PPPOE6_IFACE}" "interface"
      _setq "network.${PPPOE6_IFACE}.proto" "dhcpv6"
      _setq "network.${PPPOE6_IFACE}.device" "@${PPPOE_IFACE}"
      _setq "network.${PPPOE6_IFACE}.reqaddress" "try"
      _setq "network.${PPPOE6_IFACE}.reqprefix" "auto"
    fi

    _render_wg_interface_batch "$WG_GLOBAL_IFACE" "$WG_GLOBAL_ADDRESS" \
      "$WG_GLOBAL_PORT" "$WG_GLOBAL_PRIVATE_KEY"
    _render_wg_interface_batch "$WG_LOCAL_IFACE" "$WG_LOCAL_ADDRESS" \
      "$WG_LOCAL_PORT" "$WG_LOCAL_PRIVATE_KEY"
    _render_wg_peers_batch
  } >>"$out"
}

render_firewall_batch() {
  local out="$1"
  {
    # Reuse the factory-default anonymous firewall zones instead of creating
    # second "lan"/"wan" zones (duplicate named zones break traffic policy).
    # On a factory ImmortalWrt/OpenWrt config @zone[0] is lan and @zone[1] is
    # wan; their default network lists are cleared before our members are added
    # so no stale/duplicate interface references remain.

    # LAN zone: LAN plus both WireGuard interfaces (peer-to-peer and LAN
    # access via intra-zone forwarding).
    _setq "firewall.@zone[0].name" "lan"
    _setq "firewall.@zone[0].input" "ACCEPT"
    _setq "firewall.@zone[0].output" "ACCEPT"
    _setq "firewall.@zone[0].forward" "ACCEPT"
    _del "firewall.@zone[0].network"
    _addlist "firewall.@zone[0].network" "lan"
    _addlist "firewall.@zone[0].network" "$WG_GLOBAL_IFACE"
    _addlist "firewall.@zone[0].network" "$WG_LOCAL_IFACE"

    # WAN zone: every possible WAN and WAN6 logical interface.
    _setq "firewall.@zone[1].name" "wan"
    _setq "firewall.@zone[1].input" "REJECT"
    _setq "firewall.@zone[1].output" "ACCEPT"
    _setq "firewall.@zone[1].forward" "REJECT"
    _setq "firewall.@zone[1].masq" "1"
    _setq "firewall.@zone[1].mtu_fix" "1"
    _del "firewall.@zone[1].network"
    _addlist "firewall.@zone[1].network" "$WAN_IFACE"
    _addlist "firewall.@zone[1].network" "$WAN6_IFACE"
    if [[ -n "$PPPOE_USERNAME" ]]; then
      _addlist "firewall.@zone[1].network" "$PPPOE_IFACE"
      _addlist "firewall.@zone[1].network" "$PPPOE6_IFACE"
    fi

    # Reuse the factory-default lan->wan forwarding rather than adding a second.
    _setq "firewall.@forwarding[0].src" "lan"
    _setq "firewall.@forwarding[0].dest" "wan"

    # WireGuard ingress: IPv6-only UDP on WAN, one rule per interface.
    _set "firewall.wg_global_in" "rule"
    _setq "firewall.wg_global_in.name" "Allow-WireGuard-Global-IPv6"
    _setq "firewall.wg_global_in.src" "wan"
    _setq "firewall.wg_global_in.proto" "udp"
    _setq "firewall.wg_global_in.dest_port" "$WG_GLOBAL_PORT"
    _setq "firewall.wg_global_in.family" "ipv6"
    _setq "firewall.wg_global_in.target" "ACCEPT"

    _set "firewall.wg_local_in" "rule"
    _setq "firewall.wg_local_in.name" "Allow-WireGuard-Local-IPv6"
    _setq "firewall.wg_local_in.src" "wan"
    _setq "firewall.wg_local_in.proto" "udp"
    _setq "firewall.wg_local_in.dest_port" "$WG_LOCAL_PORT"
    _setq "firewall.wg_local_in.family" "ipv6"
    _setq "firewall.wg_local_in.target" "ACCEPT"
  } >>"$out"
}

render_dhcp_batch() {
  local out="$1"
  {
    # Suppress AAAA answers so LAN/proxy traffic stays IPv4-only.
    _setq "dhcp.@dnsmasq[0].filter_aaaa" "1"

    # LAN: keep IPv4 DHCP, disable all IPv6 RA / DHCPv6 advertisement.
    _set "dhcp.lan" "dhcp"
    _setq "dhcp.lan.interface" "lan"
    _setq "dhcp.lan.start" "100"
    _setq "dhcp.lan.limit" "150"
    _setq "dhcp.lan.leasetime" "12h"
    _setq "dhcp.lan.ra" "disabled"
    _setq "dhcp.lan.dhcpv6" "disabled"
    _setq "dhcp.lan.ndp" "disabled"
  } >>"$out"
}

render_uci_batch() {
  local out="$1"
  : >"$out"
  render_network_batch "$out"
  render_firewall_batch "$out"
  render_dhcp_batch "$out"
}

# ==================== Client template rendering ====================

render_peer_template() {
  local dir="$1" iface="$2" name="$3" addr="$4" server_pub="$5" priv="$6" \
    psk="$7" port="$8" dns="$9"
  local file="${dir}/${iface}-$(_ident "$name").conf"
  {
    printf '%s\n' "$MANAGED_MARKER"
    printf '# WireGuard client template for peer "%s" on %s.\n' "$name" "$iface"
    printf '# Replace the Endpoint host with your home public IPv6 (bracketed\n'
    printf '# automatically) or the DDNS domain configured later.\n'
    printf '[Interface]\n'
    if [[ -n "$priv" ]]; then
      printf 'PrivateKey = %s\n' "$priv"
    else
      printf 'PrivateKey = %s\n' 'REPLACE_WITH_CLIENT_PRIVATE_KEY'
    fi
    printf 'Address = %s/32\n' "$addr"
    printf 'MTU = %s\n' "$WG_MTU"
    printf 'DNS = %s\n' "$dns"
    printf '\n[Peer]\n'
    printf 'PublicKey = %s\n' "$server_pub"
    [[ -n "$psk" ]] && printf 'PresharedKey = %s\n' "$psk"
    printf 'AllowedIPs = 0.0.0.0/0\n'
    printf 'Endpoint = %s:%s\n' \
      "$(_format_wg_endpoint_host "${WG_ENDPOINT_HOST:-YOUR_HOME_IPV6_OR_DDNS_DOMAIN}")" "$port"
    printf 'PersistentKeepalive = 25\n'
  } >"$file"
  chmod 0600 "$file"
}

render_all_peer_templates() {
  local dir="$1" i iface server_pub port dns
  install -d -m 0700 "$dir"
  for i in "${!PEER_IFACE[@]}"; do
    iface="${PEER_IFACE[i]}"
    if [[ "$iface" == "$WG_GLOBAL_IFACE" ]]; then
      server_pub="$WG_GLOBAL_PUBLIC_KEY"
      port="$WG_GLOBAL_PORT"
      dns="${WG_GLOBAL_ADDRESS%/*}"
    else
      server_pub="$WG_LOCAL_PUBLIC_KEY"
      port="$WG_LOCAL_PORT"
      dns="${WG_LOCAL_ADDRESS%/*}"
    fi
    render_peer_template "$dir" "$iface" "${PEER_NAME[i]}" "${PEER_ADDR[i]}" \
      "$server_pub" "${PEER_PRIV[i]}" "${PEER_PSK[i]}" "$port" "$dns"
  done
}

validate_peer_templates() {
  local dir="$1" f
  compgen -G "$dir/*.conf" >/dev/null || return 0
  for f in "$dir"/*.conf; do
    grep -qF '[Interface]' "$f" || return 1
    grep -qF '[Peer]' "$f" || return 1
    grep -qE '^AllowedIPs = 0\.0\.0\.0/0$' "$f" || return 1
    grep -qE '^PublicKey = .+' "$f" || return 1
  done
  return 0
}

# ==================== UCI apply / validation ====================

validate_uci_batch() {
  local file="$1" tmp
  tmp="$(mktemp -d)"
  if [[ -d "$UCI_CONFIG_DIR" ]]; then
    cp -a "$UCI_CONFIG_DIR/." "$tmp/" 2>/dev/null || true
  fi
  if ! uci -q -c "$tmp" batch <"$file" || ! uci -q -c "$tmp" commit; then
    rm -rf -- "$tmp"
    return 1
  fi
  rm -rf -- "$tmp"
  return 0
}

apply_uci_batch() {
  local file="$1"
  uci -c "$UCI_CONFIG_DIR" batch <"$file" || die "failed to apply UCI batch"
  uci -c "$UCI_CONFIG_DIR" commit || die "failed to commit UCI changes"
}

# ==================== Dependencies ====================

detect_pkg_manager() {
  if command -v opkg >/dev/null 2>&1; then
    printf 'opkg'
  elif command -v apk >/dev/null 2>&1; then
    printf 'apk'
  else
    return 1
  fi
}

ensure_dependencies() {
  local cmd missing=()
  for cmd in uci wg service; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  detect_pkg_manager >/dev/null 2>&1 || missing+=("opkg/apk")
  ((${#missing[@]} == 0)) ||
    die "required command(s) not found: ${missing[*]}"
}

ensure_packages() {
  local pm
  pm="$(detect_pkg_manager)" ||
    die "no supported package manager (opkg/apk) found"
  local -a pkgs=(wireguard-tools kmod-wireguard luci-proto-wireguard)
  [[ -n "$PPPOE_USERNAME" ]] && pkgs+=(ppp ppp-mod-pppoe)
  case "$pm" in
    opkg)
      opkg update || die "opkg update failed"
      opkg install "${pkgs[@]}" || die "opkg install failed"
      ;;
    apk)
      apk update || die "apk update failed"
      apk add "${pkgs[@]}" || die "apk add failed"
      ;;
  esac
}

# ==================== Service reload ====================

reload_services() {
  service network reload || die "failed to reload network"
  service firewall reload || die "failed to reload firewall"
  service dnsmasq reload || die "failed to reload dnsmasq"
}

# ==================== Transaction and rollback ====================

_snapshot_key() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'
}

snapshot_target() {
  local path="$1" slug
  slug="$(_snapshot_key "$path")"
  SNAPSHOT_TARGETS+=("$path")
  if [[ -e "$path" ]]; then
    SNAPSHOT_EXISTED["$path"]=1
    SNAPSHOT_MODE["$path"]="$(stat -c '%a' "$path")"
    if [[ -d "$path" ]]; then
      SNAPSHOT_ISDIR["$path"]=1
    else
      SNAPSHOT_ISDIR["$path"]=0
    fi
    cp -a -- "$path" "${TXN_DIR}/backup/${slug}"
  else
    SNAPSHOT_EXISTED["$path"]=0
    SNAPSHOT_ISDIR["$path"]=0
  fi
}

begin_transaction() {
  install -d -m 0700 "$TRANSACTION_DIR_ROOT"
  TXN_DIR="$(mktemp -d "${TRANSACTION_DIR_ROOT}/txn.XXXXXX")"
  install -d -m 0700 "${TXN_DIR}/backup" "${TXN_DIR}/stage"
  STAGED_BATCH="${TXN_DIR}/stage/batch.uci"
  STAGED_STATE="${TXN_DIR}/stage/wg-state.env"
  STAGED_CLIENTS="${TXN_DIR}/stage/clients"
  SNAPSHOT_TARGETS=()
  SNAPSHOT_EXISTED=()
  SNAPSHOT_MODE=()
  SNAPSHOT_ISDIR=()
  ROLLBACK_RUNNING=0
  TRANSACTION_ACTIVE=1
  trap 'rollback_transaction $?' ERR
  trap 'rollback_transaction 130' INT
  trap 'rollback_transaction 143' TERM
}

rollback_transaction() {
  local exit_code="${1:-1}"
  if ((ROLLBACK_RUNNING)); then
    return 0
  fi
  ROLLBACK_RUNNING=1
  trap - ERR INT TERM
  set +e
  if ((TRANSACTION_ACTIVE)); then
    log "rolling back transaction"
    # Drop any uncommitted UCI staging, then restore exact config files.
    uci -q -c "$UCI_CONFIG_DIR" revert network firewall dhcp >/dev/null 2>&1 || true
    local path slug
    for path in "${SNAPSHOT_TARGETS[@]}"; do
      slug="$(_snapshot_key "$path")"
      if [[ "${SNAPSHOT_EXISTED[$path]:-0}" == "1" ]]; then
        if [[ "${SNAPSHOT_ISDIR[$path]:-0}" == "1" ]]; then
          rm -rf -- "$path"
          cp -a -- "${TXN_DIR}/backup/${slug}" "$path"
        else
          install -D -m "${SNAPSHOT_MODE[$path]}" \
            "${TXN_DIR}/backup/${slug}" "$path"
        fi
      else
        rm -rf -- "$path"
      fi
    done
    # Best-effort return of live services to the restored configuration.
    service network reload >/dev/null 2>&1 || true
    service firewall reload >/dev/null 2>&1 || true
    service dnsmasq reload >/dev/null 2>&1 || true
    TRANSACTION_ACTIVE=0
  fi
  [[ -n "$TXN_DIR" ]] && rm -rf -- "$TXN_DIR"
  exit "$exit_code"
}

commit_transaction() {
  trap - ERR INT TERM
  TRANSACTION_ACTIVE=0
  [[ -n "$TXN_DIR" ]] && rm -rf -- "$TXN_DIR"
}

# ==================== Staging and install ====================

_atomic_install_file() {
  local mode="$1" src="$2" dest="$3" dir tmp
  dir="$(dirname "$dest")"
  [[ -d "$dir" ]] || install -d -m 0755 "$dir"
  tmp="$(mktemp "${dir}/.immortalwrt-deploy.XXXXXX")"
  if ! install -m "$mode" "$src" "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    die "failed to atomically install $dest"
  fi
}

stage_managed_files() {
  render_uci_batch "$STAGED_BATCH"
  render_wg_state_file "$STAGED_STATE"
  render_all_peer_templates "$STAGED_CLIENTS"
}

validate_staged_files() {
  validate_uci_batch "$STAGED_BATCH" ||
    die "staged UCI batch failed validation"
  validate_peer_templates "$STAGED_CLIENTS" ||
    die "staged WireGuard client template failed validation"
}

install_staged_files() {
  apply_uci_batch "$STAGED_BATCH"
  install -d -m 0700 "$(dirname "$WG_STATE_FILE")"
  _atomic_install_file 0600 "$STAGED_STATE" "$WG_STATE_FILE"
  install -d -m 0700 "$CLIENT_TEMPLATE_DIR"
  local f
  if compgen -G "$STAGED_CLIENTS/*.conf" >/dev/null; then
    for f in "$STAGED_CLIENTS"/*.conf; do
      _atomic_install_file 0600 "$f" "${CLIENT_TEMPLATE_DIR}/$(basename "$f")"
    done
  fi
}

print_install_summary() {
  printf 'ImmortalWrt base network + WireGuard installed.\n'
  printf 'WAN device: %s   LAN device: %s\n' "$WAN_DEVICE" "$LAN_DEVICE"
  printf 'LAN address: %s\n' "$LAN_ADDRESS"
  if [[ -n "$PPPOE_USERNAME" ]]; then
    printf 'WAN: PPPoE (metric %s, preferred) + DHCP fallback (metric %s)\n' \
      "$PPPOE_METRIC" "$DHCP_METRIC"
  else
    printf 'WAN: DHCP only (metric %s)\n' "$DHCP_METRIC"
  fi
  printf 'WireGuard %s: %s UDP %s pubkey %s\n' "$WG_GLOBAL_IFACE" \
    "$WG_GLOBAL_ADDRESS" "$WG_GLOBAL_PORT" "$WG_GLOBAL_PUBLIC_KEY"
  printf 'WireGuard %s: %s UDP %s pubkey %s\n' "$WG_LOCAL_IFACE" \
    "$WG_LOCAL_ADDRESS" "$WG_LOCAL_PORT" "$WG_LOCAL_PUBLIC_KEY"
  printf 'WireGuard ingress is IPv6-only; requires a public IPv6 on WAN6.\n'
  printf 'Client templates: %s\n' "$CLIENT_TEMPLATE_DIR"
  printf 'LAN moved to %s; reconnect the admin host to %s.\n' \
    "$LAN_ADDRESS" "${LAN_ADDRESS%/*}"
}

install_client() {
  begin_transaction
  snapshot_target "$NETWORK_CONFIG"
  snapshot_target "$FIREWALL_CONFIG"
  snapshot_target "$DHCP_CONFIG"
  snapshot_target "$WG_STATE_FILE"
  snapshot_target "$CLIENT_TEMPLATE_DIR"
  stage_managed_files
  validate_staged_files
  install_staged_files
  reload_services
  commit_transaction
  print_install_summary
}

# ==================== Commands ====================

cmd_install() {
  require_root
  mkdir -p -- "$(dirname "$INSTALL_LOCK")"
  exec 9>"$INSTALL_LOCK"
  flock -n 9 || die "another installation is running"
  load_config
  validate_config
  ensure_dependencies
  ensure_packages
  prompt_device_selection
  resolve_wireguard_material
  install_client
}

# Renders and validates every artifact in a throwaway directory without
# touching any live UCI config, service, or the host firewall.
cmd_check() {
  load_config
  validate_config
  ensure_dependencies
  prompt_device_selection
  resolve_wireguard_material
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp'" RETURN
  render_uci_batch "$tmp/batch.uci"
  render_wg_state_file "$tmp/wg-state.env"
  render_all_peer_templates "$tmp/clients"
  validate_uci_batch "$tmp/batch.uci" || die "UCI batch failed validation"
  validate_peer_templates "$tmp/clients" ||
    die "WireGuard client template failed validation"
  log "check: configuration and rendered artifacts validated (no changes made)"
}

cmd_show_wireguard() {
  load_config
  validate_config
  [[ -f "$WG_STATE_FILE" ]] ||
    die "WireGuard state not found; run install first: $WG_STATE_FILE"
  # shellcheck source=/dev/null
  source "$WG_STATE_FILE"
  printf 'WireGuard server public keys:\n'
  printf '  %s (%s, UDP %s): %s\n' "$WG_GLOBAL_IFACE" "$WG_GLOBAL_ADDRESS" \
    "$WG_GLOBAL_PORT" "$WG_GLOBAL_PUBLIC_KEY"
  printf '  %s (%s, UDP %s): %s\n' "$WG_LOCAL_IFACE" "$WG_LOCAL_ADDRESS" \
    "$WG_LOCAL_PORT" "$WG_LOCAL_PUBLIC_KEY"
  if compgen -G "$CLIENT_TEMPLATE_DIR/*.conf" >/dev/null; then
    printf '\nClient templates (%s):\n' "$CLIENT_TEMPLATE_DIR"
    local f
    for f in "$CLIENT_TEMPLATE_DIR"/*.conf; do
      printf '\n===== %s =====\n' "$f"
      cat "$f"
    done
  else
    printf '\nNo client templates present (no peers configured).\n'
  fi
}

usage() {
  printf '%s\n' \
    "Usage: immortalwrt-deploy.sh install         Configure base network and WireGuard" \
    "       immortalwrt-deploy.sh check           Validate config and rendered artifacts (no changes)" \
    "       immortalwrt-deploy.sh show-wireguard  Print WireGuard server keys and client templates" \
    "       immortalwrt-deploy.sh help"
}

main() {
  case "${1:-help}" in
    help | -h | --help) usage ;;
    install) cmd_install ;;
    check) cmd_check ;;
    show-wireguard) cmd_show_wireguard ;;
    *)
      usage >&2
      die "unknown command: ${1:-}"
      ;;
  esac
}

if [[ "${IMMORTALWRT_DEPLOY_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
