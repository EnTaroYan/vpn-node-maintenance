#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly MANAGED_MARKER="# Managed by vpn-node-maintenance: ocserv-deploy.sh"
readonly CONFIG_FILE="${VPN_MAINTENANCE_CONFIG:-/etc/vpn-maintenance.env}"
readonly ROOT_PREFIX="${OCSERV_DEPLOY_ROOT:-}"
readonly OCSERV_CONF="${ROOT_PREFIX}/etc/ocserv/ocserv.conf"
readonly OCSERV_PASSWD="${ROOT_PREFIX}/etc/ocserv/ocpasswd"
readonly SELF_SIGNED_CERT="${ROOT_PREFIX}/etc/ocserv/ssl/selfsigned-cert.pem"
readonly SELF_SIGNED_KEY="${ROOT_PREFIX}/etc/ocserv/ssl/selfsigned-key.pem"
readonly NETWORK_HELPER="${ROOT_PREFIX}/usr/local/libexec/vpn-node/ocserv-network"
readonly SYSTEMD_DROPIN="${ROOT_PREFIX}/etc/systemd/system/ocserv.service.d/10-network.conf"
readonly CERT_HOOK="${ROOT_PREFIX}/etc/letsencrypt/renewal-hooks/deploy/20-ocserv"
readonly INSTALL_LOCK="${ROOT_PREFIX}/run/lock/ocserv-deploy.lock"

declare -a NORMALIZED_DNS=()
OCSERV_NETWORK_ADDRESS=""
OCSERV_NETMASK=""
SERVER_CERT_FILE=""
SERVER_KEY_FILE=""
CERT_HOOK_DELETE=""


# Root-only transaction workspace under /run (prefixed for test isolation).
readonly TRANSACTION_DIR_ROOT="${ROOT_PREFIX}/run/ocserv-deploy"
TXN_DIR=""
STAGED_OCSERV_CONF=""
STAGED_OCSERV_PASSWD=""
STAGED_NETWORK_HELPER=""
STAGED_SYSTEMD_DROPIN=""
STAGED_CERT_HOOK=""
STAGED_SELF_SIGNED_CERT=""
STAGED_SELF_SIGNED_KEY=""

TRANSACTION_ACTIVE=0
ROLLBACK_RUNNING=0
SERVICE_WAS_ACTIVE=0
SERVICE_WAS_ENABLED=0
declare -ga SNAPSHOT_TARGETS=()
declare -gA SNAPSHOT_EXISTED=()
declare -gA SNAPSHOT_MODE=()

log() {
  printf '%s [ocserv-deploy] %s\n' "$(date --iso-8601=seconds)" "$*"
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

valid_hostname() {
  local hostname="${1%.}" label
  local -a labels
  [[ -n "$hostname" && ${#hostname} -le 253 && "$hostname" == *.* ]] ||
    return 1
  IFS='.' read -r -a labels <<<"$hostname"
  # The final label (TLD) must not be all-numeric; otherwise an IPv4-like
  # string with an out-of-range octet (e.g. 10.20.30.999) would masquerade
  # as a valid DNS name after failing the stricter IPv4 check.
  [[ "${labels[-1]}" =~ ^[0-9]+$ ]] && return 1
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
      return 1
  done
}

validate_endpoint() {
  valid_ipv4 "$1" || valid_hostname "$1"
}

parse_ipv4_24() {
  local cidr="$1" address prefix
  address="${cidr%/*}"
  prefix="${cidr#*/}"
  valid_ipv4 "$address" || die "invalid OCSERV_IPV4_NETWORK address"
  [[ "$prefix" == "24" ]] || die "OCSERV_IPV4_NETWORK must use /24"
  [[ "${address##*.}" == "0" ]] || die "OCSERV_IPV4_NETWORK must be a /24 network address"
  OCSERV_NETWORK_ADDRESS="$address"
  OCSERV_NETMASK="255.255.255.0"
}

validate_common_config() {
  : "${OCSERV_ENDPOINT:?missing OCSERV_ENDPOINT}"
  : "${OCSERV_PORT:?missing OCSERV_PORT}"
  : "${OCSERV_IPV4_NETWORK:?missing OCSERV_IPV4_NETWORK}"
  : "${OCSERV_CERT_MODE:?missing OCSERV_CERT_MODE}"
  validate_endpoint "$OCSERV_ENDPOINT" || die "invalid OCSERV_ENDPOINT"
  [[ "$OCSERV_PORT" =~ ^[0-9]+$ ]] &&
    ((OCSERV_PORT >= 1 && OCSERV_PORT <= 65535)) ||
    die "OCSERV_PORT must be between 1 and 65535"
  case "$OCSERV_CERT_MODE" in
    letsencrypt|selfsigned) ;;
    *) die "OCSERV_CERT_MODE must be letsencrypt or selfsigned" ;;
  esac
  parse_ipv4_24 "$OCSERV_IPV4_NETWORK"
  local _dns_decl
  _dns_decl="$(declare -p OCSERV_DNS 2>/dev/null)" ||
    die "OCSERV_DNS must be an indexed Bash array"
  [[ "$_dns_decl" =~ ^'declare -'[a-z]*'a'[a-z]*' ' ]] ||
    die "OCSERV_DNS must be an indexed Bash array (not scalar or associative)"
  NORMALIZED_DNS=("${OCSERV_DNS[@]}")
  ((${#NORMALIZED_DNS[@]} > 0)) || die "OCSERV_DNS cannot be empty"
  local dns
  for dns in "${NORMALIZED_DNS[@]}"; do
    valid_ipv4 "$dns" || die "invalid DNS address: $dns"
  done
}

validate_certificate_pair() {
  local cert="$1" key="$2" cert_digest key_digest
  [[ -f "$cert" && -f "$key" ]] || die "certificate or key is missing"
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null ||
    die "certificate is expired or invalid"
  cert_digest="$(
    openssl x509 -in "$cert" -pubkey -noout |
      openssl pkey -pubin -outform DER |
      sha256sum | awk '{print $1}'
  )"
  key_digest="$(
    openssl pkey -in "$key" -pubout -outform DER |
      sha256sum | awk '{print $1}'
  )"
  [[ "$cert_digest" == "$key_digest" ]] ||
    die "certificate and private key do not match"
}

certificate_matches_endpoint() {
  local cert="$1" endpoint="$2" result rc=0
  if valid_ipv4 "$endpoint"; then
    result="$(openssl x509 -in "$cert" -noout -checkip "$endpoint" 2>/dev/null)" || rc=$?
  else
    result="$(openssl x509 -in "$cert" -noout -checkhost "$endpoint" 2>/dev/null)" || rc=$?
  fi
  # OpenSSL 3.0: exits 0; "does [NOT] match" text distinguishes match/mismatch.
  # OpenSSL 3.2+: exits 0 on match, 1 on mismatch; same text output.
  # Unrelated errors produce no match text and a nonzero exit code -- propagate.
  if [[ "$result" == *"does NOT match"* ]]; then
    return 1
  elif [[ "$result" == *"does match"* ]]; then
    return 0
  elif ((rc != 0)); then
    return "$rc"
  else
    return 1
  fi
}

generate_self_signed_certificate() {
  install -d -m 0700 "$(dirname "$SELF_SIGNED_CERT")"
  # Run all temp-file work in a subshell so the EXIT trap cannot leak to callers.
  (
    # Disable the inherited ERR trap (set -E) so a generation failure inside
    # this subshell does not roll back here as well; the failure propagates to
    # the caller, which performs exactly one rollback. Temp cleanup below is
    # kept via a separate EXIT trap.
    trap - ERR
    temp_cert="$(mktemp "$(dirname "$SELF_SIGNED_CERT")/.cert.XXXXXX")"
    # Arm cleanup right after the first temp exists so a failing second mktemp
    # cannot leak the first; temp_key stays empty until the second call succeeds.
    temp_key=""
    trap 'rm -f -- "$temp_cert" ${temp_key:+"$temp_key"}' EXIT
    temp_key="$(mktemp "$(dirname "$SELF_SIGNED_KEY")/.key.XXXXXX")"
    san_type="DNS"
    valid_ipv4 "$OCSERV_ENDPOINT" && san_type="IP"
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
      -subj "/CN=${OCSERV_ENDPOINT}" \
      -addext "subjectAltName=${san_type}:${OCSERV_ENDPOINT}" \
      -keyout "$temp_key" -out "$temp_cert"
    chmod 0600 "$temp_key"
    chmod 0644 "$temp_cert"
    validate_certificate_pair "$temp_cert" "$temp_key"
    certificate_matches_endpoint "$temp_cert" "$OCSERV_ENDPOINT" ||
      die "generated certificate SAN does not match endpoint"
    install -m 0600 "$temp_key" "$SELF_SIGNED_KEY"
    install -m 0644 "$temp_cert" "$SELF_SIGNED_CERT"
  )
}

prepare_selfsigned_certificate() {
  if [[ -f "$SELF_SIGNED_CERT" && -f "$SELF_SIGNED_KEY" ]]; then
    validate_certificate_pair "$SELF_SIGNED_CERT" "$SELF_SIGNED_KEY"
    certificate_matches_endpoint "$SELF_SIGNED_CERT" "$OCSERV_ENDPOINT" ||
      die "existing certificate SAN does not match endpoint"
  elif [[ -f "$SELF_SIGNED_CERT" || -f "$SELF_SIGNED_KEY" ]]; then
    die "only one of self-signed cert/key exists; refusing to overwrite"
  else
    generate_self_signed_certificate
  fi
  SERVER_CERT_FILE="$SELF_SIGNED_CERT"
  SERVER_KEY_FILE="$SELF_SIGNED_KEY"
  if [[ -f "$CERT_HOOK" ]] && grep -qF "$MANAGED_MARKER" "$CERT_HOOK"; then
    CERT_HOOK_DELETE=1
  fi
}

prepare_letsencrypt_certificate() {
  [[ -n "${CERT_NAME:-}" ]] || die "missing CERT_NAME for letsencrypt mode"
  LE_CONFIG_DIR="${LE_CONFIG_DIR:-/etc/letsencrypt}"
  SERVER_CERT_FILE="${LE_CONFIG_DIR}/live/${CERT_NAME}/fullchain.pem"
  SERVER_KEY_FILE="${LE_CONFIG_DIR}/live/${CERT_NAME}/privkey.pem"
  validate_certificate_pair "$SERVER_CERT_FILE" "$SERVER_KEY_FILE"
  certificate_matches_endpoint "$SERVER_CERT_FILE" "$OCSERV_ENDPOINT" ||
    die "certificate SAN does not match endpoint"
}

prepare_certificate() {
  case "$OCSERV_CERT_MODE" in
    selfsigned) prepare_selfsigned_certificate ;;
    letsencrypt) prepare_letsencrypt_certificate ;;
    *) die "unsupported OCSERV_CERT_MODE: ${OCSERV_CERT_MODE}" ;;
  esac
}

render_certbot_hook() {
  local output="$1"
  install -d -m 0755 "$(dirname "$output")"
  cat >"$output" <<'HOOK_EOF'
#!/usr/bin/env bash
# Managed by vpn-node-maintenance: ocserv-deploy.sh

set -Eeuo pipefail

readonly CONFIG_FILE="${VPN_MAINTENANCE_CONFIG:-/etc/vpn-maintenance.env}"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

readonly CERT_LIVE_DIR="${LE_CONFIG_DIR:-/etc/letsencrypt}/live/${CERT_NAME}"
[[ "${RENEWED_LINEAGE:-}" == "$CERT_LIVE_DIR" ]] || exit 0
systemctl reload ocserv.service
HOOK_EOF
  chmod +x "$output"
}

# ==================== Network helper and systemd lifecycle ====================

# Renders a standalone, self-contained Bash helper implementing the
# nftables lifecycle contract (check/up/down). Only the validated
# OCSERV_IPV4_NETWORK subnet and the lock file path are substituted at
# render time; the egress interface is detected at the helper's own
# runtime, every invocation, so it always reflects the current default
# route. The lock path is rendered as "${ROOT_PREFIX}/run/lock/..."; when
# ROOT_PREFIX is empty (real production installs) this is byte-for-byte
# identical to the historical hardcoded "/run/lock/ocserv-network.lock",
# and under a test root (OCSERV_DEPLOY_ROOT set) it is confined under that
# root so tests never create or contend on the real host lock file.
render_network_helper() {
  local output="$1"
  [[ "$OCSERV_IPV4_NETWORK" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] ||
    die "invalid OCSERV_IPV4_NETWORK for network helper rendering"
  install -d -m 0755 "$(dirname "$output")"
  cat >"$output" <<'HELPER_EOF'
#!/usr/bin/env bash
# Managed by vpn-node-maintenance: ocserv-deploy.sh

set -Eeuo pipefail
readonly TABLE_FAMILY="ip"
readonly TABLE_NAME="vpn_node_ocserv"
readonly SENTINEL="_managed_by_vpn_node_maintenance"
readonly VPN_SUBNET="@@VPN_SUBNET@@"
readonly LOCK_FILE="@@LOCK_FILE@@"

log() {
  printf '%s [ocserv-network] %s\n' "$(date --iso-8601=seconds)" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

get_egress_interface() {
  local interface
  interface="$(
    ip -4 route get 1.1.1.1 |
      awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
  )"
  [[ "$interface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] ||
    die "cannot determine a safe IPv4 egress interface"
  printf '%s\n' "$interface"
}

table_exists() {
  nft list table "$TABLE_FAMILY" "$1" >/dev/null 2>&1
}

chain_exists() {
  nft list chain "$TABLE_FAMILY" "$1" "$2" >/dev/null 2>&1
}

# Verifies that the given table is either absent or owned by us (contains
# the sentinel chain). Never deletes anything; callers that need to delete
# must call this first and only proceed to delete after it succeeds.
ensure_table_ownership() {
  local table_name="$1"
  if table_exists "$table_name"; then
    chain_exists "$table_name" "$SENTINEL" ||
      die "table $table_name exists but is not managed by vpn-node-maintenance; refusing to modify"
  fi
}

delete_owned_table() {
  local table_name="$1"
  ensure_table_ownership "$table_name"
  if table_exists "$table_name"; then
    nft delete table "$TABLE_FAMILY" "$table_name"
  fi
}

render_ruleset() {
  local table_name="$1" interface="$2"
  cat <<RULESET_EOF
table $TABLE_FAMILY $table_name {
  chain $SENTINEL {
  }

  chain forward {
    type filter hook forward priority filter; policy accept;
    ip saddr $VPN_SUBNET oifname "$interface" accept
    ip daddr $VPN_SUBNET iifname "$interface" ct state established,related accept
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $VPN_SUBNET oifname "$interface" masquerade
  }
}
RULESET_EOF
}

# Holds the current temporary rule file path so the EXIT trap can clean it
# up. Declared at script scope (not "local") because it must still be
# bound under "set -u" when the trap fires at process exit, well after the
# function that created it has returned.
RULE_FILE=""

cmd_check() {
  # Validate ownership of the real table first so check enforces the same
  # safety contract as up/down, even though it never applies anything.
  ensure_table_ownership "$TABLE_NAME"
  local interface check_table
  interface="$(get_egress_interface)"
  check_table="${TABLE_NAME}_check_${BASHPID}"
  RULE_FILE="$(mktemp)"
  trap 'rm -f -- "$RULE_FILE"' EXIT
  render_ruleset "$check_table" "$interface" >"$RULE_FILE"
  nft --check -f "$RULE_FILE"
}

cmd_up() {
  ensure_table_ownership "$TABLE_NAME"
  local interface check_table
  interface="$(get_egress_interface)"
  RULE_FILE="$(mktemp)"
  trap 'rm -f -- "$RULE_FILE"' EXIT
  # Validate that the rendered ruleset would load BEFORE deleting the owned
  # active table, so a bad ruleset can never tear down the live table with
  # nothing to replace it. A disposable check-table name avoids a base-chain
  # collision with the still-present live table (same technique as cmd_check).
  check_table="${TABLE_NAME}_check_${BASHPID}"
  render_ruleset "$check_table" "$interface" >"$RULE_FILE"
  nft --check -f "$RULE_FILE"
  render_ruleset "$TABLE_NAME" "$interface" >"$RULE_FILE"
  if table_exists "$TABLE_NAME"; then
    nft delete table "$TABLE_FAMILY" "$TABLE_NAME"
  fi
  sysctl -w net.ipv4.ip_forward=1
  nft -f "$RULE_FILE"
}

cmd_down() {
  delete_owned_table "$TABLE_NAME"
}

main() {
  case "${1:-}" in
    check) cmd_check ;;
    up) cmd_up ;;
    down) cmd_down ;;
    *) die "usage: $(basename "$0") {check|up|down}" ;;
  esac
}

# Plain "mkdir -p" (no -m) so an already-existing directory is left
# untouched (mode/ownership unchanged): on real hosts /run/lock is a
# pre-existing tmpfs directory and this is a no-op; under a test root the
# parent may not exist yet and must be created.
mkdir -p -- "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock 9
main "$@"
HELPER_EOF
  sed -i "s|@@VPN_SUBNET@@|${OCSERV_IPV4_NETWORK}|" "$output"
  sed -i "s|@@LOCK_FILE@@|${ROOT_PREFIX}/run/lock/ocserv-network.lock|" "$output"
  chmod 0755 "$output"
}

# Renders the systemd drop-in that ties the nftables helper into the
# ocserv.service lifecycle. Uses the true absolute installed path for the
# helper regardless of any ROOT_PREFIX used for test isolation, since this
# content is only ever meaningful on the real running system.
render_systemd_dropin() {
  local output="$1"
  install -d -m 0755 "$(dirname "$output")"
  cat >"$output" <<EOF
$MANAGED_MARKER
[Unit]
Wants=network-online.target
After=network-online.target nftables.service
PartOf=nftables.service

[Service]
ExecStartPre=/usr/local/libexec/vpn-node/ocserv-network up
ExecStopPost=/usr/local/libexec/vpn-node/ocserv-network down
EOF
}

# ==================== Managed configuration ====================

is_managed_file() {
  local path="$1"
  [[ -f "$path" ]] && grep -Fqx "$MANAGED_MARKER" "$path"
}

check_existing_config() {
  if [[ -e "$OCSERV_CONF" ]]; then
    if ! is_managed_file "$OCSERV_CONF"; then
      local backup
      backup="${OCSERV_CONF}.pre-vpn-node-$(date -u +%Y%m%dT%H%M%SZ).bak"
      cp -a -- "$OCSERV_CONF" "$backup"
      die "existing unmanaged ocserv config backed up to $backup; refusing to overwrite"
    fi
  fi
}

render_ocserv_config() {
  local output="$1"
  local dns dns_lines=""
  for dns in "${NORMALIZED_DNS[@]}"; do
    dns_lines+="dns = ${dns}"$'\n'
  done
  cat >"$output" <<EOF
$MANAGED_MARKER
auth = "plain[$OCSERV_PASSWD]"
tcp-port = $OCSERV_PORT
udp-port = $OCSERV_PORT
run-as-user = nobody
run-as-group = daemon
socket-file = /run/ocserv.socket
occtl-socket-file = /run/occtl.socket
server-cert = $SERVER_CERT_FILE
server-key = $SERVER_KEY_FILE
isolate-workers = true
max-clients = 128
max-same-clients = 2
keepalive = 32400
dpd = 90
mobile-dpd = 1800
try-mtu-discovery = true
auth-timeout = 240
idle-timeout = 1200
mobile-idle-timeout = 1800
session-timeout = 0
cookie-timeout = 300
deny-roaming = false
tls-priorities = "NORMAL:%SERVER_PRECEDENCE:%COMPAT:-VERS-SSL3.0:-VERS-TLS1.0:-VERS-TLS1.1"
device = vpns
predictable-ips = true
ipv4-network = $OCSERV_NETWORK_ADDRESS
ipv4-netmask = $OCSERV_NETMASK
${dns_lines}route = default
cisco-client-compat = true
log-level = 1
use-occtl = true
EOF
}

ipv4_to_int() {
  local ip="$1"
  local a b c d
  IFS='.' read -r a b c d <<<"$ip"
  valid_ipv4 "$ip" || die "invalid IPv4 address in route: $ip"
  printf '%u\n' "$((((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d) & 0xFFFFFFFF))"
}

cidr_bounds() {
  local cidr="$1" address prefix ip_value mask start end
  if [[ "$cidr" == */* ]]; then
    address="${cidr%/*}"
    prefix="${cidr#*/}"
  else
    address="$cidr"
    prefix=32
  fi
  [[ "$prefix" =~ ^[0-9]+$ ]] && ((prefix >= 0 && prefix <= 32)) ||
    die "invalid route prefix: $cidr"
  ip_value="$(ipv4_to_int "$address")"
  if ((prefix == 0)); then
    mask=0
  else
    mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  fi
  start=$((ip_value & mask))
  end=$((start | ((~mask) & 0xFFFFFFFF)))
  printf '%u %u\n' "$start" "$end"
}

check_route_overlap() {
  local selected_start selected_end
  read -r selected_start selected_end < <(cidr_bounds "$OCSERV_IPV4_NETWORK")
  local line dest route_start route_end
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Skip ECMP multipath continuation lines (indented "nexthop ..."), which
    # are not route destinations; unrelated malformed destinations still fail.
    [[ "$line" =~ ^[[:space:]]*nexthop[[:space:]] ]] && continue
    dest="${line%% *}"
    [[ "$dest" == "default" ]] && continue
    read -r route_start route_end < <(cidr_bounds "$dest")
    if ((selected_start <= route_end && route_start <= selected_end)); then
      die "OCSERV_IPV4_NETWORK ${OCSERV_IPV4_NETWORK} overlaps existing route: $dest"
    fi
  done < <(ip -4 route show table main type unicast)
}

_configured_ocserv_port() {
  is_managed_file "$OCSERV_CONF" || return 1
  awk -F' = ' '$1 == "tcp-port" { print $2; found=1 } END { exit !found }' "$OCSERV_CONF"
}

check_port_available() {
  local configured_port="" managed_rerun=0
  if configured_port="$(_configured_ocserv_port)"; then
    managed_rerun=1
  fi
  local listeners
  listeners="$( { ss -H -ltnp "sport = :${OCSERV_PORT}"; ss -H -lunp "sport = :${OCSERV_PORT}"; } 2>/dev/null )"
  [[ -z "$listeners" ]] && return 0
  if ((managed_rerun)) && [[ "$OCSERV_PORT" == "$configured_port" ]]; then
    local line procs other
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      procs="$(grep -oP '"\K[^"]+(?=")' <<<"$line")"
      [[ -n "$procs" ]] || die "cannot determine process owning port ${OCSERV_PORT}"
      other="$(printf '%s\n' "$procs" | grep -v '^ocserv$' || true)"
      [[ -z "$other" ]] ||
        die "port ${OCSERV_PORT} is held by another process: $other"
    done <<<"$listeners"
    return 0
  fi
  die "port ${OCSERV_PORT} is already in use"
}

test_ocserv_config() {
  local temp_conf="$1"
  ocserv -c "$temp_conf" --test-config
}

# ==================== User management ====================

validate_username() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]
}

user_exists() {
  local username="$1"
  local password_file="${2:-$OCSERV_PASSWD}"
  [[ -f "$password_file" ]] &&
    awk -F: -v user="$username" '$1 == user { found=1 } END { exit !found }' \
      "$password_file"
}

CONFIRMED_PASSWORD=""

read_confirmed_password() {
  local p1 p2
  read -r -s -p "Password: " p1
  printf '\n'
  read -r -s -p "Confirm password: " p2
  printf '\n'
  [[ -n "$p1" ]] || die "password cannot be empty"
  [[ "$p1" == "$p2" ]] || die "passwords do not match"
  CONFIRMED_PASSWORD="$p1"
}

set_user_password() {
  local username="$1"
  local password_file="${2:-$OCSERV_PASSWD}"
  [[ -f "$password_file" ]] || install -m 0600 /dev/null "$password_file"
  local rc=0
  printf '%s\n%s\n' "$CONFIRMED_PASSWORD" "$CONFIRMED_PASSWORD" |
    ocpasswd -c "$password_file" "$username" || rc=$?
  unset CONFIRMED_PASSWORD
  return $rc
}

add_user() {
  local username="$1"
  local password_file="${2:-$OCSERV_PASSWD}"
  validate_username "$username" || die "invalid username: $username"
  if user_exists "$username" "$password_file"; then
    die "user already exists: $username"
  fi
  [[ -f "$password_file" ]] || install -m 0600 /dev/null "$password_file"
  read_confirmed_password
  set_user_password "$username" "$password_file"
}

delete_user() {
  local username="$1"
  local password_file="${2:-$OCSERV_PASSWD}"
  validate_username "$username" || die "invalid username: $username"
  user_exists "$username" "$password_file" || die "user not found: $username"
  ocpasswd -c "$password_file" -d "$username"
}

ensure_initial_user() {
  local password_file="$1"
  [[ -f "$password_file" ]] || install -m 0600 /dev/null "$password_file"
  if ! awk -F: 'NF { found=1 } END { exit !found }' "$password_file"; then
    local username
    read -r -p "Username for initial VPN user: " username
    add_user "$username" "$password_file"
  fi
}

# ==================== Platform and dependencies ====================

# Packages remain installed even if a later transactional step fails; the
# rollback contract covers configuration state, not the package database.
install_dependencies() {
  command -v apt-get >/dev/null 2>&1 ||
    die "required command not found: apt-get"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ocserv nftables openssl iproute2 util-linux
}

# ==================== Transaction and rollback ====================

_snapshot_key() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'
}

# Records existence and mode for one exact target path, backing up any
# existing file so rollback can restore it byte-for-byte.
snapshot_target() {
  local path="$1" slug
  slug="$(_snapshot_key "$path")"
  SNAPSHOT_TARGETS+=("$path")
  if [[ -e "$path" ]]; then
    SNAPSHOT_EXISTED["$path"]=1
    SNAPSHOT_MODE["$path"]="$(stat -c '%a' "$path")"
    cp -a -- "$path" "${TXN_DIR}/backup/${slug}"
  else
    SNAPSHOT_EXISTED["$path"]=0
  fi
}

begin_transaction() {
  install -d -m 0700 "$TRANSACTION_DIR_ROOT"
  TXN_DIR="$(mktemp -d "${TRANSACTION_DIR_ROOT}/txn.XXXXXX")"
  install -d -m 0700 "${TXN_DIR}/backup" "${TXN_DIR}/stage"
  STAGED_OCSERV_CONF="${TXN_DIR}/stage/ocserv.conf"
  STAGED_OCSERV_PASSWD="${TXN_DIR}/stage/ocpasswd"
  STAGED_NETWORK_HELPER="${TXN_DIR}/stage/ocserv-network"
  STAGED_SYSTEMD_DROPIN="${TXN_DIR}/stage/10-network.conf"
  STAGED_CERT_HOOK="${TXN_DIR}/stage/20-ocserv"
  STAGED_SELF_SIGNED_CERT="${TXN_DIR}/stage/selfsigned-cert.pem"
  STAGED_SELF_SIGNED_KEY="${TXN_DIR}/stage/selfsigned-key.pem"
  SNAPSHOT_TARGETS=()
  SNAPSHOT_EXISTED=()
  SNAPSHOT_MODE=()
  if systemctl is-active --quiet ocserv.service; then
    SERVICE_WAS_ACTIVE=1
  else
    SERVICE_WAS_ACTIVE=0
  fi
  if systemctl is-enabled --quiet ocserv.service 2>/dev/null; then
    SERVICE_WAS_ENABLED=1
  else
    SERVICE_WAS_ENABLED=0
  fi
  ROLLBACK_RUNNING=0
  TRANSACTION_ACTIVE=1
  trap 'rollback_transaction $?' ERR
  trap 'rollback_transaction 130' INT
  trap 'rollback_transaction 143' TERM
}

# Idempotent, trap-guarded rollback. Restores every snapshotted target to
# its prior state (or removes it if it did not exist before), reloads
# systemd, and restores the previous enabled/active service state.
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
    local path slug
    for path in "${SNAPSHOT_TARGETS[@]}"; do
      slug="$(_snapshot_key "$path")"
      if [[ "${SNAPSHOT_EXISTED[$path]:-0}" == "1" ]]; then
        install -D -m "${SNAPSHOT_MODE[$path]}" "${TXN_DIR}/backup/${slug}" "$path"
      else
        rm -f -- "$path"
      fi
    done
    systemctl daemon-reload
    if ((SERVICE_WAS_ENABLED)); then
      systemctl enable ocserv.service
    else
      systemctl disable ocserv.service
    fi
    if ((SERVICE_WAS_ACTIVE)); then
      systemctl restart ocserv.service
    else
      systemctl stop ocserv.service
    fi
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

# ==================== Staging and atomic install ====================

# Refuses to touch a target that exists but is not owned by this tool, so
# unknown helper/drop-in/hook collisions are never overwritten or deleted.
guard_managed_or_absent() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  is_managed_file "$path" ||
    die "refusing to overwrite unmanaged file: $path"
}

check_managed_targets() {
  guard_managed_or_absent "$NETWORK_HELPER"
  guard_managed_or_absent "$SYSTEMD_DROPIN"
  if [[ "$OCSERV_CERT_MODE" == "letsencrypt" ]]; then
    guard_managed_or_absent "$CERT_HOOK"
  fi
}

# Renders every managed file into the transaction staging directory and
# copies (or creates) the password database there. Nothing here becomes
# live; install_staged_files performs the atomic replacement later.
stage_managed_files() {
  render_ocserv_config "$STAGED_OCSERV_CONF"
  chmod 0600 "$STAGED_OCSERV_CONF"
  render_network_helper "$STAGED_NETWORK_HELPER"
  render_systemd_dropin "$STAGED_SYSTEMD_DROPIN"
  if [[ -f "$OCSERV_PASSWD" ]]; then
    install -m 0600 "$OCSERV_PASSWD" "$STAGED_OCSERV_PASSWD"
  else
    install -m 0600 /dev/null "$STAGED_OCSERV_PASSWD"
  fi
  if [[ "$OCSERV_CERT_MODE" == "letsencrypt" ]]; then
    render_certbot_hook "$STAGED_CERT_HOOK"
  else
    install -m 0600 "$SERVER_KEY_FILE" "$STAGED_SELF_SIGNED_KEY"
    install -m 0644 "$SERVER_CERT_FILE" "$STAGED_SELF_SIGNED_CERT"
  fi
}

validate_staged_files() {
  test_ocserv_config "$STAGED_OCSERV_CONF"
  "$STAGED_NETWORK_HELPER" check
}

# Atomically installs one file: stage a same-filesystem temporary target
# with the final mode, then rename it over the destination. If either the
# install or the rename fails, the same-directory temp is removed before the
# failure propagates (and triggers rollback), so no stray temp is left behind.
_atomic_install_file() {
  local mode="$1" src="$2" dest="$3" dir tmp
  dir="$(dirname "$dest")"
  [[ -d "$dir" ]] || install -d -m 0755 "$dir"
  tmp="$(mktemp "${dir}/.ocserv-deploy.XXXXXX")"
  if ! install -m "$mode" "$src" "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    die "failed to atomically install $dest"
  fi
}

# Promotes the staged files to their live locations with fixed modes. Only
# invoked after the staged password database has been populated.
install_staged_files() {
  _atomic_install_file 0600 "$STAGED_OCSERV_CONF" "$OCSERV_CONF"
  _atomic_install_file 0600 "$STAGED_OCSERV_PASSWD" "$OCSERV_PASSWD"
  _atomic_install_file 0755 "$STAGED_NETWORK_HELPER" "$NETWORK_HELPER"
  _atomic_install_file 0644 "$STAGED_SYSTEMD_DROPIN" "$SYSTEMD_DROPIN"
  if [[ "$OCSERV_CERT_MODE" == "letsencrypt" ]]; then
    _atomic_install_file 0755 "$STAGED_CERT_HOOK" "$CERT_HOOK"
  else
    install -d -m 0700 "$(dirname "$SELF_SIGNED_KEY")"
    _atomic_install_file 0600 "$STAGED_SELF_SIGNED_KEY" "$SELF_SIGNED_KEY"
    _atomic_install_file 0644 "$STAGED_SELF_SIGNED_CERT" "$SELF_SIGNED_CERT"
    if [[ -n "$CERT_HOOK_DELETE" ]]; then
      rm -f -- "$CERT_HOOK"
    fi
  fi
}

# ==================== Service activation and verification ====================

activate_service() {
  systemctl daemon-reload
  systemctl enable ocserv.service
  systemctl restart ocserv.service
}

verify_service() {
  systemctl is-active --quiet ocserv.service ||
    die "ocserv.service is not active after restart"
  [[ -n "$(ss -H -ltn "sport = :${OCSERV_PORT}")" ]] ||
    die "no TCP listener on port ${OCSERV_PORT}"
  [[ -n "$(ss -H -lun "sport = :${OCSERV_PORT}")" ]] ||
    die "no UDP listener on port ${OCSERV_PORT}"
}

print_install_summary() {
  printf 'OpenConnect endpoint: %s:%s\n' "$OCSERV_ENDPOINT" "$OCSERV_PORT"
  printf 'Azure NSG required: allow TCP %s and UDP %s\n' "$OCSERV_PORT" "$OCSERV_PORT"
  printf 'Certificate mode: %s\n' "$OCSERV_CERT_MODE"
  if [[ "$OCSERV_CERT_MODE" == "selfsigned" ]]; then
    local fingerprint pin
    fingerprint="$(
      openssl x509 -in "$SELF_SIGNED_CERT" -noout -fingerprint -sha256 |
        sed 's/^.*=//'
    )"
    pin="$(
      openssl x509 -in "$SELF_SIGNED_CERT" -pubkey -noout |
        openssl pkey -pubin -outform DER |
        openssl dgst -sha256 -binary |
        openssl enc -base64
    )"
    printf 'Certificate SHA-256 fingerprint: %s\n' "$fingerprint"
    printf 'pin-sha256: %s\n' "$pin"
  fi
}

# Orchestrates the transactional install: snapshot, stage, validate,
# populate the password DB, atomically install, activate, and verify.
install_server() {
  begin_transaction
  snapshot_target "$OCSERV_CONF"
  snapshot_target "$OCSERV_PASSWD"
  snapshot_target "$SELF_SIGNED_CERT"
  snapshot_target "$SELF_SIGNED_KEY"
  snapshot_target "$NETWORK_HELPER"
  snapshot_target "$SYSTEMD_DROPIN"
  snapshot_target "$CERT_HOOK"
  prepare_certificate
  stage_managed_files
  validate_staged_files
  ensure_initial_user "$STAGED_OCSERV_PASSWD"
  install_staged_files
  activate_service
  verify_service
  commit_transaction
  print_install_summary
}

usage() {
  printf '%s\n' \
    "Usage: ocserv-deploy.sh install" \
    "       ocserv-deploy.sh add-user [USERNAME]" \
    "       ocserv-deploy.sh del-user [USERNAME]" \
    "       ocserv-deploy.sh help"
}

main() {
  case "${1:-help}" in
    help|-h|--help)
      usage
      return
      ;;
    install)
      require_root
      # Plain "mkdir -p" (no -m) so an already-existing directory is left
      # untouched: the real /run/lock is a pre-existing tmpfs directory with
      # the sticky 1777 mode, and "install -d -m 0755" would strip that to
      # 0755. Under a test root the parent may not exist yet and is created.
      mkdir -p -- "$(dirname "$INSTALL_LOCK")"
      exec 9>"$INSTALL_LOCK"
      flock -n 9 || die "another installation is running"
      load_config
      validate_common_config
      check_existing_config
      check_managed_targets
      check_route_overlap
      check_port_available
      install_dependencies
      install_server
      ;;
    add-user)
      require_root
      load_config
      validate_common_config
      command -v ocpasswd >/dev/null 2>&1 || die "ocpasswd not found in PATH"
      local username="${2:-}"
      if [[ -z "$username" ]]; then
        read -r -p "Username: " username
      fi
      add_user "$username"
      ;;
    del-user)
      require_root
      load_config
      validate_common_config
      command -v ocpasswd >/dev/null 2>&1 || die "ocpasswd not found in PATH"
      local username="${2:-}"
      if [[ -z "$username" ]]; then
        read -r -p "Username: " username
      fi
      delete_user "$username"
      ;;
    *)
      usage >&2
      die "unknown command: ${1:-}"
      ;;
  esac
}

if [[ "${OCSERV_DEPLOY_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
