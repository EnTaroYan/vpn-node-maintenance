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
  local cert="$1" endpoint="$2" result
  if valid_ipv4 "$endpoint"; then
    result="$(openssl x509 -in "$cert" -noout -checkip "$endpoint" 2>/dev/null)"
  else
    result="$(openssl x509 -in "$cert" -noout -checkhost "$endpoint" 2>/dev/null)"
  fi
  # OpenSSL 3.x -checkhost/-checkip always exits 0; distinguish via output text
  [[ "$result" == *"does match"* ]]
}

generate_self_signed_certificate() {
  install -d -m 0700 "$(dirname "$SELF_SIGNED_CERT")"
  local temp_cert temp_key san_type
  temp_cert="$(mktemp "$(dirname "$SELF_SIGNED_CERT")/.cert.XXXXXX")"
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
  rm -f -- "$temp_cert" "$temp_key"
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
    install|add-user|del-user)
      require_root
      load_config
      validate_common_config
      die "unsupported command in configuration-only build: $1"
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
