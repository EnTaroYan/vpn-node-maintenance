#!/usr/bin/env bash

set -Eeuo pipefail

if ((EUID != 0)); then
  exec sudo --preserve-env=PATH bash "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/testlib.sh"
SCRIPT_PATH="$REPO_ROOT/server/sing-box-deploy.sh"

# Fail fast: each test runs in its own subshell (run_test wraps it in "(...)"),
# so exiting on the first failed assertion prevents a later passing command
# from masking an earlier failure in the same test.
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Every test runs against a per-run temp root: the config lives there, and the
# deployer's live paths are confined under SINGBOX_DEPLOY_ROOT so nothing ever
# touches the real /etc/sing-box, /etc/vpn-node, systemd, or host firewall.
new_fixture() {
  TEST_ROOT="$(mktemp -d)"
  export TEST_ROOT
  export SINGBOX_DEPLOY_CONFIG="$TEST_ROOT/sing-box.env"
  export SINGBOX_DEPLOY_ROOT="$TEST_ROOT/root"
  install -d -m 0700 "$SINGBOX_DEPLOY_ROOT" "$TEST_ROOT/bin" "$TEST_ROOT/ctl"
}

remove_fixture() {
  rm -rf -- "$TEST_ROOT"
}

write_config() {
  install -m 0600 /dev/null "$SINGBOX_DEPLOY_CONFIG"
  printf '%s\n' "$1" >"$SINGBOX_DEPLOY_CONFIG"
  chown root:root "$SINGBOX_DEPLOY_CONFIG"
  chmod 0600 "$SINGBOX_DEPLOY_CONFIG"
}

source_deployer() {
  SINGBOX_DEPLOY_SOURCE_ONLY=1 source "$SCRIPT_PATH"
}

VALID_CONFIG='
SERVER_IPV4="104.46.217.92"
HY2_PORT="443"
HY2_CERT_MODE="selfsigned"
REALITY_PORT="443"
REALITY_TARGET="www.microsoft.com"
'

# Strips the leading JSONC "// ..." ownership marker so strict JSON parsers can
# read the rendered sing-box config.
_json_body() { grep -v '^//' "$1"; }

# ---------- system-command mocks ----------
#
# Intercepts every real system command the installer touches under
# $TEST_ROOT/bin. openssl/jq/awk/sed remain real (cert + JSON rendering need
# them); sing-box, systemd-analyze, systemctl, ss, nft, journalctl, and the
# swap tools are stubbed so no test starts a service, applies a firewall rule,
# or creates swap on the host.
_write_mocks() {
  cat >"$TEST_ROOT/bin/sing-box" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*" >> "$TEST_ROOT/sing-box-args.log"
case "$1" in
  check) [[ -f "$TEST_ROOT/ctl/singbox_check_fail" ]] && exit 1; exit 0 ;;
  generate)
    case "${2:-}" in
      reality-keypair)
        printf 'PrivateKey: PRIVKEYBASE64URLVALUE\nPublicKey: PUBKEYBASE64URLVALUE\n'
        exit 0 ;;
      uuid) printf '11111111-2222-3333-4444-555555555555\n'; exit 0 ;;
    esac ;;
esac
exit 0
EOF

  cat >"$TEST_ROOT/bin/systemd-analyze" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*" >> "$TEST_ROOT/systemd-analyze-args.log"
[[ -f "$TEST_ROOT/ctl/systemd_verify_fail" ]] && exit 1
exit 0
EOF

  cat >"$TEST_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*" >> "$TEST_ROOT/systemctl-args.log"
ctl="$TEST_ROOT/ctl"; mkdir -p "$ctl"
case "$1" in
  is-active) [[ -f "$ctl/is_active" ]] && exit 0 || exit 1 ;;
  is-enabled) [[ -f "$ctl/is_enabled" ]] && exit 0 || exit 1 ;;
  enable) touch "$ctl/is_enabled"; exit 0 ;;
  disable) rm -f "$ctl/is_enabled"; exit 0 ;;
  restart) [[ -f "$ctl/restart_fail" ]] && exit 1; touch "$ctl/is_active"; exit 0 ;;
  stop) rm -f "$ctl/is_active"; exit 0 ;;
  daemon-reload) exit 0 ;;
  status) exit 0 ;;
  *) exit 0 ;;
esac
EOF

  cat >"$TEST_ROOT/bin/ss" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*" >> "$TEST_ROOT/ss-args.log"
ctl="$TEST_ROOT/ctl"; flags="$2"
if [[ "$flags" == *p* ]]; then
  # Port-availability probe (-lunp / -ltnp).
  if [[ "$flags" == *u* && -f "$ctl/udp_busy" ]]; then cat "$ctl/udp_busy"; fi
  if [[ "$flags" == *t* && -f "$ctl/tcp_busy" ]]; then cat "$ctl/tcp_busy"; fi
  exit 0
fi
# Readiness probe (-ltn / -lun): report a listener unless suppressed.
if [[ "$flags" == *t* && -f "$ctl/no_tcp" ]]; then exit 0; fi
if [[ "$flags" == *u* && -f "$ctl/no_udp" ]]; then exit 0; fi
printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'
exit 0
EOF

  cat >"$TEST_ROOT/bin/nft" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*" >> "$TEST_ROOT/nft-args.log"
ctl="$TEST_ROOT/ctl"
case "$1" in
  --check|-f) exit 0 ;;
  list)
    case "${2:-}" in
      table) [[ -f "$ctl/nft_table" ]] && exit 0 || exit 1 ;;
      chain) [[ -f "$ctl/nft_sentinel" ]] && exit 0 || exit 1 ;;
    esac
    exit 1 ;;
  delete) rm -f "$ctl/nft_table" "$ctl/nft_sentinel"; exit 0 ;;
  *) exit 0 ;;
esac
EOF

  cat >"$TEST_ROOT/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  local m
  for m in swapon mkswap fallocate; do
    cat >"$TEST_ROOT/bin/$m" <<'EOF'
#!/usr/bin/env bash
printf '%s ARGS: %s\n' "$(basename "$0")" "$*" >> "$TEST_ROOT/swap-args.log"
exit 0
EOF
  done

  chmod +x "$TEST_ROOT/bin/"*
}

# Loads a fully valid config plus every mock and points PATH at them. Extra
# config lines can be appended via the first argument.
_orchestration_fixture() {
  local extra="${1:-}"
  write_config "${VALID_CONFIG}
${extra}"
  source_deployer
  load_config
  validate_config
  _write_mocks
  export PATH="$TEST_ROOT/bin:$PATH"
  # Fast readiness cadence so the 15s production wait never runs under the
  # suite. Seams are functions; the environment has no effect.
  readiness_attempts() { printf '2'; }
  readiness_interval_seconds() { printf '0'; }
}

# Generates a real cert/key pair with an IP SAN for the given address.
_make_ip_cert() {
  local addr="$1" cert="$2" key="$3"
  install -d -m 0700 "$(dirname "$cert")"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 \
    -subj "/CN=${addr}" -addext "subjectAltName=IP:${addr}" \
    -keyout "$key" -out "$cert" >/dev/null 2>&1
  chmod 0600 "$key"; chmod 0644 "$cert"
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
  chown nobody "$SINGBOX_DEPLOY_CONFIG"
  source_deployer
  assert_failure load_config
}

test_config_rejects_group_writable_perms() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  chmod 0644 "$SINGBOX_DEPLOY_CONFIG"
  source_deployer
  assert_failure load_config
}

test_config_rejects_symlink() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  local real="$TEST_ROOT/real.env"
  cp "$SINGBOX_DEPLOY_CONFIG" "$real"
  chown root:root "$real"; chmod 0600 "$real"
  rm -f "$SINGBOX_DEPLOY_CONFIG"
  ln -s "$real" "$SINGBOX_DEPLOY_CONFIG"
  source_deployer
  assert_failure load_config
}

# ==================== Port / field validation ====================

test_rejects_invalid_hy2_port() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
SERVER_IPV4="104.46.217.92"
HY2_PORT="70000"
REALITY_TARGET="www.microsoft.com"
'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_invalid_reality_port() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
SERVER_IPV4="104.46.217.92"
REALITY_PORT="0"
REALITY_TARGET="www.microsoft.com"
'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_missing_server_ipv4() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
REALITY_TARGET="www.microsoft.com"
'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_bad_server_ipv4() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
SERVER_IPV4="10.20.30.999"
REALITY_TARGET="www.microsoft.com"
'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_bad_cert_mode() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
SERVER_IPV4="104.46.217.92"
HY2_CERT_MODE="acme"
REALITY_TARGET="www.microsoft.com"
'
  source_deployer
  load_config
  assert_failure validate_config
}

test_rejects_reversed_hy2_ports_range() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
SERVER_IPV4="104.46.217.92"
HY2_PORTS="50000:20000"
REALITY_TARGET="www.microsoft.com"
'
  source_deployer
  load_config
  assert_failure validate_config
}

test_accepts_valid_hy2_ports_range() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
SERVER_IPV4="104.46.217.92"
HY2_PORTS="20000:50000"
REALITY_TARGET="www.microsoft.com"
'
  source_deployer
  load_config
  assert_success validate_config
  assert_eq "20000-50000" "$HY2_PORTS_RANGE" "nft range derived from HY2_PORTS"
}

# ==================== Let's Encrypt certificate mode ====================

test_letsencrypt_requires_cert_fields() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
SERVER_IPV4="104.46.217.92"
HY2_CERT_MODE="letsencrypt"
REALITY_TARGET="www.microsoft.com"
'
  source_deployer
  load_config
  assert_failure validate_config
}

test_letsencrypt_missing_cert_fails() {
  new_fixture
  trap remove_fixture EXIT
  write_config "
SERVER_IPV4=\"104.46.217.92\"
HY2_CERT_MODE=\"letsencrypt\"
HY2_CERT_FILE=\"$TEST_ROOT/le/fullchain.pem\"
HY2_KEY_FILE=\"$TEST_ROOT/le/privkey.pem\"
REALITY_TARGET=\"www.microsoft.com\"
"
  source_deployer
  load_config
  validate_config
  assert_failure prepare_letsencrypt_certificate
}

test_letsencrypt_matching_cert_passes() {
  new_fixture
  trap remove_fixture EXIT
  _make_ip_cert "104.46.217.92" "$TEST_ROOT/le/fullchain.pem" "$TEST_ROOT/le/privkey.pem"
  write_config "
SERVER_IPV4=\"104.46.217.92\"
HY2_CERT_MODE=\"letsencrypt\"
HY2_CERT_FILE=\"$TEST_ROOT/le/fullchain.pem\"
HY2_KEY_FILE=\"$TEST_ROOT/le/privkey.pem\"
REALITY_TARGET=\"www.microsoft.com\"
"
  source_deployer
  load_config
  validate_config
  assert_success prepare_letsencrypt_certificate
  assert_eq "$TEST_ROOT/le/fullchain.pem" "$SERVER_CERT_FILE" "LE cert path"
}

test_letsencrypt_wrong_identity_fails() {
  new_fixture
  trap remove_fixture EXIT
  _make_ip_cert "203.0.113.7" "$TEST_ROOT/le/fullchain.pem" "$TEST_ROOT/le/privkey.pem"
  write_config "
SERVER_IPV4=\"104.46.217.92\"
HY2_CERT_MODE=\"letsencrypt\"
HY2_CERT_FILE=\"$TEST_ROOT/le/fullchain.pem\"
HY2_KEY_FILE=\"$TEST_ROOT/le/privkey.pem\"
REALITY_TARGET=\"www.microsoft.com\"
"
  source_deployer
  load_config
  validate_config
  assert_failure prepare_letsencrypt_certificate
}

# ==================== Self-signed certificate mode ====================

test_selfsigned_generates_ip_san_and_pin() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  source_deployer
  load_config
  validate_config
  prepare_selfsigned_certificate
  [[ -f "$SELF_SIGNED_CERT" ]] || fail "self-signed cert not generated"
  openssl x509 -in "$SELF_SIGNED_CERT" -noout -text |
    grep -q 'IP Address:104.46.217.92' ||
    fail "self-signed certificate is missing the IP SAN"
  [[ -n "$HY2_PIN_SHA256" ]] || fail "self-signed pin was not computed"
  [[ -n "$HY2_CERT_PEM_B64" ]] ||
    fail "self-signed certificate was not base64-encoded for the client"
  printf '%s' "$HY2_CERT_PEM_B64" | base64 -d |
    openssl x509 -noout >/dev/null 2>&1 ||
    fail "HY2_CERT_PEM_B64 must decode to a valid certificate"
}

test_selfsigned_reuses_existing_pair() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  source_deployer
  load_config
  validate_config
  prepare_selfsigned_certificate
  local first_sum
  first_sum="$(sha256sum "$SELF_SIGNED_CERT" | awk '{print $1}')"
  prepare_selfsigned_certificate
  local second_sum
  second_sum="$(sha256sum "$SELF_SIGNED_CERT" | awk '{print $1}')"
  assert_eq "$first_sum" "$second_sum" "existing self-signed cert must be reused, not regenerated"
}

test_selfsigned_refuses_half_pair() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  source_deployer
  load_config
  validate_config
  install -d -m 0700 "$(dirname "$SELF_SIGNED_CERT")"
  : >"$SELF_SIGNED_CERT"
  assert_failure prepare_selfsigned_certificate
}

test_certificate_pair_mismatch_rejected() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  source_deployer
  _make_ip_cert "104.46.217.92" "$TEST_ROOT/a.crt" "$TEST_ROOT/a.key"
  _make_ip_cert "104.46.217.92" "$TEST_ROOT/b.crt" "$TEST_ROOT/b.key"
  assert_failure validate_certificate_pair "$TEST_ROOT/a.crt" "$TEST_ROOT/b.key"
}

# ==================== Secret generation and persistence ====================

test_secret_persistence_shell_escaped() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  source_deployer
  load_config
  install -d -m 0700 "$(dirname "$STATE_FILE")"
  HY2_PASSWORD='p@ss word$with/special+='
  SALAMANDER_PASSWORD='sal msander'
  VLESS_UUID='11111111-2222-3333-4444-555555555555'
  REALITY_PRIVATE_KEY='PRIVKEY'
  REALITY_PUBLIC_KEY='PUBKEY'
  REALITY_SHORT_ID='deadbeef'
  render_state_file "$STATE_FILE"
  assert_eq "600" "$(stat -c '%a' "$STATE_FILE")" "state file must be mode 0600"
  local expected="$HY2_PASSWORD"
  unset HY2_PASSWORD SALAMANDER_PASSWORD VLESS_UUID
  # shellcheck source=/dev/null
  source "$STATE_FILE"
  assert_eq "$expected" "$HY2_PASSWORD" "shell-escaped secret must round-trip exactly"
}

test_secret_reuse_on_rerun() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  _write_mocks
  export PATH="$TEST_ROOT/bin:$PATH"
  source_deployer
  load_config
  install -d -m 0700 "$(dirname "$STATE_FILE")"
  cat >"$STATE_FILE" <<'EOF'
# Managed by vpn-node-maintenance: sing-box-deploy.sh
HY2_PASSWORD=persisted-hy2
SALAMANDER_PASSWORD=persisted-sal
VLESS_UUID=persisted-uuid
REALITY_PRIVATE_KEY=persisted-priv
REALITY_PUBLIC_KEY=persisted-pub
REALITY_SHORT_ID=persisted-sid
EOF
  chmod 0600 "$STATE_FILE"
  resolve_secrets
  assert_eq "persisted-hy2" "$HY2_PASSWORD" "persisted HY2 password reused"
  assert_eq "persisted-priv" "$REALITY_PRIVATE_KEY" "persisted reality key reused"
  assert_eq "persisted-sid" "$REALITY_SHORT_ID" "persisted short id reused"
}

test_env_secret_overrides_state() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  _write_mocks
  export PATH="$TEST_ROOT/bin:$PATH"
  source_deployer
  load_config
  install -d -m 0700 "$(dirname "$STATE_FILE")"
  cat >"$STATE_FILE" <<'EOF'
# Managed by vpn-node-maintenance: sing-box-deploy.sh
HY2_PASSWORD=persisted-hy2
SALAMANDER_PASSWORD=persisted-sal
VLESS_UUID=persisted-uuid
REALITY_PRIVATE_KEY=persisted-priv
REALITY_PUBLIC_KEY=persisted-pub
REALITY_SHORT_ID=persisted-sid
EOF
  chmod 0600 "$STATE_FILE"
  HY2_PASSWORD="env-override"
  resolve_secrets
  assert_eq "env-override" "$HY2_PASSWORD" "env secret must override persisted state"
}

test_missing_secrets_are_generated() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  _write_mocks
  export PATH="$TEST_ROOT/bin:$PATH"
  source_deployer
  load_config
  resolve_secrets
  [[ -n "$HY2_PASSWORD" ]] || fail "HY2 password not generated"
  [[ -n "$SALAMANDER_PASSWORD" ]] || fail "Salamander password not generated"
  [[ -n "$VLESS_UUID" ]] || fail "VLESS UUID not generated"
  assert_eq "PRIVKEYBASE64URLVALUE" "$REALITY_PRIVATE_KEY" "reality private key parsed from generator"
  assert_eq "PUBKEYBASE64URLVALUE" "$REALITY_PUBLIC_KEY" "reality public key parsed from generator"
  [[ -n "$REALITY_SHORT_ID" ]] || fail "reality short id not generated"
}

# ==================== Rendered sing-box JSON shape ====================

_render_shape_config() {
  HY2_PASSWORD='hy2-secret'
  SALAMANDER_PASSWORD='sal-secret'
  VLESS_UUID='uuid-abc'
  REALITY_PRIVATE_KEY='priv-key'
  REALITY_PUBLIC_KEY='pub-key'
  REALITY_SHORT_ID='beef'
  SERVER_CERT_FILE="/etc/sing-box/tls/hy2-selfsigned-cert.pem"
  SERVER_KEY_FILE="/etc/sing-box/tls/hy2-selfsigned-key.pem"
  render_singbox_config "$1"
}

test_config_json_shape() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  source_deployer
  load_config
  validate_config
  local out="$TEST_ROOT/config.json"
  _render_shape_config "$out"
  head -1 "$out" | grep -qF "Managed by vpn-node-maintenance" ||
    fail "config.json must carry the managed marker comment"
  local body; body="$(_json_body "$out")"
  assert_eq "warn" "$(jq -r '.log.level' <<<"$body")" "log level"
  assert_eq "hysteria2" "$(jq -r '.inbounds[0].type' <<<"$body")" "hy2 inbound type"
  assert_eq "443" "$(jq -r '.inbounds[0].listen_port' <<<"$body")" "hy2 listen port"
  assert_eq "hy2-secret" "$(jq -r '.inbounds[0].users[0].password' <<<"$body")" "hy2 password"
  assert_eq "salamander" "$(jq -r '.inbounds[0].obfs.type' <<<"$body")" "obfs type"
  assert_eq "sal-secret" "$(jq -r '.inbounds[0].obfs.password' <<<"$body")" "obfs password"
  assert_eq "/etc/sing-box/tls/hy2-selfsigned-cert.pem" \
    "$(jq -r '.inbounds[0].tls.certificate_path' <<<"$body")" "hy2 cert path"
  assert_eq "vless" "$(jq -r '.inbounds[1].type' <<<"$body")" "reality inbound type"
  assert_eq "uuid-abc" "$(jq -r '.inbounds[1].users[0].uuid' <<<"$body")" "vless uuid"
  assert_eq "xtls-rprx-vision" "$(jq -r '.inbounds[1].users[0].flow' <<<"$body")" "vless flow"
  assert_eq "true" "$(jq -r '.inbounds[1].tls.reality.enabled' <<<"$body")" "reality enabled"
  assert_eq "www.microsoft.com" "$(jq -r '.inbounds[1].tls.reality.handshake.server' <<<"$body")" "reality handshake"
  assert_eq "priv-key" "$(jq -r '.inbounds[1].tls.reality.private_key' <<<"$body")" "reality private key"
  assert_eq "beef" "$(jq -r '.inbounds[1].tls.reality.short_id[0]' <<<"$body")" "reality short id"
  assert_eq "direct-out" "$(jq -r '.outbounds[0].tag' <<<"$body")" "direct outbound tag"
  assert_eq "direct-out" "$(jq -r '.route.final' <<<"$body")" "route final"
}

test_config_json_omits_bandwidth_when_unset() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  source_deployer
  load_config
  validate_config
  local out="$TEST_ROOT/config.json"
  _render_shape_config "$out"
  local body; body="$(_json_body "$out")"
  assert_eq "null" "$(jq -r '.inbounds[0].up_mbps' <<<"$body")" "up_mbps omitted when unset"
  assert_eq "null" "$(jq -r '.inbounds[0].down_mbps' <<<"$body")" "down_mbps omitted when unset"
}

test_config_json_includes_bandwidth_when_set() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
SERVER_IPV4="104.46.217.92"
REALITY_TARGET="www.microsoft.com"
HY2_UP_MBPS="100"
HY2_DOWN_MBPS="200"
'
  source_deployer
  load_config
  validate_config
  local out="$TEST_ROOT/config.json"
  _render_shape_config "$out"
  local body; body="$(_json_body "$out")"
  assert_eq "100" "$(jq -r '.inbounds[0].up_mbps' <<<"$body")" "up_mbps present"
  assert_eq "200" "$(jq -r '.inbounds[0].down_mbps' <<<"$body")" "down_mbps present"
}

# ==================== systemd unit ====================

test_systemd_unit_shape() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  _write_mocks
  export PATH="$TEST_ROOT/bin:$PATH"
  source_deployer
  load_config
  validate_config
  local out="$TEST_ROOT/sing-box.service"
  render_systemd_unit "$out"
  grep -qF "Managed by vpn-node-maintenance" "$out" || fail "unit missing managed marker"
  grep -qE '^ExecStart=.*sing-box run -c /etc/sing-box/config.json$' "$out" ||
    fail "unit ExecStart is wrong"
  grep -qx 'Type=simple' "$out" || fail "unit must be Type=simple"
  grep -qx 'Restart=on-failure' "$out" || fail "unit must restart on failure"
  grep -qx 'WantedBy=multi-user.target' "$out" || fail "unit missing install target"
}

# ==================== Optional HY2 port hopping (nftables) ====================

test_hopping_include_rendered_when_ports_set() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
SERVER_IPV4="104.46.217.92"
HY2_PORT="443"
HY2_PORTS="20000:50000"
REALITY_TARGET="www.microsoft.com"
'
  source_deployer
  load_config
  validate_config
  local out="$TEST_ROOT/hop.nft"
  render_nft_include "$out"
  grep -qF "Managed by vpn-node-maintenance" "$out" || fail "nft include missing marker"
  grep -q '_managed_by_vpn_node_maintenance' "$out" || fail "nft include missing sentinel chain"
  grep -qF 'udp dport 20000-50000 redirect to :443' "$out" ||
    fail "nft include missing the DNAT range redirect"
}

test_hopping_absent_when_ports_empty() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture
  resolve_secrets
  ( install_server ) </dev/null >/dev/null 2>&1 || fail "install_server failed"
  [[ ! -e "$NFT_INCLUDE" ]] || fail "nft include must not exist when HY2_PORTS is empty"
  [[ ! -f "$TEST_ROOT/nft-args.log" ]] ||
    ! grep -q '^ARGS: -f' "$TEST_ROOT/nft-args.log" ||
    fail "nft must not be applied when HY2_PORTS is empty"
}

test_hopping_refuses_unowned_table() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture 'HY2_PORTS="20000:50000"'
  # A table exists but carries no sentinel chain: it is not ours.
  touch "$TEST_ROOT/ctl/nft_table"
  assert_failure ensure_nft_ownership
}

test_hopping_allows_owned_table() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture 'HY2_PORTS="20000:50000"'
  touch "$TEST_ROOT/ctl/nft_table" "$TEST_ROOT/ctl/nft_sentinel"
  assert_success ensure_nft_ownership
}

test_hopping_full_install_applies_nft() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture 'HY2_PORTS="20000:50000"'
  resolve_secrets
  ( install_server ) </dev/null >/dev/null 2>&1 || fail "install_server failed"
  [[ -f "$NFT_INCLUDE" ]] || fail "nft include must be installed when HY2_PORTS is set"
  grep -q '^ARGS: -f ' "$TEST_ROOT/nft-args.log" ||
    fail "nft -f must apply the hopping include during install"
}

test_unit_reapplies_nft_before_start_when_hopping() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
SERVER_IPV4="104.46.217.92"
HY2_PORT="443"
HY2_PORTS="20000:50000"
REALITY_TARGET="www.microsoft.com"
'
  _write_mocks
  export PATH="$TEST_ROOT/bin:$PATH"
  source_deployer
  load_config
  validate_config
  local out="$TEST_ROOT/sing-box.service"
  render_systemd_unit "$out"
  # Hopping must be re-applied at boot via a privileged ('+') ExecStartPre that
  # loads the real host include, so port hopping survives reboots.
  grep -qE '^ExecStartPre=\+.* -f /etc/sing-box/hy2-hopping\.nft$' "$out" ||
    fail "unit must re-apply the hopping include before start"
  # ExecStartPre must precede ExecStart so the DNAT exists before sing-box binds.
  local pre start
  pre="$(grep -n '^ExecStartPre=' "$out" | head -n1 | cut -d: -f1)"
  start="$(grep -n '^ExecStart=' "$out" | head -n1 | cut -d: -f1)"
  [[ -n "$pre" && -n "$start" && "$pre" -lt "$start" ]] ||
    fail "ExecStartPre must run before ExecStart"
}

test_unit_no_nft_dependency_when_ports_empty() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  _write_mocks
  export PATH="$TEST_ROOT/bin:$PATH"
  source_deployer
  load_config
  validate_config
  local out="$TEST_ROOT/sing-box.service"
  render_systemd_unit "$out"
  # With no hopping there must be no ExecStartPre and no reference to the include
  # file, so the unit never depends on a file that is never installed.
  ! grep -q '^ExecStartPre=' "$out" ||
    fail "unit must not add an ExecStartPre when HY2_PORTS is empty"
  ! grep -qF 'hy2-hopping.nft' "$out" ||
    fail "unit must not reference the hopping include when HY2_PORTS is empty"
}

test_unit_drops_cap_net_admin() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  _write_mocks
  export PATH="$TEST_ROOT/bin:$PATH"
  source_deployer
  load_config
  validate_config
  local out="$TEST_ROOT/sing-box.service"
  render_systemd_unit "$out"
  # sing-box is an inbound proxy (no TUN); the privileged ExecStartPre owns the
  # nftables work, so the service itself keeps only CAP_NET_BIND_SERVICE.
  grep -qx 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$out" ||
    fail "AmbientCapabilities must be exactly CAP_NET_BIND_SERVICE"
  grep -qx 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' "$out" ||
    fail "CapabilityBoundingSet must be exactly CAP_NET_BIND_SERVICE"
  ! grep -q 'CAP_NET_ADMIN' "$out" ||
    fail "the service must not grant the unused CAP_NET_ADMIN"
}

test_nft_include_idempotent_cleanup() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
SERVER_IPV4="104.46.217.92"
HY2_PORT="443"
HY2_PORTS="20000:50000"
REALITY_TARGET="www.microsoft.com"
'
  source_deployer
  load_config
  validate_config
  local out="$TEST_ROOT/hop.nft"
  render_nft_include "$out"
  # The include ensures then deletes the table before recreating it, so a
  # repeated ExecStartPre re-apply cleans prior state instead of erroring.
  grep -qxF "add table ip vpn_node_singbox" "$out" ||
    fail "include must ensure the table exists before deleting it"
  grep -qxF "delete table ip vpn_node_singbox" "$out" ||
    fail "include must delete the table before recreating it"
  local del recreate
  del="$(grep -n '^delete table ' "$out" | head -n1 | cut -d: -f1)"
  recreate="$(grep -n '^table ip vpn_node_singbox {' "$out" | head -n1 | cut -d: -f1)"
  [[ -n "$del" && -n "$recreate" && "$del" -lt "$recreate" ]] ||
    fail "the delete must precede the table recreation"
}

# ==================== Collision refusal ====================

test_refuses_unmanaged_config() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture
  install -d -m 0755 "$(dirname "$SINGBOX_CONFIG")"
  printf '{"hand":"written"}\n' >"$SINGBOX_CONFIG"
  assert_failure check_managed_targets
}

test_refuses_unmanaged_unit() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture
  install -d -m 0755 "$(dirname "$SYSTEMD_UNIT")"
  printf '[Service]\nExecStart=/bin/true\n' >"$SYSTEMD_UNIT"
  assert_failure check_managed_targets
}

test_allows_managed_targets() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture
  install -d -m 0755 "$(dirname "$SINGBOX_CONFIG")" "$(dirname "$SYSTEMD_UNIT")"
  printf '// Managed by vpn-node-maintenance: sing-box-deploy.sh\n{}\n' >"$SINGBOX_CONFIG"
  printf '# Managed by vpn-node-maintenance: sing-box-deploy.sh\n' >"$SYSTEMD_UNIT"
  assert_success check_managed_targets
}

test_port_collision_refused() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture
  printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=1,fd=3))\n' \
    >"$TEST_ROOT/ctl/tcp_busy"
  assert_failure check_ports_available
}

test_port_free_when_no_listener() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture
  assert_success check_ports_available
}

# ==================== Transactional install + rollback ====================

test_successful_install_writes_all_artifacts() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture
  resolve_secrets
  local rc=0
  ( install_server ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc == 0)) || fail "install_server must succeed"
  [[ -f "$SINGBOX_CONFIG" ]] || fail "config.json not installed"
  assert_eq "600" "$(stat -c '%a' "$SINGBOX_CONFIG")" "config.json mode"
  [[ -f "$SYSTEMD_UNIT" ]] || fail "systemd unit not installed"
  assert_eq "644" "$(stat -c '%a' "$SYSTEMD_UNIT")" "unit mode"
  [[ -f "$STATE_FILE" ]] || fail "state file not installed"
  assert_eq "600" "$(stat -c '%a' "$STATE_FILE")" "state mode"
  [[ -f "$CLIENT_FILE" ]] || fail "client file not installed"
  assert_eq "600" "$(stat -c '%a' "$CLIENT_FILE")" "client mode"
  [[ -f "$SELF_SIGNED_CERT" ]] || fail "self-signed cert not installed"
  grep -q '^ARGS: enable sing-box.service' "$TEST_ROOT/systemctl-args.log" ||
    fail "service must be enabled"
  grep -q '^ARGS: restart sing-box.service' "$TEST_ROOT/systemctl-args.log" ||
    fail "service must be restarted"
}

test_rollback_before_install_leaves_no_live_files() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture
  resolve_secrets
  touch "$TEST_ROOT/ctl/singbox_check_fail"
  local rc=0
  ( install_server ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc != 0)) || fail "install_server must fail when sing-box check fails"
  [[ ! -e "$SINGBOX_CONFIG" ]] || fail "no config.json must be left behind"
  [[ ! -e "$SYSTEMD_UNIT" ]] || fail "no systemd unit must be left behind"
  [[ ! -e "$STATE_FILE" ]] || fail "no state file must be left behind"
  [[ -z "$(find "$TRANSACTION_DIR_ROOT" -mindepth 1 2>/dev/null)" ]] ||
    fail "transaction workspace must be cleaned up"
}

test_rollback_after_activation_restores_prior() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture
  resolve_secrets
  # Seed a prior managed config and unit; installation overwrites them, then
  # the (mocked) restart fails, so rollback must restore the originals.
  install -d -m 0755 "$(dirname "$SINGBOX_CONFIG")" "$(dirname "$SYSTEMD_UNIT")"
  printf '// Managed by vpn-node-maintenance: sing-box-deploy.sh\n{"prior":true}\n' \
    >"$SINGBOX_CONFIG"
  chmod 0600 "$SINGBOX_CONFIG"
  printf '# Managed by vpn-node-maintenance: sing-box-deploy.sh\nPRIOR-UNIT\n' \
    >"$SYSTEMD_UNIT"
  chmod 0644 "$SYSTEMD_UNIT"
  touch "$TEST_ROOT/ctl/restart_fail"
  local rc=0
  ( install_server ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc != 0)) || fail "install_server must fail when restart fails"
  grep -qF '"prior":true' "$SINGBOX_CONFIG" ||
    fail "prior config.json must be restored on rollback"
  grep -qF 'PRIOR-UNIT' "$SYSTEMD_UNIT" ||
    fail "prior systemd unit must be restored on rollback"
}

test_install_fails_when_service_never_ready() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture
  resolve_secrets
  touch "$TEST_ROOT/ctl/no_udp"
  local rc=0
  ( install_server ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc != 0)) || fail "install_server must fail when the UDP listener never appears"
}

# ==================== check performs no mutation ====================

test_check_makes_no_mutation() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture
  local rc=0
  ( cmd_check ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc == 0)) || fail "check must succeed on a valid config"
  [[ ! -e "$SINGBOX_CONFIG" ]] || fail "check must not write config.json"
  [[ ! -e "$STATE_FILE" ]] || fail "check must not write the state file"
  [[ ! -e "$SYSTEMD_UNIT" ]] || fail "check must not write the systemd unit"
  if [[ -f "$TEST_ROOT/systemctl-args.log" ]]; then
    ! grep -qE '^ARGS: (enable|restart|daemon-reload)' "$TEST_ROOT/systemctl-args.log" ||
      fail "check must not invoke systemctl mutations"
  fi
}

# ==================== No optional-script invocation ====================

test_script_never_references_optional_installers() {
  new_fixture
  trap remove_fixture EXIT
  ! grep -Eq 'ocserv-deploy\.sh|vpn-maintenance\.sh' "$SCRIPT_PATH" ||
    fail "sing-box-deploy.sh must not reference the other installers"
}

test_no_optional_script_invocation_runtime() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture
  resolve_secrets
  # Tripwire stubs: if the deployer ever shells out to these, the log appears.
  local s
  for s in ocserv-deploy.sh vpn-maintenance.sh; do
    cat >"$TEST_ROOT/bin/$s" <<EOF
#!/usr/bin/env bash
printf 'INVOKED %s\n' "$s" >> "$TEST_ROOT/optional-invoked.log"
exit 0
EOF
    chmod +x "$TEST_ROOT/bin/$s"
  done
  ( install_server ) </dev/null >/dev/null 2>&1 || fail "install_server failed"
  [[ ! -e "$TEST_ROOT/optional-invoked.log" ]] ||
    fail "the installer must never invoke the optional scripts"
}

# ==================== show-client ====================

test_show_client_prints_parameters() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture
  resolve_secrets
  ( install_server ) </dev/null >/dev/null 2>&1 || fail "install_server failed"
  local out
  out="$(cmd_show_client)"
  grep -qF "Managed by vpn-node-maintenance" <<<"$out" ||
    fail "client output must include the managed marker"
  grep -qF "SERVER_IPV4=" <<<"$out" || fail "client output must include SERVER_IPV4"
  grep -qF "REALITY_PUBLIC_KEY=" <<<"$out" || fail "client output must include REALITY_PUBLIC_KEY"
}

test_show_client_missing_fails() {
  new_fixture
  trap remove_fixture EXIT
  write_config "$VALID_CONFIG"
  source_deployer
  assert_failure cmd_show_client
}

# ==================== Client env self-signed certificate handoff ====================

# The default (self-signed) mode must hand the client the full server
# certificate, base64-encoded, so the client can trust it without insecure TLS.
test_client_file_embeds_selfsigned_cert_b64() {
  new_fixture
  trap remove_fixture EXIT
  _orchestration_fixture
  resolve_secrets
  ( install_server ) </dev/null >/dev/null 2>&1 || fail "install_server failed"
  [[ -f "$CLIENT_FILE" ]] || fail "client file not installed"
  grep -q '^HY2_CERT_PEM_B64=' "$CLIENT_FILE" ||
    fail "client file must embed HY2_CERT_PEM_B64"
  local b64 decoded
  b64="$(set +u; source "$CLIENT_FILE"; printf '%s' "$HY2_CERT_PEM_B64")"
  [[ -n "$b64" ]] || fail "HY2_CERT_PEM_B64 must be non-empty in selfsigned mode"
  decoded="$(printf '%s' "$b64" | base64 -d)" ||
    fail "HY2_CERT_PEM_B64 must be valid base64"
  printf '%s' "$decoded" | openssl x509 -noout >/dev/null 2>&1 ||
    fail "decoded HY2_CERT_PEM_B64 must be a valid certificate"
  assert_eq "$(cat "$SELF_SIGNED_CERT")" "$decoded" \
    "embedded certificate must equal the installed self-signed certificate"
}

# Let's Encrypt mode uses a public CA, so no certificate PEM is handed over.
test_client_file_letsencrypt_omits_cert_b64() {
  new_fixture
  trap remove_fixture EXIT
  _make_ip_cert "104.46.217.92" "$TEST_ROOT/le/fullchain.pem" "$TEST_ROOT/le/privkey.pem"
  write_config "
SERVER_IPV4=\"104.46.217.92\"
HY2_CERT_MODE=\"letsencrypt\"
HY2_CERT_FILE=\"$TEST_ROOT/le/fullchain.pem\"
HY2_KEY_FILE=\"$TEST_ROOT/le/privkey.pem\"
REALITY_TARGET=\"www.microsoft.com\"
"
  source_deployer
  load_config
  validate_config
  _write_mocks
  export PATH="$TEST_ROOT/bin:$PATH"
  resolve_secrets
  prepare_certificate
  local out="$TEST_ROOT/client.env"
  render_client_file "$out"
  grep -q "^HY2_CERT_PEM_B64=''" "$out" ||
    fail "letsencrypt client file must carry an empty HY2_CERT_PEM_B64"
}

# ==================== Runner ====================

run_test "valid config passes" test_valid_config_passes
run_test "config must be root-owned" test_config_must_be_root_owned
run_test "config rejects group-writable perms" test_config_rejects_group_writable_perms
run_test "config rejects symlink" test_config_rejects_symlink

run_test "rejects invalid HY2 port" test_rejects_invalid_hy2_port
run_test "rejects invalid REALITY port" test_rejects_invalid_reality_port
run_test "rejects missing SERVER_IPV4" test_rejects_missing_server_ipv4
run_test "rejects bad SERVER_IPV4" test_rejects_bad_server_ipv4
run_test "rejects bad cert mode" test_rejects_bad_cert_mode
run_test "rejects reversed HY2_PORTS range" test_rejects_reversed_hy2_ports_range
run_test "accepts valid HY2_PORTS range" test_accepts_valid_hy2_ports_range

run_test "letsencrypt requires cert fields" test_letsencrypt_requires_cert_fields
run_test "letsencrypt missing cert fails" test_letsencrypt_missing_cert_fails
run_test "letsencrypt matching cert passes" test_letsencrypt_matching_cert_passes
run_test "letsencrypt wrong identity fails" test_letsencrypt_wrong_identity_fails

run_test "selfsigned generates IP SAN and pin" test_selfsigned_generates_ip_san_and_pin
run_test "selfsigned reuses existing pair" test_selfsigned_reuses_existing_pair
run_test "selfsigned refuses half pair" test_selfsigned_refuses_half_pair
run_test "certificate pair mismatch rejected" test_certificate_pair_mismatch_rejected

run_test "secret persistence is shell-escaped" test_secret_persistence_shell_escaped
run_test "secret reuse on rerun" test_secret_reuse_on_rerun
run_test "env secret overrides state" test_env_secret_overrides_state
run_test "missing secrets are generated" test_missing_secrets_are_generated

run_test "config JSON shape" test_config_json_shape
run_test "config JSON omits bandwidth when unset" test_config_json_omits_bandwidth_when_unset
run_test "config JSON includes bandwidth when set" test_config_json_includes_bandwidth_when_set

run_test "systemd unit shape" test_systemd_unit_shape

run_test "hopping include rendered when ports set" test_hopping_include_rendered_when_ports_set
run_test "hopping absent when ports empty" test_hopping_absent_when_ports_empty
run_test "hopping refuses unowned table" test_hopping_refuses_unowned_table
run_test "hopping allows owned table" test_hopping_allows_owned_table
run_test "hopping full install applies nft" test_hopping_full_install_applies_nft
run_test "unit re-applies nft before start when hopping" test_unit_reapplies_nft_before_start_when_hopping
run_test "unit has no nft dependency when ports empty" test_unit_no_nft_dependency_when_ports_empty
run_test "unit drops CAP_NET_ADMIN" test_unit_drops_cap_net_admin
run_test "nft include idempotent cleanup" test_nft_include_idempotent_cleanup

run_test "refuses unmanaged config" test_refuses_unmanaged_config
run_test "refuses unmanaged unit" test_refuses_unmanaged_unit
run_test "allows managed targets" test_allows_managed_targets
run_test "port collision refused" test_port_collision_refused
run_test "port free when no listener" test_port_free_when_no_listener

run_test "successful install writes all artifacts" test_successful_install_writes_all_artifacts
run_test "rollback before install leaves no live files" test_rollback_before_install_leaves_no_live_files
run_test "rollback after activation restores prior" test_rollback_after_activation_restores_prior
run_test "install fails when service never ready" test_install_fails_when_service_never_ready

run_test "check performs no mutation" test_check_makes_no_mutation

run_test "script never references optional installers" test_script_never_references_optional_installers
run_test "no optional-script invocation at runtime" test_no_optional_script_invocation_runtime

run_test "show-client prints parameters" test_show_client_prints_parameters
run_test "show-client missing fails" test_show_client_missing_fails

run_test "client file embeds selfsigned cert b64" test_client_file_embeds_selfsigned_cert_b64
run_test "client file letsencrypt omits cert b64" test_client_file_letsencrypt_omits_cert_b64

finish_tests
