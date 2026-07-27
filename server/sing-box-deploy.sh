#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# ==================== Constants and paths ====================

readonly MANAGED_MARKER_TEXT="Managed by vpn-node-maintenance: sing-box-deploy.sh"
readonly MANAGED_MARKER="# ${MANAGED_MARKER_TEXT}"
readonly MANAGED_MARKER_JSON="// ${MANAGED_MARKER_TEXT}"

readonly CONFIG_FILE="${SINGBOX_DEPLOY_CONFIG:-/etc/vpn-node/sing-box.env}"
readonly ROOT_PREFIX="${SINGBOX_DEPLOY_ROOT:-}"

# Live (prefixed) target paths. Under a test root ($SINGBOX_DEPLOY_ROOT set)
# every path is confined below that root so tests never touch real files; in
# production ROOT_PREFIX is empty and these are the real absolute paths.
readonly SINGBOX_CONFIG="${ROOT_PREFIX}/etc/sing-box/config.json"
readonly STATE_FILE="${ROOT_PREFIX}/etc/vpn-node/sing-box-state.env"
readonly CLIENT_FILE="${ROOT_PREFIX}/etc/vpn-node/sing-box-client.env"
readonly SYSTEMD_UNIT="${ROOT_PREFIX}/etc/systemd/system/sing-box.service"
readonly NFT_INCLUDE="${ROOT_PREFIX}/etc/sing-box/hy2-hopping.nft"
readonly SELF_SIGNED_CERT="${ROOT_PREFIX}/etc/sing-box/tls/hy2-selfsigned-cert.pem"
readonly SELF_SIGNED_KEY="${ROOT_PREFIX}/etc/sing-box/tls/hy2-selfsigned-key.pem"
readonly INSTALL_LOCK="${ROOT_PREFIX}/run/lock/sing-box-deploy.lock"

# The systemd unit and config path baked into it are only ever meaningful on
# the real running host, so they use the true absolute paths regardless of any
# test ROOT_PREFIX (mirrors the ocserv drop-in convention).
readonly SERVICE_CONFIG_PATH="/etc/sing-box/config.json"

readonly NFT_FAMILY="ip"
readonly NFT_TABLE="vpn_node_singbox"
readonly NFT_SENTINEL="_managed_by_vpn_node_maintenance"

# Root-only transaction workspace under /run (prefixed for test isolation).
readonly TRANSACTION_DIR_ROOT="${ROOT_PREFIX}/run/sing-box-deploy"
TXN_DIR=""
STAGED_CONFIG=""
STAGED_UNIT=""
STAGED_STATE=""
STAGED_CLIENT=""
STAGED_NFT=""
STAGED_CERT=""
STAGED_KEY=""

TRANSACTION_ACTIVE=0
ROLLBACK_RUNNING=0
SERVICE_WAS_ACTIVE=0
SERVICE_WAS_ENABLED=0
declare -ga SNAPSHOT_TARGETS=()
declare -gA SNAPSHOT_EXISTED=()
declare -gA SNAPSHOT_MODE=()

# Resolved configuration/secret state (populated at run time).
SERVER_CERT_FILE=""
SERVER_KEY_FILE=""
HY2_PORTS_RANGE=""
HY2_PIN_SHA256=""
HY2_CERT_PEM_B64=""

log() {
  printf '%s [sing-box-deploy] %s\n' "$(date --iso-8601=seconds)" "$*"
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
  SERVER_IPV4="${SERVER_IPV4:-}"
  HY2_PORT="${HY2_PORT:-443}"
  HY2_PORTS="${HY2_PORTS:-}"
  HY2_CERT_MODE="${HY2_CERT_MODE:-selfsigned}"
  HY2_CERT_FILE="${HY2_CERT_FILE:-}"
  HY2_KEY_FILE="${HY2_KEY_FILE:-}"
  HY2_SNI="${HY2_SNI:-}"
  HY2_UP_MBPS="${HY2_UP_MBPS:-}"
  HY2_DOWN_MBPS="${HY2_DOWN_MBPS:-}"
  REALITY_PORT="${REALITY_PORT:-443}"
  REALITY_TARGET="${REALITY_TARGET:-}"
  REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-}"
  CREATE_SWAP_MB="${CREATE_SWAP_MB:-0}"
  # Optional secrets: empty means "generate or reuse persisted value".
  HY2_PASSWORD="${HY2_PASSWORD:-}"
  SALAMANDER_PASSWORD="${SALAMANDER_PASSWORD:-}"
  VLESS_UUID="${VLESS_UUID:-}"
  REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"
  REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-}"
  REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"
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
  [[ "${labels[-1]}" =~ ^[0-9]+$ ]] && return 1
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
      return 1
  done
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

validate_config() {
  [[ -n "$SERVER_IPV4" ]] || die "SERVER_IPV4 is required"
  valid_ipv4 "$SERVER_IPV4" || die "SERVER_IPV4 must be a valid IPv4 address"

  valid_port "$HY2_PORT" || die "HY2_PORT must be between 1 and 65535"
  valid_port "$REALITY_PORT" || die "REALITY_PORT must be between 1 and 65535"

  case "$HY2_CERT_MODE" in
    letsencrypt|selfsigned) ;;
    *) die "HY2_CERT_MODE must be letsencrypt or selfsigned" ;;
  esac

  [[ -n "$REALITY_TARGET" ]] || die "REALITY_TARGET is required"
  valid_hostname "$REALITY_TARGET" ||
    die "REALITY_TARGET must be a valid domain name"
  [[ -n "$REALITY_SERVER_NAME" ]] || REALITY_SERVER_NAME="$REALITY_TARGET"
  valid_hostname "$REALITY_SERVER_NAME" ||
    die "REALITY_SERVER_NAME must be a valid domain name"

  if [[ -n "$HY2_PORTS" ]]; then
    [[ "$HY2_PORTS" =~ ^([0-9]+):([0-9]+)$ ]] ||
      die "HY2_PORTS must be START:END (e.g. 20000:50000)"
    local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
    valid_port "$start" && valid_port "$end" ||
      die "HY2_PORTS ports must be between 1 and 65535"
    ((10#$start < 10#$end)) || die "HY2_PORTS start must be less than end"
    HY2_PORTS_RANGE="${start}-${end}"
  else
    HY2_PORTS_RANGE=""
  fi

  [[ -z "$HY2_UP_MBPS" ]] ||
    { [[ "$HY2_UP_MBPS" =~ ^[0-9]+$ ]] && ((10#$HY2_UP_MBPS >= 1)); } ||
    die "HY2_UP_MBPS must be a positive integer"
  [[ -z "$HY2_DOWN_MBPS" ]] ||
    { [[ "$HY2_DOWN_MBPS" =~ ^[0-9]+$ ]] && ((10#$HY2_DOWN_MBPS >= 1)); } ||
    die "HY2_DOWN_MBPS must be a positive integer"

  [[ "$CREATE_SWAP_MB" =~ ^[0-9]+$ ]] ||
    die "CREATE_SWAP_MB must be a non-negative integer"

  if [[ "$HY2_CERT_MODE" == "letsencrypt" ]]; then
    [[ -n "$HY2_CERT_FILE" && -n "$HY2_KEY_FILE" ]] ||
      die "letsencrypt mode requires HY2_CERT_FILE and HY2_KEY_FILE"
  fi
}

# ==================== Secret generation and persistence ====================

# Seams: overridable by tests after sourcing so generated values are
# deterministic and no production entropy source is invoked under the suite.
gen_random_b64() { openssl rand -base64 "${1:-24}"; }
gen_random_hex() { openssl rand -hex "${1:-8}"; }
generate_uuid() { uuidgen; }
generate_reality_keypair() { sing-box generate reality-keypair; }

# Populates every secret variable, preferring (in order) an explicit env
# value, an already-persisted state value, then a freshly generated one. This
# gives stable secrets across reruns while still honouring env overrides.
resolve_secrets() {
  local env_hy2="$HY2_PASSWORD" env_sal="$SALAMANDER_PASSWORD"
  local env_uuid="$VLESS_UUID" env_priv="$REALITY_PRIVATE_KEY"
  local env_pub="$REALITY_PUBLIC_KEY" env_short="$REALITY_SHORT_ID"

  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
  fi

  [[ -n "$env_hy2" ]] && HY2_PASSWORD="$env_hy2"
  [[ -n "$env_sal" ]] && SALAMANDER_PASSWORD="$env_sal"
  [[ -n "$env_uuid" ]] && VLESS_UUID="$env_uuid"
  [[ -n "$env_priv" ]] && REALITY_PRIVATE_KEY="$env_priv"
  [[ -n "$env_pub" ]] && REALITY_PUBLIC_KEY="$env_pub"
  [[ -n "$env_short" ]] && REALITY_SHORT_ID="$env_short"

  [[ -n "$HY2_PASSWORD" ]] || HY2_PASSWORD="$(gen_random_b64 24)"
  [[ -n "$SALAMANDER_PASSWORD" ]] || SALAMANDER_PASSWORD="$(gen_random_b64 24)"
  [[ -n "$VLESS_UUID" ]] || VLESS_UUID="$(generate_uuid)"
  [[ -n "$REALITY_SHORT_ID" ]] || REALITY_SHORT_ID="$(gen_random_hex 8)"

  if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
    local keypair
    keypair="$(generate_reality_keypair)"
    REALITY_PRIVATE_KEY="$(
      awk -F': *' '/PrivateKey/ { print $2; exit }' <<<"$keypair"
    )"
    REALITY_PUBLIC_KEY="$(
      awk -F': *' '/PublicKey/ { print $2; exit }' <<<"$keypair"
    )"
  fi
  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] ||
    die "failed to obtain a REALITY key pair"
}

# Persists exact shell-escaped secret values so a later "source" reproduces
# them byte for byte. Written in the transaction staging area first.
render_state_file() {
  local out="$1"
  {
    printf '%s\n' "$MANAGED_MARKER"
    printf 'HY2_PASSWORD=%q\n' "$HY2_PASSWORD"
    printf 'SALAMANDER_PASSWORD=%q\n' "$SALAMANDER_PASSWORD"
    printf 'VLESS_UUID=%q\n' "$VLESS_UUID"
    printf 'REALITY_PRIVATE_KEY=%q\n' "$REALITY_PRIVATE_KEY"
    printf 'REALITY_PUBLIC_KEY=%q\n' "$REALITY_PUBLIC_KEY"
    printf 'REALITY_SHORT_ID=%q\n' "$REALITY_SHORT_ID"
  } >"$out"
  chmod 0600 "$out"
}

render_client_file() {
  local out="$1"
  {
    printf '%s\n' "$MANAGED_MARKER"
    printf '# Copy these values into client/immortalwrt.env.\n'
    printf 'SERVER_IPV4=%q\n' "$SERVER_IPV4"
    printf 'HY2_PORT=%q\n' "$HY2_PORT"
    printf 'HY2_PORTS=%q\n' "$HY2_PORTS"
    printf 'HY2_PASSWORD=%q\n' "$HY2_PASSWORD"
    printf 'SALAMANDER_PASSWORD=%q\n' "$SALAMANDER_PASSWORD"
    printf 'HY2_CERT_MODE=%q\n' "$HY2_CERT_MODE"
    printf 'HY2_SNI=%q\n' "${HY2_SNI:-$SERVER_IPV4}"
    printf 'HY2_PIN_SHA256=%q\n' "$HY2_PIN_SHA256"
    # Full server certificate (base64-encoded PEM) so the client can trust the
    # self-signed identity directly. Empty for letsencrypt (public CA) mode.
    printf 'HY2_CERT_PEM_B64=%q\n' "$HY2_CERT_PEM_B64"
    printf 'REALITY_PORT=%q\n' "$REALITY_PORT"
    printf 'VLESS_UUID=%q\n' "$VLESS_UUID"
    printf 'REALITY_PUBLIC_KEY=%q\n' "$REALITY_PUBLIC_KEY"
    printf 'REALITY_SHORT_ID=%q\n' "$REALITY_SHORT_ID"
    printf 'REALITY_SERVER_NAME=%q\n' "$REALITY_SERVER_NAME"
  } >"$out"
  chmod 0600 "$out"
}

# ==================== Certificate handling ====================

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

certificate_matches_identity() {
  local cert="$1" identity="$2" result rc=0
  if valid_ipv4 "$identity"; then
    result="$(openssl x509 -in "$cert" -noout -checkip "$identity" 2>/dev/null)" || rc=$?
  else
    result="$(openssl x509 -in "$cert" -noout -checkhost "$identity" 2>/dev/null)" || rc=$?
  fi
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

compute_cert_pin() {
  local cert="$1"
  openssl x509 -in "$cert" -pubkey -noout |
    openssl pkey -pubin -outform DER |
    openssl dgst -sha256 -binary |
    openssl enc -base64
}

generate_self_signed_certificate() {
  install -d -m 0700 "$(dirname "$SELF_SIGNED_CERT")"
  (
    trap - ERR
    temp_cert="$(mktemp "$(dirname "$SELF_SIGNED_CERT")/.cert.XXXXXX")"
    temp_key=""
    trap 'rm -f -- "$temp_cert" ${temp_key:+"$temp_key"}' EXIT
    temp_key="$(mktemp "$(dirname "$SELF_SIGNED_KEY")/.key.XXXXXX")"
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
      -subj "/CN=${SERVER_IPV4}" \
      -addext "subjectAltName=IP:${SERVER_IPV4}" \
      -keyout "$temp_key" -out "$temp_cert"
    chmod 0600 "$temp_key"
    chmod 0644 "$temp_cert"
    validate_certificate_pair "$temp_cert" "$temp_key"
    certificate_matches_identity "$temp_cert" "$SERVER_IPV4" ||
      die "generated certificate SAN does not match SERVER_IPV4"
    install -m 0600 "$temp_key" "$SELF_SIGNED_KEY"
    install -m 0644 "$temp_cert" "$SELF_SIGNED_CERT"
  )
}

prepare_selfsigned_certificate() {
  if [[ -f "$SELF_SIGNED_CERT" && -f "$SELF_SIGNED_KEY" ]]; then
    validate_certificate_pair "$SELF_SIGNED_CERT" "$SELF_SIGNED_KEY"
    certificate_matches_identity "$SELF_SIGNED_CERT" "$SERVER_IPV4" ||
      die "existing self-signed certificate SAN does not match SERVER_IPV4"
  elif [[ -f "$SELF_SIGNED_CERT" || -f "$SELF_SIGNED_KEY" ]]; then
    die "only one of self-signed cert/key exists; refusing to overwrite"
  else
    generate_self_signed_certificate
  fi
  SERVER_CERT_FILE="$SELF_SIGNED_CERT"
  SERVER_KEY_FILE="$SELF_SIGNED_KEY"
  HY2_PIN_SHA256="$(compute_cert_pin "$SERVER_CERT_FILE")"
  HY2_CERT_PEM_B64="$(base64 -w0 <"$SERVER_CERT_FILE")"
}

prepare_letsencrypt_certificate() {
  [[ -f "$HY2_CERT_FILE" && -f "$HY2_KEY_FILE" ]] ||
    die "letsencrypt certificate or key file is missing"
  validate_certificate_pair "$HY2_CERT_FILE" "$HY2_KEY_FILE"
  local identity="${HY2_SNI:-$SERVER_IPV4}"
  certificate_matches_identity "$HY2_CERT_FILE" "$identity" ||
    die "letsencrypt certificate does not match identity: $identity"
  SERVER_CERT_FILE="$HY2_CERT_FILE"
  SERVER_KEY_FILE="$HY2_KEY_FILE"
  HY2_PIN_SHA256=""
  HY2_CERT_PEM_B64=""
}

prepare_certificate() {
  case "$HY2_CERT_MODE" in
    selfsigned) prepare_selfsigned_certificate ;;
    letsencrypt) prepare_letsencrypt_certificate ;;
    *) die "unsupported HY2_CERT_MODE: ${HY2_CERT_MODE}" ;;
  esac
}

# ==================== Rendering ====================

# Emits the strict-JSON body of the sing-box configuration. jq guarantees
# valid JSON and proper escaping of any secret material. Optional up/down
# bandwidth fields are only present when configured.
_singbox_config_json() {
  jq -n \
    --argjson hy2_port "$HY2_PORT" \
    --arg hy2_pw "$HY2_PASSWORD" \
    --arg sal_pw "$SALAMANDER_PASSWORD" \
    --arg cert_path "$SERVER_CERT_FILE" \
    --arg key_path "$SERVER_KEY_FILE" \
    --argjson reality_port "$REALITY_PORT" \
    --arg uuid "$VLESS_UUID" \
    --arg sni "$REALITY_SERVER_NAME" \
    --arg handshake "$REALITY_TARGET" \
    --arg rpriv "$REALITY_PRIVATE_KEY" \
    --arg rshort "$REALITY_SHORT_ID" \
    --arg up "$HY2_UP_MBPS" \
    --arg down "$HY2_DOWN_MBPS" \
    '{
      log: { level: "warn" },
      inbounds: [
        (
          {
            type: "hysteria2",
            tag: "hy2-in",
            listen: "0.0.0.0",
            listen_port: $hy2_port,
            users: [ { password: $hy2_pw } ],
            obfs: { type: "salamander", password: $sal_pw },
            tls: {
              enabled: true,
              alpn: [ "h3" ],
              certificate_path: $cert_path,
              key_path: $key_path
            }
          }
          + (if $up  != "" then { up_mbps:  ($up  | tonumber) } else {} end)
          + (if $down != "" then { down_mbps:($down | tonumber) } else {} end)
        ),
        {
          type: "vless",
          tag: "reality-in",
          listen: "0.0.0.0",
          listen_port: $reality_port,
          users: [ { uuid: $uuid, flow: "xtls-rprx-vision" } ],
          tls: {
            enabled: true,
            server_name: $sni,
            reality: {
              enabled: true,
              handshake: { server: $handshake, server_port: 443 },
              private_key: $rpriv,
              short_id: [ $rshort ]
            }
          }
        }
      ],
      outbounds: [ { type: "direct", tag: "direct-out" } ],
      route: { final: "direct-out" }
    }'
}

render_singbox_config() {
  local out="$1"
  {
    printf '%s\n' "$MANAGED_MARKER_JSON"
    _singbox_config_json
  } >"$out"
  chmod 0600 "$out"
}

render_systemd_unit() {
  local out="$1" bin
  bin="$(command -v sing-box || echo /usr/local/bin/sing-box)"
  install -d -m 0755 "$(dirname "$out")"
  cat >"$out" <<EOF
$MANAGED_MARKER
[Unit]
Description=sing-box dual-protocol proxy (vpn-node-maintenance)
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${bin} run -c ${SERVICE_CONFIG_PATH}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/etc/sing-box
RuntimeDirectory=sing-box
StateDirectory=sing-box
WorkingDirectory=/var/lib/sing-box

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$out"
}

# Renders the nftables UDP DNAT include used for Hysteria2 port hopping. The
# sentinel chain marks the table as ours so ownership can be proven before any
# later delete/apply. Only rendered when HY2_PORTS is configured.
render_nft_include() {
  local out="$1"
  [[ -n "$HY2_PORTS_RANGE" ]] ||
    die "render_nft_include called without a configured HY2_PORTS range"
  install -d -m 0755 "$(dirname "$out")"
  cat >"$out" <<EOF
$MANAGED_MARKER
table $NFT_FAMILY $NFT_TABLE {
  chain $NFT_SENTINEL {
  }

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    udp dport ${HY2_PORTS_RANGE} redirect to :${HY2_PORT}
  }
}
EOF
  chmod 0644 "$out"
}

# ==================== Validation of staged artifacts ====================

# Thin wrappers around the real validators so tests can force a failure by
# redefining the function while production calls the real binary.
test_singbox_config() { sing-box check -c "$1"; }
verify_systemd_unit() { systemd-analyze verify "$1"; }
validate_nft_include() { nft --check -f "$1"; }

# ==================== Ownership and collision guards ====================

is_managed_file() {
  local path="$1"
  [[ -f "$path" ]] && grep -qF "$MANAGED_MARKER_TEXT" "$path"
}

guard_managed_or_absent() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  is_managed_file "$path" ||
    die "refusing to overwrite unmanaged file: $path"
}

nft_table_exists() {
  nft list table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1
}

nft_sentinel_present() {
  nft list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_SENTINEL" >/dev/null 2>&1
}

ensure_nft_ownership() {
  if nft_table_exists; then
    nft_sentinel_present ||
      die "nftables table ${NFT_TABLE} exists but is not managed by vpn-node-maintenance; refusing to modify"
  fi
}

check_managed_targets() {
  guard_managed_or_absent "$SINGBOX_CONFIG"
  guard_managed_or_absent "$SYSTEMD_UNIT"
  if [[ -n "$HY2_PORTS_RANGE" ]]; then
    guard_managed_or_absent "$NFT_INCLUDE"
    ensure_nft_ownership
  fi
}

# ==================== Port availability ====================

_listener_free_or_ours() {
  local listeners="$1" label="$2" line procs other
  [[ -z "$listeners" ]] && return 0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    procs="$(grep -oP '"\K[^"]+(?=")' <<<"$line" || true)"
    [[ -n "$procs" ]] || die "cannot determine process owning ${label}"
    other="$(printf '%s\n' "$procs" | grep -v '^sing-box$' || true)"
    [[ -z "$other" ]] || die "${label} is held by another process: $other"
  done <<<"$listeners"
}

check_ports_available() {
  local udp tcp
  udp="$( { ss -H -lunp "sport = :${HY2_PORT}"; } 2>/dev/null || true )"
  tcp="$( { ss -H -ltnp "sport = :${REALITY_PORT}"; } 2>/dev/null || true )"
  _listener_free_or_ours "$udp" "UDP port ${HY2_PORT}"
  _listener_free_or_ours "$tcp" "TCP port ${REALITY_PORT}"
}

# ==================== Dependencies and swap ====================

ensure_dependencies() {
  local cmd missing=()
  for cmd in sing-box nft ss openssl jq systemctl systemd-analyze uuidgen; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) ||
    die "required command(s) not found: ${missing[*]}"
}

# Creates a swap file only when explicitly requested and no swap is already
# active, never overwriting existing swap. Wrapped so tests can mock the
# underlying tools; skipped entirely when CREATE_SWAP_MB is 0.
maybe_create_swap() {
  ((10#$CREATE_SWAP_MB > 0)) || return 0
  if [[ -n "$(swapon --show --noheadings 2>/dev/null || true)" ]]; then
    log "swap already active; not creating a new swap file"
    return 0
  fi
  local swapfile="${ROOT_PREFIX}/swapfile"
  [[ -e "$swapfile" ]] && { log "swap file exists; leaving untouched"; return 0; }
  fallocate -l "${CREATE_SWAP_MB}M" "$swapfile" ||
    dd if=/dev/zero of="$swapfile" bs=1M count="$CREATE_SWAP_MB"
  chmod 0600 "$swapfile"
  mkswap "$swapfile"
  swapon "$swapfile"
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
    cp -a -- "$path" "${TXN_DIR}/backup/${slug}"
  else
    SNAPSHOT_EXISTED["$path"]=0
  fi
}

begin_transaction() {
  install -d -m 0700 "$TRANSACTION_DIR_ROOT"
  TXN_DIR="$(mktemp -d "${TRANSACTION_DIR_ROOT}/txn.XXXXXX")"
  install -d -m 0700 "${TXN_DIR}/backup" "${TXN_DIR}/stage"
  STAGED_CONFIG="${TXN_DIR}/stage/config.json"
  STAGED_UNIT="${TXN_DIR}/stage/sing-box.service"
  STAGED_STATE="${TXN_DIR}/stage/sing-box-state.env"
  STAGED_CLIENT="${TXN_DIR}/stage/sing-box-client.env"
  STAGED_NFT="${TXN_DIR}/stage/hy2-hopping.nft"
  STAGED_CERT="${TXN_DIR}/stage/hy2-selfsigned-cert.pem"
  STAGED_KEY="${TXN_DIR}/stage/hy2-selfsigned-key.pem"
  SNAPSHOT_TARGETS=()
  SNAPSHOT_EXISTED=()
  SNAPSHOT_MODE=()
  if systemctl is-active --quiet sing-box.service; then
    SERVICE_WAS_ACTIVE=1
  else
    SERVICE_WAS_ACTIVE=0
  fi
  if systemctl is-enabled --quiet sing-box.service 2>/dev/null; then
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

cleanup_owned_nft_table() {
  if nft_sentinel_present; then
    nft delete table "$NFT_FAMILY" "$NFT_TABLE" || return 1
  fi
  return 0
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
    cleanup_owned_nft_table ||
      log "WARNING: could not fully clean sing-box nftables state during rollback"
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
      systemctl enable sing-box.service
    else
      systemctl disable sing-box.service
    fi
    if ((SERVICE_WAS_ACTIVE)); then
      systemctl restart sing-box.service
    else
      systemctl stop sing-box.service
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

stage_managed_files() {
  render_singbox_config "$STAGED_CONFIG"
  render_systemd_unit "$STAGED_UNIT"
  render_state_file "$STAGED_STATE"
  render_client_file "$STAGED_CLIENT"
  if [[ "$HY2_CERT_MODE" == "selfsigned" ]]; then
    install -m 0600 "$SERVER_KEY_FILE" "$STAGED_KEY"
    install -m 0644 "$SERVER_CERT_FILE" "$STAGED_CERT"
  fi
  if [[ -n "$HY2_PORTS_RANGE" ]]; then
    render_nft_include "$STAGED_NFT"
  fi
}

validate_staged_files() {
  test_singbox_config "$STAGED_CONFIG" ||
    die "staged sing-box configuration failed validation"
  verify_systemd_unit "$STAGED_UNIT" ||
    die "staged systemd unit failed verification"
  if [[ -n "$HY2_PORTS_RANGE" ]]; then
    validate_nft_include "$STAGED_NFT" ||
      die "staged nftables include failed validation"
  fi
}

_atomic_install_file() {
  local mode="$1" src="$2" dest="$3" dir tmp
  dir="$(dirname "$dest")"
  [[ -d "$dir" ]] || install -d -m 0755 "$dir"
  tmp="$(mktemp "${dir}/.sing-box-deploy.XXXXXX")"
  if ! install -m "$mode" "$src" "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    die "failed to atomically install $dest"
  fi
}

install_staged_files() {
  install -d -m 0755 "$(dirname "$SINGBOX_CONFIG")"
  install -d -m 0700 "$(dirname "$STATE_FILE")"
  _atomic_install_file 0600 "$STAGED_CONFIG" "$SINGBOX_CONFIG"
  _atomic_install_file 0644 "$STAGED_UNIT" "$SYSTEMD_UNIT"
  _atomic_install_file 0600 "$STAGED_STATE" "$STATE_FILE"
  _atomic_install_file 0600 "$STAGED_CLIENT" "$CLIENT_FILE"
  if [[ "$HY2_CERT_MODE" == "selfsigned" ]]; then
    install -d -m 0700 "$(dirname "$SELF_SIGNED_KEY")"
    _atomic_install_file 0600 "$STAGED_KEY" "$SELF_SIGNED_KEY"
    _atomic_install_file 0644 "$STAGED_CERT" "$SELF_SIGNED_CERT"
  fi
  if [[ -n "$HY2_PORTS_RANGE" ]]; then
    _atomic_install_file 0644 "$STAGED_NFT" "$NFT_INCLUDE"
  fi
}

apply_nft_hopping() {
  [[ -n "$HY2_PORTS_RANGE" ]] || return 0
  ensure_nft_ownership
  if nft_table_exists; then
    nft delete table "$NFT_FAMILY" "$NFT_TABLE"
  fi
  nft -f "$NFT_INCLUDE"
}

# ==================== Service activation and verification ====================

activate_service() {
  systemctl daemon-reload || die "systemctl daemon-reload failed"
  systemctl enable sing-box.service || die "failed to enable sing-box.service"
  apply_nft_hopping
  systemctl restart sing-box.service || die "failed to restart sing-box.service"
}

# Fixed readiness cadence (75 x 0.2s ~= 15s). Functions, not variables, so the
# production bound cannot be reconfigured through the environment; tests
# override them after sourcing.
readiness_attempts() { printf '75'; }
readiness_interval_seconds() { printf '0.2'; }

service_is_ready() {
  systemctl is-active --quiet sing-box.service &&
    [[ -n "$(ss -H -ltn "sport = :${REALITY_PORT}")" ]] &&
    [[ -n "$(ss -H -lun "sport = :${HY2_PORT}")" ]]
}

print_readiness_diagnostics() {
  systemctl status sing-box.service --no-pager -l >&2 || true
  journalctl -u sing-box.service -n 50 --no-pager >&2 || true
}

service_status_summary() {
  local active=no tcp=no udp=no
  if systemctl is-active --quiet sing-box.service; then active=yes; fi
  if [[ -n "$(ss -H -ltn "sport = :${REALITY_PORT}")" ]]; then tcp=yes; fi
  if [[ -n "$(ss -H -lun "sport = :${HY2_PORT}")" ]]; then udp=yes; fi
  printf 'active=%s tcp=%s udp=%s' "$active" "$tcp" "$udp"
}

wait_for_service_ready() {
  local attempt attempts interval timeout
  attempts="$(readiness_attempts)"
  interval="$(readiness_interval_seconds)"
  for ((attempt=1; attempt<=attempts; attempt++)); do
    service_is_ready && return 0
    ((attempt < attempts)) && sleep "$interval"
  done
  print_readiness_diagnostics
  timeout="$(awk "BEGIN { printf \"%g\", ${attempts} * ${interval} }")"
  die "sing-box did not become ready on TCP ${REALITY_PORT} and UDP ${HY2_PORT}: ${attempts} attempts exhausted (~${timeout}s); last status: $(service_status_summary)"
}

print_install_summary() {
  printf 'sing-box endpoint: %s\n' "$SERVER_IPV4"
  printf 'Hysteria2 (Salamander): UDP %s\n' "$HY2_PORT"
  if [[ -n "$HY2_PORTS_RANGE" ]]; then
    printf 'Hysteria2 port hopping: UDP %s -> %s (nftables)\n' "$HY2_PORTS_RANGE" "$HY2_PORT"
  fi
  printf 'VLESS + REALITY + Vision: TCP %s (SNI %s)\n' "$REALITY_PORT" "$REALITY_SERVER_NAME"
  printf 'Certificate mode: %s\n' "$HY2_CERT_MODE"
  if [[ "$HY2_CERT_MODE" == "selfsigned" ]]; then
    printf 'HY2 pin-sha256: %s (client must not use insecure=true)\n' "$HY2_PIN_SHA256"
    printf 'HY2 self-signed certificate embedded in client env as HY2_CERT_PEM_B64.\n'
  fi
  printf 'Azure NSG: allow UDP %s' "$HY2_PORT"
  [[ -n "$HY2_PORTS_RANGE" ]] && printf ' and UDP %s' "$HY2_PORTS_RANGE"
  printf ' and TCP %s\n' "$REALITY_PORT"
  printf 'Client parameters written to: %s\n' "$CLIENT_FILE"
}

install_server() {
  begin_transaction
  snapshot_target "$SINGBOX_CONFIG"
  snapshot_target "$SYSTEMD_UNIT"
  snapshot_target "$STATE_FILE"
  snapshot_target "$CLIENT_FILE"
  snapshot_target "$SELF_SIGNED_CERT"
  snapshot_target "$SELF_SIGNED_KEY"
  snapshot_target "$NFT_INCLUDE"
  prepare_certificate
  stage_managed_files
  validate_staged_files
  install_staged_files
  activate_service
  wait_for_service_ready
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
  resolve_secrets
  check_managed_targets
  check_ports_available
  maybe_create_swap
  install_server
}

# Renders and validates every artifact in a throwaway directory without
# touching any live path, systemd unit, or the host firewall.
cmd_check() {
  load_config
  validate_config
  ensure_dependencies
  resolve_secrets
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp'" RETURN
  if [[ "$HY2_CERT_MODE" == "selfsigned" ]]; then
    SERVER_CERT_FILE="$tmp/cert.pem"
    SERVER_KEY_FILE="$tmp/key.pem"
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 1 \
      -subj "/CN=${SERVER_IPV4}" \
      -addext "subjectAltName=IP:${SERVER_IPV4}" \
      -keyout "$SERVER_KEY_FILE" -out "$SERVER_CERT_FILE" >/dev/null 2>&1 ||
      die "failed to render an ephemeral certificate for check"
  else
    prepare_letsencrypt_certificate
  fi
  render_singbox_config "$tmp/config.json"
  render_systemd_unit "$tmp/sing-box.service"
  test_singbox_config "$tmp/config.json"
  verify_systemd_unit "$tmp/sing-box.service"
  if [[ -n "$HY2_PORTS_RANGE" ]]; then
    render_nft_include "$tmp/hy2-hopping.nft"
    validate_nft_include "$tmp/hy2-hopping.nft"
  fi
  log "check: configuration and artifacts validated (no changes made)"
}

cmd_show_client() {
  [[ -f "$CLIENT_FILE" ]] ||
    die "client parameter file not found; run install first: $CLIENT_FILE"
  cat "$CLIENT_FILE"
}

usage() {
  printf '%s\n' \
    "Usage: sing-box-deploy.sh install      Install/reconcile the sing-box server" \
    "       sing-box-deploy.sh check        Validate config and rendered artifacts (no changes)" \
    "       sing-box-deploy.sh show-client  Print generated client parameters" \
    "       sing-box-deploy.sh help"
}

main() {
  case "${1:-help}" in
    help|-h|--help) usage ;;
    install) cmd_install ;;
    check) cmd_check ;;
    show-client) cmd_show_client ;;
    *)
      usage >&2
      die "unknown command: ${1:-}"
      ;;
  esac
}

if [[ "${SINGBOX_DEPLOY_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
