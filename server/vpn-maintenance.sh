#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly CONFIG_FILE="${VPN_MAINTENANCE_CONFIG:-/etc/vpn-maintenance.env}"
readonly LOCK_DIR="${VPN_MAINTENANCE_LOCK_DIR:-/run/lock}"
readonly CF_API_BASE="https://api.cloudflare.com/client/v4"

declare -a DDNS_RECORD_NAMES=()
declare -a REQUESTED_CERT_DOMAINS=()

log() {
  printf '%s [vpn-maintenance] %s\n' "$(date --iso-8601=seconds)" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: vpn-maintenance.sh COMMAND

Commands:
  ddns         Update Cloudflare DNS-only A records when the public IP changes
  issue-cert   Obtain or expand a Let's Encrypt certificate through Cloudflare DNS-01
  renew-cert   Ask Certbot to renew the configured certificate when it is due
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "run this command as root"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "missing required setting: $name"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "configuration file not found: $CONFIG_FILE"
  [[ ! -L "$CONFIG_FILE" ]] || die "configuration file must not be a symbolic link"
  [[ "$(stat -c '%u' "$CONFIG_FILE")" -eq 0 ]] ||
    die "configuration file must be owned by root"

  local mode
  mode="$(stat -c '%a' "$CONFIG_FILE")"
  [[ "$mode" == "600" || "$mode" == "400" ]] ||
    die "configuration file permissions must be 600 or 400"

  # This file is trusted because it is root-owned and not writable by other users.
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  CF_IP_CHECK_URL="${CF_IP_CHECK_URL:-https://cloudflare.com/cdn-cgi/trace}"
  CF_TTL="${CF_TTL:-1}"
  CERTBOT_BIN="${CERTBOT_BIN:-certbot}"
  LE_CONFIG_DIR="${LE_CONFIG_DIR:-/etc/letsencrypt}"
}

acquire_lock() {
  local name="$1"
  mkdir -p "$LOCK_DIR"
  exec 9>"${LOCK_DIR}/vpn-maintenance-${name}.lock"
  if ! flock -n 9; then
    log "another $name operation is already running; skipping"
    exit 0
  fi
}

valid_ipv4() {
  local ip="$1"
  local octet
  local -a octets

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$ip"
  [[ "${#octets[@]}" -eq 4 ]] || return 1

  for octet in "${octets[@]}"; do
    ((10#"$octet" <= 255)) || return 1
  done
}

valid_hostname() {
  local hostname="${1%.}"
  local label
  local -a labels

  [[ -n "$hostname" && ${#hostname} -le 253 && "$hostname" == *.* ]] ||
    return 1
  [[ "$hostname" != *..* ]] || return 1

  IFS='.' read -r -a labels <<<"$hostname"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
      return 1
  done
}

valid_certificate_domain() {
  local domain="$1"

  if [[ "$domain" == "*."* ]]; then
    valid_hostname "${domain#*.}"
  else
    valid_hostname "$domain"
  fi
}

get_public_ipv4() {
  local response
  local ip

  response="$(
    curl -4 --silent --show-error --fail-with-body \
      --connect-timeout 10 --max-time 20 "$CF_IP_CHECK_URL"
  )"

  ip="$(awk -F= '$1 == "ip" { print $2; exit }' <<<"$response")"
  if [[ -z "$ip" ]]; then
    ip="$(head -n 1 <<<"$response")"
  fi

  ip="$(tr -d '[:space:]' <<<"$ip")"
  valid_ipv4 "$ip" || die "public IP endpoint returned an invalid IPv4 address"
  printf '%s\n' "$ip"
}

cloudflare_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local -a args=(
    --silent
    --show-error
    --fail-with-body
    --request "$method"
    --url "${CF_API_BASE}${path}"
  )

  if [[ -n "$data" ]]; then
    args+=(--data "$data")
  fi

  # Read the authorization header from stdin so the token is not exposed in argv.
  printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' \
    "$CF_DDNS_API_TOKEN" |
    curl --config - "${args[@]}"
}

assert_cloudflare_success() {
  local response="$1"
  local errors

  if ! jq -e '.success == true' >/dev/null <<<"$response"; then
    errors="$(jq -c '.errors // []' <<<"$response" 2>/dev/null || true)"
    die "Cloudflare API request failed: ${errors:-invalid response}"
  fi
}

validate_ddns_config() {
  local record_name
  local index
  local -A seen=()

  require_var CF_DDNS_API_TOKEN
  require_var CF_ZONE_ID

  [[ "$CF_ZONE_ID" =~ ^[0-9a-fA-F]{32}$ ]] ||
    die "CF_ZONE_ID must be a 32-character hexadecimal zone ID"

  if declare -p CF_RECORD_NAMES >/dev/null 2>&1; then
    DDNS_RECORD_NAMES=("${CF_RECORD_NAMES[@]}")
  elif [[ -n "${CF_RECORD_NAME:-}" ]]; then
    DDNS_RECORD_NAMES=("$CF_RECORD_NAME")
  fi

  ((${#DDNS_RECORD_NAMES[@]} > 0)) ||
    die "set CF_RECORD_NAMES or the legacy CF_RECORD_NAME"

  for index in "${!DDNS_RECORD_NAMES[@]}"; do
    record_name="${DDNS_RECORD_NAMES[$index],,}"
    record_name="${record_name%.}"
    valid_hostname "$record_name" ||
      die "invalid DNS record name: ${DDNS_RECORD_NAMES[$index]}"
    [[ -z "${seen[$record_name]+x}" ]] ||
      die "duplicate DNS record name: $record_name"
    seen["$record_name"]=1
    DDNS_RECORD_NAMES[$index]="$record_name"
  done

  [[ "$CF_TTL" =~ ^[0-9]+$ ]] || die "CF_TTL must be numeric"
  if ((CF_TTL != 1 && (CF_TTL < 60 || CF_TTL > 86400))); then
    die "CF_TTL must be 1 (automatic) or between 60 and 86400"
  fi
}

sync_ddns_record() {
  local record_name="$1"
  local public_ip="$2"
  local query_response
  local record_count
  local record_id
  local current_ip
  local current_proxied
  local current_ttl
  local payload
  local update_response

  query_response="$(
    cloudflare_request GET \
      "/zones/${CF_ZONE_ID}/dns_records?type=A&name=${record_name}"
  )"
  assert_cloudflare_success "$query_response"

  record_count="$(jq '.result | length' <<<"$query_response")"
  case "$record_count" in
    0)
      payload="$(
        jq -cn \
          --arg name "$record_name" \
          --arg content "$public_ip" \
          --argjson ttl "$CF_TTL" \
          '{type:"A", name:$name, content:$content, ttl:$ttl, proxied:false}'
      )"
      update_response="$(
        cloudflare_request POST "/zones/${CF_ZONE_ID}/dns_records" "$payload"
      )"
      assert_cloudflare_success "$update_response"
      log "created DNS-only A record ${record_name} -> ${public_ip}"
      ;;
    1)
      record_id="$(jq -r '.result[0].id' <<<"$query_response")"
      current_ip="$(jq -r '.result[0].content' <<<"$query_response")"
      current_proxied="$(jq -r '.result[0].proxied // false' <<<"$query_response")"
      current_ttl="$(jq -r '.result[0].ttl' <<<"$query_response")"

      if [[ "$current_ip" == "$public_ip" &&
            "$current_proxied" == "false" &&
            "$current_ttl" == "$CF_TTL" ]]; then
        log "DNS record is current: ${record_name} -> ${public_ip}"
        return
      fi

      payload="$(
        jq -cn \
          --arg content "$public_ip" \
          --argjson ttl "$CF_TTL" \
          '{content:$content, ttl:$ttl, proxied:false}'
      )"
      update_response="$(
        cloudflare_request PATCH \
          "/zones/${CF_ZONE_ID}/dns_records/${record_id}" "$payload"
      )"
      assert_cloudflare_success "$update_response"
      log "updated DNS-only A record ${record_name}: ${current_ip} -> ${public_ip}"
      ;;
    *)
      die "multiple A records found for ${record_name}; refusing to choose one"
      ;;
  esac
}

update_ddns() {
  local public_ip
  local record_name

  require_command curl
  require_command jq
  require_command flock
  validate_ddns_config
  acquire_lock ddns

  public_ip="$(get_public_ipv4)"
  for record_name in "${DDNS_RECORD_NAMES[@]}"; do
    sync_ddns_record "$record_name" "$public_ip"
  done
}

validate_certificate_config() {
  local domain
  local index
  local -A seen=()

  require_var CERT_NAME
  require_var LE_EMAIL
  require_var CF_DNS_CREDENTIALS_FILE

  valid_hostname "$CERT_NAME" || die "CERT_NAME must be a valid DNS name"

  if declare -p CERT_DOMAINS >/dev/null 2>&1; then
    REQUESTED_CERT_DOMAINS=("${CERT_DOMAINS[@]}")
  else
    REQUESTED_CERT_DOMAINS=("$CERT_NAME")
  fi

  ((${#REQUESTED_CERT_DOMAINS[@]} > 0)) ||
    die "CERT_DOMAINS must contain at least one DNS name"

  for index in "${!REQUESTED_CERT_DOMAINS[@]}"; do
    domain="${REQUESTED_CERT_DOMAINS[$index],,}"
    domain="${domain%.}"
    valid_certificate_domain "$domain" ||
      die "invalid certificate domain: ${REQUESTED_CERT_DOMAINS[$index]}"
    [[ -z "${seen[$domain]+x}" ]] ||
      die "duplicate certificate domain: $domain"
    seen["$domain"]=1
    REQUESTED_CERT_DOMAINS[$index]="$domain"
  done

  [[ -f "$CF_DNS_CREDENTIALS_FILE" ]] ||
    die "Cloudflare ACME credentials file not found: $CF_DNS_CREDENTIALS_FILE"
  [[ "$(stat -c '%u' "$CF_DNS_CREDENTIALS_FILE")" -eq 0 ]] ||
    die "Cloudflare ACME credentials file must be owned by root"

  local mode
  mode="$(stat -c '%a' "$CF_DNS_CREDENTIALS_FILE")"
  [[ "$mode" == "600" || "$mode" == "400" ]] ||
    die "Cloudflare ACME credentials file permissions must be 600 or 400"
}

issue_certificate() {
  local domain
  local -a domain_args=()
  local -a lineage_args=()

  require_command "$CERTBOT_BIN"
  validate_certificate_config
  acquire_lock certificate

  for domain in "${REQUESTED_CERT_DOMAINS[@]}"; do
    domain_args+=(-d "$domain")
  done

  if [[ -f "${LE_CONFIG_DIR}/renewal/${CERT_NAME}.conf" ]]; then
    lineage_args+=(--expand)
  fi

  "$CERTBOT_BIN" certonly \
    --non-interactive \
    --agree-tos \
    --email "$LE_EMAIL" \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_DNS_CREDENTIALS_FILE" \
    --cert-name "$CERT_NAME" \
    "${domain_args[@]}" \
    "${lineage_args[@]}" \
    --key-type rsa \
    --rsa-key-size 2048 \
    --reuse-key

  log "issued or updated certificate: ${CERT_NAME} (${REQUESTED_CERT_DOMAINS[*]})"
}

renew_certificate() {
  require_command "$CERTBOT_BIN"
  require_var CERT_NAME
  acquire_lock certificate

  [[ -f "${LE_CONFIG_DIR}/renewal/${CERT_NAME}.conf" ]] ||
    die "certificate lineage not found; run issue-cert first"

  "$CERTBOT_BIN" renew --cert-name "$CERT_NAME" --quiet
  log "completed certificate renewal check: ${CERT_NAME}"
}

main() {
  local command="${1:-}"

  case "$command" in
    -h|--help|help)
      usage
      return
      ;;
    ddns|issue-cert|renew-cert)
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac

  require_root
  require_command stat
  load_config

  case "$command" in
    ddns)
      update_ddns
      ;;
    issue-cert)
      issue_certificate
      ;;
    renew-cert)
      renew_certificate
      ;;
  esac
}

main "$@"
