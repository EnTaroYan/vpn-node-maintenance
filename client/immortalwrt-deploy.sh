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
readonly HOMEPROXY_CONFIG="${UCI_CONFIG_DIR}/homeproxy"
readonly UHTTPD_CONFIG="${UCI_CONFIG_DIR}/uhttpd"
readonly ACME_CONFIG="${UCI_CONFIG_DIR}/acme"
readonly VPN_NODE_DIR="${ROOT_PREFIX}/etc/vpn-node"
readonly WG_STATE_FILE="${VPN_NODE_DIR}/immortalwrt-wg-state.env"
readonly CLIENT_TEMPLATE_DIR="${VPN_NODE_DIR}/wg-clients"
readonly INSTALL_LOCK="${ROOT_PREFIX}/run/lock/immortalwrt-deploy.lock"
readonly TRANSACTION_DIR_ROOT="${ROOT_PREFIX}/run/immortalwrt-deploy"

# HomeProxy self-signed trust anchor for the Hysteria2 node (PEM). Lives under
# /etc/homeproxy/certs so it is inside the ujail mount sing-box runs under.
readonly HOMEPROXY_CERT_DIR="${ROOT_PREFIX}/etc/homeproxy/certs"
readonly HY2_CA_FILE="${HOMEPROXY_CERT_DIR}/hy2-server.pem"

# Public LuCI (separate uhttpd instance) self-signed certificate material.
readonly LUCI_PUBLIC_CRT="${VPN_NODE_DIR}/luci-public.crt"
readonly LUCI_PUBLIC_KEY_FILE="${VPN_NODE_DIR}/luci-public.key"

# Optional Cloudflare AAAA DDNS updater, iface hotplug hook, and root crontab.
readonly DDNS_UPDATER="${VPN_NODE_DIR}/cloudflare-aaaa.sh"
readonly DDNS_HOTPLUG="${ROOT_PREFIX}/etc/hotplug.d/iface/99-vpn-node-ddns"
readonly CRONTAB_ROOT="${ROOT_PREFIX}/etc/crontabs/root"
readonly DDNS_CRON_TAG="#vpn-node-ddns"

# Logical interface / section names (never the physical device names).
readonly WAN_IFACE="wan"
readonly WAN6_IFACE="wan6"
readonly PPPOE_IFACE="wanpppoe"
readonly PPPOE6_IFACE="wanpppoe6"
readonly WG_GLOBAL_IFACE="wg_global"
readonly WG_LOCAL_IFACE="wg_local"

# HomeProxy node / uhttpd / acme section names.
readonly HP_HY2_NODE="hp_hy2"
readonly HP_REALITY_NODE="hp_reality"
readonly LUCI_UHTTPD_INSTANCE="vpnpublic"
readonly LUCI_ACME_CERT="luci_public"

# Interactive device selection results.
WAN_DEVICE=""
LAN_DEVICE=""

# Transaction state.
TXN_DIR=""
STAGED_BATCH=""
STAGED_STATE=""
STAGED_CLIENTS=""
STAGED_HY2_CA=""
STAGED_LUCI_CRT=""
STAGED_LUCI_KEY=""
STAGED_DDNS_SCRIPT=""
STAGED_DDNS_HOTPLUG=""
STAGED_DDNS_CRON=""
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

  # ---- sing-box proxy nodes (copied from the server client-params file) ----
  VPS_IPV4="${VPS_IPV4:-}"
  HY2_PORT="${HY2_PORT:-443}"
  HY2_PORTS="${HY2_PORTS:-}"
  HY2_PASSWORD="${HY2_PASSWORD:-}"
  HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD:-}"
  HY2_SNI="${HY2_SNI:-}"
  HY2_CERT_MODE="${HY2_CERT_MODE:-selfsigned}"
  # Server self-signed certificate as base64-encoded PEM (from the server's
  # client env). HY2_CERT_PIN is the retired name kept only to fail loudly.
  HY2_CERT_PEM_B64="${HY2_CERT_PEM_B64:-}"
  HY2_CERT_PIN="${HY2_CERT_PIN:-}"
  REALITY_PORT="${REALITY_PORT:-443}"
  REALITY_UUID="${REALITY_UUID:-}"
  REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-}"
  REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"
  REALITY_TARGET_NAME="${REALITY_TARGET_NAME:-}"
  REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-chrome}"

  # ---- Optional home IPv6 Cloudflare DDNS ----
  HOME_DOMAIN="${HOME_DOMAIN:-}"
  CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
  CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"

  # ---- Public LuCI (separate IPv6-only HTTPS instance) ----
  LUCI_PUBLIC_PORT="${LUCI_PUBLIC_PORT:-10443}"
  LUCI_CERT_MODE="${LUCI_CERT_MODE:-selfsigned}"
}

# Proxy (HomeProxy node) configuration is emitted only when a server has been
# provisioned and its IPv4 literal copied in.
proxy_enabled() { [[ -n "$VPS_IPV4" ]]; }

# The optional Cloudflare AAAA DDNS is active only with a domain and full
# Cloudflare credentials; an absent domain or token means no DDNS.
ddns_enabled() {
  [[ -n "$HOME_DOMAIN" && -n "$CLOUDFLARE_API_TOKEN" && -n "$CLOUDFLARE_ZONE_ID" ]]
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

valid_hostname() {
  local h="$1"
  ((${#h} <= 253)) || return 1
  [[ "$h" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

# "START:END" UDP port-hopping range with START <= END.
valid_port_range() {
  local v="$1" a b
  [[ "$v" == *:* ]] || return 1
  a="${v%%:*}"
  b="${v##*:}"
  valid_port "$a" && valid_port "$b" && ((10#$a <= 10#$b))
}

# Network address (host bits cleared) for an IPv4 CIDR, e.g.
# 10.192.100.1/24 -> 10.192.100.0/24.
ipv4_network_cidr() {
  local cidr="$1" ip prefix mask
  local -a ipo masko
  ip="${cidr%/*}"
  prefix="${cidr#*/}"
  mask="$(prefix_to_netmask "$prefix")"
  IFS='.' read -r -a ipo <<<"$ip"
  IFS='.' read -r -a masko <<<"$mask"
  printf '%d.%d.%d.%d/%s' \
    "$((10#${ipo[0]} & 10#${masko[0]}))" "$((10#${ipo[1]} & 10#${masko[1]}))" \
    "$((10#${ipo[2]} & 10#${masko[2]}))" "$((10#${ipo[3]} & 10#${masko[3]}))" \
    "$prefix"
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

  validate_proxy_config
  validate_ddns_config
  validate_luci_config
}

# HomeProxy node parameters. The proxy is configured only when VPS_IPV4 is set
# (copied from the server client-params file); the remaining node fields are
# then required so the HY2 and REALITY nodes are complete.
validate_proxy_config() {
  case "$HY2_CERT_MODE" in
    selfsigned | letsencrypt) ;;
    *) die "HY2_CERT_MODE must be selfsigned or letsencrypt" ;;
  esac
  proxy_enabled || return 0

  valid_ipv4 "$VPS_IPV4" || die "VPS_IPV4 must be a valid IPv4 literal"
  valid_port "$HY2_PORT" || die "HY2_PORT must be between 1 and 65535"
  valid_port "$REALITY_PORT" || die "REALITY_PORT must be between 1 and 65535"
  [[ -z "$HY2_PORTS" ]] || valid_port_range "$HY2_PORTS" ||
    die "HY2_PORTS must be a START:END UDP range"
  [[ -n "$HY2_PASSWORD" ]] || die "HY2_PASSWORD is required when VPS_IPV4 is set"
  [[ -n "$HY2_OBFS_PASSWORD" ]] ||
    die "HY2_OBFS_PASSWORD is required when VPS_IPV4 is set"
  [[ -n "$REALITY_UUID" ]] || die "REALITY_UUID is required when VPS_IPV4 is set"
  [[ -n "$REALITY_PUBLIC_KEY" ]] ||
    die "REALITY_PUBLIC_KEY is required when VPS_IPV4 is set"
  [[ -n "$REALITY_SHORT_ID" ]] ||
    die "REALITY_SHORT_ID is required when VPS_IPV4 is set"
  [[ -n "$REALITY_TARGET_NAME" ]] ||
    die "REALITY_TARGET_NAME is required when VPS_IPV4 is set"
  valid_hostname "$REALITY_TARGET_NAME" ||
    die "REALITY_TARGET_NAME must be a valid domain name"
  if [[ "$HY2_CERT_MODE" == "selfsigned" ]]; then
    [[ -z "$HY2_CERT_PIN" ]] ||
      die "HY2_CERT_PIN has been renamed to HY2_CERT_PEM_B64; set the base64-encoded server certificate PEM there instead"
    [[ -n "$HY2_CERT_PEM_B64" ]] ||
      die "HY2_CERT_PEM_B64 (base64-encoded server self-signed certificate PEM) is required for selfsigned HY2_CERT_MODE"
    decode_hy2_cert_pem >/dev/null ||
      die "HY2_CERT_PEM_B64 must be base64-encoded PEM of the server certificate"
  fi
}

# Cloudflare DDNS is optional. If a home domain is set, the Cloudflare
# credentials become mandatory; otherwise DDNS is simply skipped.
validate_ddns_config() {
  [[ -n "$HOME_DOMAIN" ]] || return 0
  valid_hostname "$HOME_DOMAIN" || die "HOME_DOMAIN must be a valid domain name"
  [[ -n "$CLOUDFLARE_API_TOKEN" ]] ||
    die "CLOUDFLARE_API_TOKEN is required when HOME_DOMAIN is set"
  [[ -n "$CLOUDFLARE_ZONE_ID" ]] ||
    die "CLOUDFLARE_ZONE_ID is required when HOME_DOMAIN is set"
}

# Public LuCI cert mode / port. Let's Encrypt uses DNS-01 via Cloudflare, so it
# needs the same domain and credentials as the DDNS.
validate_luci_config() {
  valid_port "$LUCI_PUBLIC_PORT" ||
    die "LUCI_PUBLIC_PORT must be between 1 and 65535"
  case "$LUCI_CERT_MODE" in
    selfsigned) ;;
    letsencrypt)
      [[ -n "$HOME_DOMAIN" ]] ||
        die "LUCI_CERT_MODE=letsencrypt requires HOME_DOMAIN"
      [[ -n "$CLOUDFLARE_API_TOKEN" && -n "$CLOUDFLARE_ZONE_ID" ]] ||
        die "LUCI_CERT_MODE=letsencrypt requires Cloudflare credentials for DNS-01"
      ;;
    *) die "LUCI_CERT_MODE must be selfsigned or letsencrypt" ;;
  esac
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

    # Public LuCI ingress: IPv6-only TCP on WAN for the separate uhttpd instance.
    _set "firewall.luci_public_in" "rule"
    _setq "firewall.luci_public_in.name" "Allow-LuCI-Public-IPv6"
    _setq "firewall.luci_public_in.src" "wan"
    _setq "firewall.luci_public_in.proto" "tcp"
    _setq "firewall.luci_public_in.dest_port" "$LUCI_PUBLIC_PORT"
    _setq "firewall.luci_public_in.family" "ipv6"
    _setq "firewall.luci_public_in.target" "ACCEPT"
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
  render_homeproxy_batch "$out"
  render_uhttpd_batch "$out"
  render_acme_batch "$out"
}

# ==================== HomeProxy UCI rendering ====================

# Emits the HomeProxy client configuration: GFWList redirect_tproxy mode,
# IPv4-only, the wg-global source global-proxy policy, the resource auto-update
# cron, and the exact HY2 (default) and VLESS+REALITY+Vision (manual) nodes.
# The package ships a default /etc/config/homeproxy with the 'config', 'dns',
# 'subscription', and 'control' sections seeded; we redeclare each section (a
# no-op when it already exists) and set only the options we manage, so manually
# maintained proxy/direct lists (wan_proxy_*, lan_direct_*, resource list files)
# are preserved. Only our own lan_global_proxy list is cleared before re-adding.
render_homeproxy_batch() {
  local out="$1" wg_global_net
  proxy_enabled || return 0
  wg_global_net="$(ipv4_network_cidr "$WG_GLOBAL_ADDRESS")"
  {
    # General: GFWList split, redirect_tproxy, IPv4-only, HY2 as default node.
    _set "homeproxy.config" "homeproxy"
    _setq "homeproxy.config.proxy_mode" "redirect_tproxy"
    _setq "homeproxy.config.routing_mode" "gfwlist"
    _setq "homeproxy.config.ipv6_support" "0"
    _setq "homeproxy.config.main_node" "$HP_HY2_NODE"
    _setq "homeproxy.config.main_udp_node" "same"

    # IPv4-only DNS resolution for proxied lookups.
    _set "homeproxy.dns" "homeproxy"
    _setq "homeproxy.dns.dns_strategy" "ipv4_only"

    # Resource/geodata auto-update via HomeProxy's cron.
    _set "homeproxy.subscription" "homeproxy"
    _setq "homeproxy.subscription.auto_update" "1"
    _setq "homeproxy.subscription.auto_update_time" "4"

    # Access control: the wg-global subnet is globally proxied; LAN and wg-local
    # keep the default GFWList behaviour (lan_proxy_mode disabled). Clear only
    # our own global-proxy list before re-adding it; leave manual lists intact.
    _set "homeproxy.control" "homeproxy"
    _setq "homeproxy.control.lan_proxy_mode" "disabled"
    _del "homeproxy.control.lan_global_proxy_ipv4_ips"
    _addlist "homeproxy.control.lan_global_proxy_ipv4_ips" "$wg_global_net"

    # HY2 (Hysteria2 + Salamander) node - the default main node. IPv4 literal
    # address keeps the dial IPv4-only.
    _set "homeproxy.${HP_HY2_NODE}" "node"
    _setq "homeproxy.${HP_HY2_NODE}.label" "HY2 Hysteria2 (default)"
    _setq "homeproxy.${HP_HY2_NODE}.type" "hysteria2"
    _setq "homeproxy.${HP_HY2_NODE}.address" "$VPS_IPV4"
    _setq "homeproxy.${HP_HY2_NODE}.port" "$HY2_PORT"
    _setq "homeproxy.${HP_HY2_NODE}.password" "$HY2_PASSWORD"
    _setq "homeproxy.${HP_HY2_NODE}.hysteria_obfs_type" "salamander"
    _setq "homeproxy.${HP_HY2_NODE}.hysteria_obfs_password" "$HY2_OBFS_PASSWORD"
    _setq "homeproxy.${HP_HY2_NODE}.tls" "1"
    _setq "homeproxy.${HP_HY2_NODE}.tls_sni" "${HY2_SNI:-$VPS_IPV4}"
    _setq "homeproxy.${HP_HY2_NODE}.tls_insecure" "0"
    if [[ -n "$HY2_PORTS" ]]; then
      _addlist "homeproxy.${HP_HY2_NODE}.hysteria_hopping_port" "$HY2_PORTS"
    fi
    if [[ "$HY2_CERT_MODE" == "selfsigned" ]]; then
      # Pin the server self-signed certificate instead of allowing insecure TLS.
      _setq "homeproxy.${HP_HY2_NODE}.tls_self_sign" "1"
      _setq "homeproxy.${HP_HY2_NODE}.tls_cert_path" "$HY2_CA_FILE"
    fi

    # VLESS + REALITY + Vision node - selectable manually in LuCI as main_node.
    _set "homeproxy.${HP_REALITY_NODE}" "node"
    _setq "homeproxy.${HP_REALITY_NODE}.label" "REALITY VLESS Vision (manual)"
    _setq "homeproxy.${HP_REALITY_NODE}.type" "vless"
    _setq "homeproxy.${HP_REALITY_NODE}.address" "$VPS_IPV4"
    _setq "homeproxy.${HP_REALITY_NODE}.port" "$REALITY_PORT"
    _setq "homeproxy.${HP_REALITY_NODE}.uuid" "$REALITY_UUID"
    _setq "homeproxy.${HP_REALITY_NODE}.vless_flow" "xtls-rprx-vision"
    _setq "homeproxy.${HP_REALITY_NODE}.packet_encoding" "xudp"
    _setq "homeproxy.${HP_REALITY_NODE}.tls" "1"
    _setq "homeproxy.${HP_REALITY_NODE}.tls_sni" "$REALITY_TARGET_NAME"
    _setq "homeproxy.${HP_REALITY_NODE}.tls_insecure" "0"
    _setq "homeproxy.${HP_REALITY_NODE}.tls_utls" "$REALITY_FINGERPRINT"
    _setq "homeproxy.${HP_REALITY_NODE}.tls_reality" "1"
    _setq "homeproxy.${HP_REALITY_NODE}.tls_reality_public_key" "$REALITY_PUBLIC_KEY"
    _setq "homeproxy.${HP_REALITY_NODE}.tls_reality_short_id" "$REALITY_SHORT_ID"
  } >>"$out"
}

# ==================== Public LuCI (uhttpd) UCI rendering ====================

# A separate uhttpd instance bound to [::]:PORT only (IPv6-only HTTPS), distinct
# from the factory LAN 'main' instance. No plain-HTTP listener is created.
render_uhttpd_batch() {
  local out="$1" crt key
  if [[ "$LUCI_CERT_MODE" == "letsencrypt" ]]; then
    crt="${ROOT_PREFIX}/etc/acme/${HOME_DOMAIN}/fullchain.cer"
    key="${ROOT_PREFIX}/etc/acme/${HOME_DOMAIN}/${HOME_DOMAIN}.key"
  else
    crt="$LUCI_PUBLIC_CRT"
    key="$LUCI_PUBLIC_KEY_FILE"
  fi
  {
    _set "uhttpd.${LUCI_UHTTPD_INSTANCE}" "uhttpd"
    _del "uhttpd.${LUCI_UHTTPD_INSTANCE}.listen_http"
    _del "uhttpd.${LUCI_UHTTPD_INSTANCE}.listen_https"
    _addlist "uhttpd.${LUCI_UHTTPD_INSTANCE}.listen_https" "[::]:${LUCI_PUBLIC_PORT}"
    _setq "uhttpd.${LUCI_UHTTPD_INSTANCE}.redirect_https" "0"
    _setq "uhttpd.${LUCI_UHTTPD_INSTANCE}.home" "/www"
    _setq "uhttpd.${LUCI_UHTTPD_INSTANCE}.rfc1918_filter" "0"
    _setq "uhttpd.${LUCI_UHTTPD_INSTANCE}.cert" "$crt"
    _setq "uhttpd.${LUCI_UHTTPD_INSTANCE}.key" "$key"
    _setq "uhttpd.${LUCI_UHTTPD_INSTANCE}.cgi_prefix" "/cgi-bin"
    _addlist "uhttpd.${LUCI_UHTTPD_INSTANCE}.index_page" "index.html"
    _setq "uhttpd.${LUCI_UHTTPD_INSTANCE}.script_timeout" "60"
    _setq "uhttpd.${LUCI_UHTTPD_INSTANCE}.network_timeout" "30"
    _setq "uhttpd.${LUCI_UHTTPD_INSTANCE}.http_keepalive" "20"
    _setq "uhttpd.${LUCI_UHTTPD_INSTANCE}.tcp_keepalive" "1"
  } >>"$out"
}

# ACME (acme.sh via luci-app-acme) cert for the public LuCI domain, issued with
# the Cloudflare DNS-01 challenge only. Emitted only in letsencrypt mode.
render_acme_batch() {
  local out="$1"
  [[ "$LUCI_CERT_MODE" == "letsencrypt" ]] || return 0
  {
    _set "acme.${LUCI_ACME_CERT}" "cert"
    _setq "acme.${LUCI_ACME_CERT}.enabled" "1"
    _del "acme.${LUCI_ACME_CERT}.domains"
    _addlist "acme.${LUCI_ACME_CERT}.domains" "$HOME_DOMAIN"
    _setq "acme.${LUCI_ACME_CERT}.validation_method" "dns"
    _setq "acme.${LUCI_ACME_CERT}.dns" "dns_cf"
    _del "acme.${LUCI_ACME_CERT}.credentials"
    _addlist "acme.${LUCI_ACME_CERT}.credentials" "CF_Token=${CLOUDFLARE_API_TOKEN}"
    _addlist "acme.${LUCI_ACME_CERT}.credentials" "CF_Zone_ID=${CLOUDFLARE_ZONE_ID}"
    _setq "acme.${LUCI_ACME_CERT}.key_type" "rsa2048"
  } >>"$out"
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

# ==================== Certificate and DDNS artifacts ====================

# HY2 self-signed trust anchor: HY2_CERT_PEM_B64 carries the server's self-signed
# certificate as base64-encoded PEM (produced by the server deployer). Decode it
# and confirm it is a real certificate; callers write it to tls_cert_path so
# HomeProxy trusts it via tls_self_sign and never resorts to insecure TLS.
decode_hy2_cert_pem() {
  local pem
  pem="$(printf '%s' "$HY2_CERT_PEM_B64" | base64 -d 2>/dev/null)" || return 1
  [[ "$pem" == *"-----BEGIN CERTIFICATE-----"* ]] || return 1
  printf '%s' "$pem" | openssl x509 -noout >/dev/null 2>&1 || return 1
  printf '%s\n' "$pem"
}

write_hy2_ca_file() {
  local dest="$1" pem
  pem="$(decode_hy2_cert_pem)" ||
    die "failed to decode HY2_CERT_PEM_B64 into a server certificate"
  install -d -m 0755 "$(dirname "$dest")"
  printf '%s\n' "$pem" >"$dest"
  chmod 0644 "$dest"
}

# Self-signed certificate for the public LuCI uhttpd instance (selfsigned mode).
generate_luci_selfsigned() {
  local crt="$1" key="$2" cn
  cn="${HOME_DOMAIN:-immortalwrt-luci}"
  install -d -m 0700 "$(dirname "$key")"
  install -d -m 0755 "$(dirname "$crt")"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$key" -out "$crt" -days 3650 -sha256 \
    -subj "/CN=${cn}" >/dev/null 2>&1 ||
    die "failed to generate the self-signed LuCI certificate"
  chmod 0600 "$key"
  chmod 0644 "$crt"
}

# Cloudflare AAAA updater. Selects a stable global IPv6 (skipping temporary /
# privacy / deprecated addresses) and publishes it as a DNS-only (proxied=false)
# record. Credentials are baked into this root-only 0700 script.
render_ddns_updater() {
  local dest="$1"
  install -d -m 0700 "$(dirname "$dest")"
  {
    printf '#!/bin/sh\n'
    printf '%s\n' "$MANAGED_MARKER"
    printf "DOMAIN=%q\n" "$HOME_DOMAIN"
    printf "ZONE_ID=%q\n" "$CLOUDFLARE_ZONE_ID"
    printf "API_TOKEN=%q\n" "$CLOUDFLARE_API_TOKEN"
    cat <<'EOF'
API='https://api.cloudflare.com/client/v4'
set -eu

# Stable global-scope IPv6: skip temporary/privacy, deprecated and tentative
# addresses and ULA (fc00::/7). The LAN advertises no IPv6, so the surviving
# GUAs are the active WAN6 addresses; take the first stable one.
select_stable_gua() {
	ip -6 addr show scope global 2>/dev/null | awk '
		$1 == "inet6" {
			a = $2; sub(/\/.*/, "", a); bad = 0
			for (i = 3; i <= NF; i++)
				if ($i == "temporary" || $i == "deprecated" || $i == "tentative")
					bad = 1
			if (bad) next
			la = tolower(a)
			if (la ~ /^fe80:/) next
			if (la ~ /^f[cd]/) next
			print a
		}' | head -n1
}

gua="$(select_stable_gua)"
[ -n "$gua" ] || { logger -t vpn-node-ddns "no stable global IPv6 available"; exit 0; }

auth="Authorization: Bearer ${API_TOKEN}"
records="$(curl -fsS -H "$auth" -H 'Content-Type: application/json' \
	"${API}/zones/${ZONE_ID}/dns_records?type=AAAA&name=${DOMAIN}")" ||
	{ logger -t vpn-node-ddns "Cloudflare query failed"; exit 1; }

rec_id="$(printf '%s' "$records" | sed -n 's/.*"id":"\([0-9a-f]\{1,\}\)".*/\1/p' | head -n1)"
body='{"type":"AAAA","name":"'"$DOMAIN"'","content":"'"$gua"'","ttl":60,"proxied":false}'

if [ -n "$rec_id" ]; then
	curl -fsS -X PUT -H "$auth" -H 'Content-Type: application/json' \
		"${API}/zones/${ZONE_ID}/dns_records/${rec_id}" --data "$body" >/dev/null &&
		logger -t vpn-node-ddns "updated ${DOMAIN} AAAA -> ${gua}"
else
	curl -fsS -X POST -H "$auth" -H 'Content-Type: application/json' \
		"${API}/zones/${ZONE_ID}/dns_records" --data "$body" >/dev/null &&
		logger -t vpn-node-ddns "created ${DOMAIN} AAAA -> ${gua}"
fi
EOF
  } >"$dest"
  chmod 0700 "$dest"
}

# Hotplug hook: run the updater when a WAN IPv6 logical interface comes up.
render_ddns_hotplug() {
  local dest="$1"
  install -d -m 0755 "$(dirname "$dest")"
  {
    printf '#!/bin/sh\n'
    printf '%s\n' "$MANAGED_MARKER"
    printf '[ "$ACTION" = "ifup" ] || exit 0\n'
    printf 'case "$INTERFACE" in\n'
    printf '  %s|%s) %s >/dev/null 2>&1 & ;;\n' \
      "$WAN6_IFACE" "$PPPOE6_IFACE" "$DDNS_UPDATER"
    printf 'esac\n'
    printf 'exit 0\n'
  } >"$dest"
  chmod 0755 "$dest"
}

# Root crontab with our marked DDNS line, preserving all other entries.
render_ddns_crontab() {
  local dest="$1"
  install -d -m 0755 "$(dirname "$dest")"
  : >"$dest"
  if [[ -f "$CRONTAB_ROOT" ]]; then
    grep -vF "$DDNS_CRON_TAG" "$CRONTAB_ROOT" >"$dest" || true
  fi
  printf '*/15 * * * * %s %s\n' "$DDNS_UPDATER" "$DDNS_CRON_TAG" >>"$dest"
  chmod 0600 "$dest"
}

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
  # HomeProxy client + sing-box engine, and the DDNS framework.
  pkgs+=(homeproxy sing-box ddns-scripts)
  # TLS / certificate tooling depends on the public-LuCI cert mode.
  if [[ "$LUCI_CERT_MODE" == "letsencrypt" ]]; then
    pkgs+=(acme acme-dnsapi luci-app-acme)
  else
    pkgs+=(openssl-util)
  fi
  # The Cloudflare AAAA updater needs an HTTPS-capable curl.
  if ddns_enabled; then
    pkgs+=(curl ca-bundle)
  fi
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
  service uhttpd reload || die "failed to reload uhttpd"
  if proxy_enabled; then
    service homeproxy enable >/dev/null 2>&1 || true
    service homeproxy restart || die "failed to restart homeproxy"
  fi
  if ddns_enabled; then
    service cron enable >/dev/null 2>&1 || true
    service cron restart >/dev/null 2>&1 || true
  fi
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
  STAGED_HY2_CA="${TXN_DIR}/stage/hy2_server_ca.pem"
  STAGED_LUCI_CRT="${TXN_DIR}/stage/luci-public.crt"
  STAGED_LUCI_KEY="${TXN_DIR}/stage/luci-public.key"
  STAGED_DDNS_SCRIPT="${TXN_DIR}/stage/cloudflare-aaaa.sh"
  STAGED_DDNS_HOTPLUG="${TXN_DIR}/stage/99-vpn-node-ddns"
  STAGED_DDNS_CRON="${TXN_DIR}/stage/crontab-root"
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
    uci -q -c "$UCI_CONFIG_DIR" revert network firewall dhcp homeproxy uhttpd acme >/dev/null 2>&1 || true
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
  if proxy_enabled && [[ "$HY2_CERT_MODE" == "selfsigned" ]]; then
    write_hy2_ca_file "$STAGED_HY2_CA"
  fi
  if [[ "$LUCI_CERT_MODE" == "selfsigned" ]]; then
    generate_luci_selfsigned "$STAGED_LUCI_CRT" "$STAGED_LUCI_KEY"
  fi
  if ddns_enabled; then
    render_ddns_updater "$STAGED_DDNS_SCRIPT"
    render_ddns_hotplug "$STAGED_DDNS_HOTPLUG"
    render_ddns_crontab "$STAGED_DDNS_CRON"
  fi
}

validate_staged_files() {
  validate_uci_batch "$STAGED_BATCH" ||
    die "staged UCI batch failed validation"
  validate_peer_templates "$STAGED_CLIENTS" ||
    die "staged WireGuard client template failed validation"
  if [[ "$LUCI_CERT_MODE" == "selfsigned" ]]; then
    [[ -s "$STAGED_LUCI_CRT" && -s "$STAGED_LUCI_KEY" ]] ||
      die "public LuCI self-signed certificate was not generated"
    openssl x509 -in "$STAGED_LUCI_CRT" -noout >/dev/null 2>&1 ||
      die "generated public LuCI certificate is invalid"
  fi
  if proxy_enabled && [[ "$HY2_CERT_MODE" == "selfsigned" ]]; then
    [[ -s "$STAGED_HY2_CA" ]] || die "HY2 self-signed trust anchor is empty"
  fi
  if ddns_enabled; then
    [[ -s "$STAGED_DDNS_SCRIPT" ]] || die "Cloudflare DDNS updater was not rendered"
  fi
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
  if proxy_enabled && [[ "$HY2_CERT_MODE" == "selfsigned" ]]; then
    install -d -m 0755 "$HOMEPROXY_CERT_DIR"
    _atomic_install_file 0644 "$STAGED_HY2_CA" "$HY2_CA_FILE"
  fi
  if [[ "$LUCI_CERT_MODE" == "selfsigned" ]]; then
    install -d -m 0700 "$VPN_NODE_DIR"
    _atomic_install_file 0644 "$STAGED_LUCI_CRT" "$LUCI_PUBLIC_CRT"
    _atomic_install_file 0600 "$STAGED_LUCI_KEY" "$LUCI_PUBLIC_KEY_FILE"
  fi
  if ddns_enabled; then
    install -d -m 0700 "$VPN_NODE_DIR"
    _atomic_install_file 0700 "$STAGED_DDNS_SCRIPT" "$DDNS_UPDATER"
    install -d -m 0755 "$(dirname "$DDNS_HOTPLUG")"
    _atomic_install_file 0755 "$STAGED_DDNS_HOTPLUG" "$DDNS_HOTPLUG"
    install -d -m 0755 "$(dirname "$CRONTAB_ROOT")"
    _atomic_install_file 0600 "$STAGED_DDNS_CRON" "$CRONTAB_ROOT"
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
  if proxy_enabled; then
    printf 'HomeProxy: GFWList redirect_tproxy, IPv4-only; default node HY2 (%s), manual node REALITY.\n' \
      "$HP_HY2_NODE"
    printf 'HY2 certificate mode: %s\n' "$HY2_CERT_MODE"
  fi
  if ddns_enabled; then
    printf 'Cloudflare AAAA DDNS enabled for %s (DNS-only, hotplug + cron).\n' \
      "$HOME_DOMAIN"
  else
    printf 'Cloudflare AAAA DDNS: disabled (no home domain/token).\n'
  fi
  printf 'Public LuCI: IPv6-only HTTPS on [::]:%s (%s certificate).\n' \
    "$LUCI_PUBLIC_PORT" "$LUCI_CERT_MODE"
  printf 'LAN moved to %s; reconnect the admin host to %s.\n' \
    "$LAN_ADDRESS" "${LAN_ADDRESS%/*}"
}

install_client() {
  begin_transaction
  snapshot_target "$NETWORK_CONFIG"
  snapshot_target "$FIREWALL_CONFIG"
  snapshot_target "$DHCP_CONFIG"
  snapshot_target "$HOMEPROXY_CONFIG"
  snapshot_target "$UHTTPD_CONFIG"
  snapshot_target "$ACME_CONFIG"
  snapshot_target "$WG_STATE_FILE"
  snapshot_target "$CLIENT_TEMPLATE_DIR"
  snapshot_target "$HY2_CA_FILE"
  snapshot_target "$LUCI_PUBLIC_CRT"
  snapshot_target "$LUCI_PUBLIC_KEY_FILE"
  snapshot_target "$DDNS_UPDATER"
  snapshot_target "$DDNS_HOTPLUG"
  snapshot_target "$CRONTAB_ROOT"
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
  if proxy_enabled && [[ "$HY2_CERT_MODE" == "selfsigned" ]]; then
    write_hy2_ca_file "$tmp/hy2_server_ca.pem"
  fi
  if [[ "$LUCI_CERT_MODE" == "selfsigned" ]]; then
    generate_luci_selfsigned "$tmp/luci-public.crt" "$tmp/luci-public.key"
  fi
  if ddns_enabled; then
    render_ddns_updater "$tmp/cloudflare-aaaa.sh"
    render_ddns_hotplug "$tmp/99-vpn-node-ddns"
  fi
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
