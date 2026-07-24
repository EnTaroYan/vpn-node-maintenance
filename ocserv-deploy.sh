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
  declare -p OCSERV_DNS >/dev/null 2>&1 ||
    die "OCSERV_DNS must be a Bash array"
  NORMALIZED_DNS=("${OCSERV_DNS[@]}")
  ((${#NORMALIZED_DNS[@]} > 0)) || die "OCSERV_DNS cannot be empty"
  local dns
  for dns in "${NORMALIZED_DNS[@]}"; do
    valid_ipv4 "$dns" || die "invalid DNS address: $dns"
  done
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
