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
CONF_EXISTED_BEFORE_INSTALL=0

log() {
  printf '%s [ocserv-deploy] %s\n' "$(date --iso-8601=seconds)" "$*"
}

die() {
  log "ERROR: $*" >&2
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
  # Unrelated errors produce no match text and a nonzero exit code — propagate.
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
    temp_cert="$(mktemp "$(dirname "$SELF_SIGNED_CERT")/.cert.XXXXXX")"
    temp_key="$(mktemp "$(dirname "$SELF_SIGNED_KEY")/.key.XXXXXX")"
    trap 'rm -f -- "$temp_cert" "$temp_key"' EXIT
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

# ==================== Managed configuration ====================

is_managed_file() {
  local path="$1"
  [[ -f "$path" ]] && grep -Fqx "$MANAGED_MARKER" "$path"
}

check_existing_config() {
  if [[ -e "$OCSERV_CONF" ]]; then
    CONF_EXISTED_BEFORE_INSTALL=1
    if ! is_managed_file "$OCSERV_CONF"; then
      local backup
      backup="${OCSERV_CONF}.pre-vpn-node-$(date -u +%Y%m%dT%H%M%SZ).bak"
      cp -a -- "$OCSERV_CONF" "$backup"
      die "existing unmanaged ocserv config backed up to $backup; refusing to overwrite"
    fi
  else
    CONF_EXISTED_BEFORE_INSTALL=0
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
      load_config
      validate_common_config
      die "unsupported command in configuration-only build: $1"
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
