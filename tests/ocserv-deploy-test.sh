#!/usr/bin/env bash

set -Eeuo pipefail

if ((EUID != 0)); then
  exec sudo --preserve-env=PATH bash "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/tests/testlib.sh"

# --real-tools: validate staged rendering against the actual system
# ocserv/nft/ip binaries instead of the PATH-shadowed test doubles used by
# every other test in this file. Every artifact still lives under a
# per-run OCSERV_DEPLOY_ROOT prefix; see test_real_tools_staged_validation.
REAL_TOOLS_MODE=0
if [[ "${1:-}" == "--real-tools" ]]; then
  REAL_TOOLS_MODE=1
fi

new_fixture() {
  TEST_ROOT="$(mktemp -d)"
  export TEST_ROOT
  export VPN_MAINTENANCE_CONFIG="$TEST_ROOT/vpn-maintenance.env"
  export OCSERV_DEPLOY_ROOT="$TEST_ROOT/root"
  install -d -m 0700 "$OCSERV_DEPLOY_ROOT" "$TEST_ROOT/bin"
}

remove_fixture() {
  rm -f -- "$TEST_ROOT/vpn-maintenance.env"
  rm -rf -- "$TEST_ROOT/root" "$TEST_ROOT/bin"
  rmdir -- "$TEST_ROOT"
}

write_config() {
  install -m 0600 /dev/null "$VPN_MAINTENANCE_CONFIG"
  printf '%s\n' "$1" >"$VPN_MAINTENANCE_CONFIG"
  chown root:root "$VPN_MAINTENANCE_CONFIG"
  chmod 0600 "$VPN_MAINTENANCE_CONFIG"
}

source_deployer() {
  OCSERV_DEPLOY_SOURCE_ONLY=1 source "$REPO_ROOT/ocserv-deploy.sh"
}

# ---------- --real-tools: real ocserv/nft/ip staged validation ----------
#
# Renders a self-signed certificate, ocserv.conf, and the ocserv-network
# helper exactly as install_server would stage them, then validates them
# with the real "ocserv --test-config", real "nft --check", and real
# "ip route get" (all installed on the target in Task 7 Step 3) instead of
# the $TEST_ROOT/bin test doubles every other test in this file relies on.
# All rendered paths still live under this run's OCSERV_DEPLOY_ROOT/TEST_ROOT
# prefix. Deliberately bypasses install_server/begin_transaction/rollback
# entirely (no systemctl, no "ocserv-network up", no install_staged_files)
# so a validation failure here can never start ocserv.service, enable it,
# or apply the vpn_node_ocserv nftables table on the real host.
test_real_tools_staged_validation() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT/stage"; remove_fixture' EXIT
  write_config '
OCSERV_ENDPOINT="104.46.217.92"
OCSERV_PORT="18443"
OCSERV_IPV4_NETWORK="10.66.77.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  validate_common_config

  install -d -m 0700 "$TEST_ROOT/stage"
  STAGED_OCSERV_CONF="$TEST_ROOT/stage/ocserv.conf"
  STAGED_NETWORK_HELPER="$TEST_ROOT/stage/ocserv-network"

  # OCSERV_PASSWD (referenced by the "auth" line) is the real, prefixed
  # live path; ocserv --test-config only parses syntax, it never needs to
  # start listening, so no live install/activation ever occurs here.
  install -d -m 0700 "$(dirname "$OCSERV_PASSWD")"
  install -m 0600 /dev/null "$OCSERV_PASSWD"

  prepare_certificate
  render_ocserv_config "$STAGED_OCSERV_CONF"
  chmod 0600 "$STAGED_OCSERV_CONF"
  render_network_helper "$STAGED_NETWORK_HELPER"

  local ok=0
  assert_success test_ocserv_config "$STAGED_OCSERV_CONF" || ok=1
  assert_success "$STAGED_NETWORK_HELPER" check || ok=1
  assert_failure systemctl is-active --quiet ocserv.service || ok=1
  assert_failure nft list table ip vpn_node_ocserv || ok=1
  return "$ok"
}

if ((REAL_TOOLS_MODE)); then
  run_test "real-tools staged validation (real ocserv/nft/ip, no start/apply)" \
    test_real_tools_staged_validation
  finish_tests
  exit $?
fi

test_valid_common_config() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  validate_common_config
  assert_eq "10.66.0.0" "$OCSERV_NETWORK_ADDRESS" "network address"
  assert_eq "255.255.255.0" "$OCSERV_NETMASK" "network mask"
}

test_rejects_invalid_port() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="70000"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  assert_failure validate_common_config
}

test_selfsigned_does_not_require_ddns_or_certbot_fields() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
OCSERV_ENDPOINT="104.46.217.92"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  assert_success validate_common_config
}

# Regression test: scalar OCSERV_DNS must be rejected; only indexed Bash arrays are valid.
test_rejects_scalar_dns() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS="8.8.4.4"
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  assert_failure validate_common_config
}

# ---------- Certificate test helpers ----------

_generate_test_cert() {
  local endpoint="$1" cert="$2" key="$3"
  local san_type="DNS"
  [[ "$endpoint" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && san_type="IP"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 \
    -subj "/CN=${endpoint}" \
    -addext "subjectAltName=${san_type}:${endpoint}" \
    -keyout "$key" -out "$cert" 2>/dev/null
}

_generate_expired_test_cert() {
  local cert="$1" key="$2"
  CERT_OUT="$cert" KEY_OUT="$key" python3 - <<'PYEOF'
import os, datetime
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa

cert_path = os.environ["CERT_OUT"]
key_path = os.environ["KEY_OUT"]
private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "vpn.example.com")])
cert = (
    x509.CertificateBuilder()
    .subject_name(subject)
    .issuer_name(issuer)
    .public_key(private_key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(datetime.datetime(2000, 1, 1, tzinfo=datetime.timezone.utc))
    .not_valid_after(datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc))
    .add_extension(
        x509.SubjectAlternativeName([x509.DNSName("vpn.example.com")]),
        critical=False,
    )
    .sign(private_key, hashes.SHA256())
)
with open(cert_path, "wb") as f:
    f.write(cert.public_bytes(serialization.Encoding.PEM))
with open(key_path, "wb") as f:
    f.write(private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ))
PYEOF
}

# ---------- Certificate tests ----------

test_selfsigned_ip_san() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
OCSERV_ENDPOINT="104.46.217.92"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  validate_common_config
  prepare_certificate
  openssl x509 -in "$SELF_SIGNED_CERT" -noout -text |
    grep -q "IP Address:104.46.217.92" ||
    fail "expected IP Address SAN in self-signed certificate"
}

test_selfsigned_dns_san() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  validate_common_config
  prepare_certificate
  openssl x509 -in "$SELF_SIGNED_CERT" -noout -text |
    grep -q "DNS:vpn.example.com" ||
    fail "expected DNS SAN in self-signed certificate"
}

test_selfsigned_reuse_matching_pair() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  validate_common_config
  install -d -m 0700 "$(dirname "$SELF_SIGNED_CERT")"
  _generate_test_cert "vpn.example.com" "$SELF_SIGNED_CERT" "$SELF_SIGNED_KEY"
  assert_success prepare_certificate
  assert_eq "$SELF_SIGNED_CERT" "$SERVER_CERT_FILE" "SERVER_CERT_FILE after reuse"
  assert_eq "$SELF_SIGNED_KEY" "$SERVER_KEY_FILE" "SERVER_KEY_FILE after reuse"
}

test_selfsigned_one_missing_file_fails() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  validate_common_config
  install -d -m 0700 "$(dirname "$SELF_SIGNED_CERT")"
  _generate_test_cert "vpn.example.com" "$SELF_SIGNED_CERT" "$SELF_SIGNED_KEY"
  rm -f -- "$SELF_SIGNED_KEY"
  assert_failure prepare_certificate
}

test_letsencrypt_matching_san_succeeds() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  local le_dir="$TEST_ROOT/letsencrypt"
  local cert_dir="${le_dir}/live/vpn.example.com"
  install -d -m 0755 "$cert_dir"
  _generate_test_cert "vpn.example.com" "${cert_dir}/fullchain.pem" "${cert_dir}/privkey.pem"
  write_config "
OCSERV_ENDPOINT=\"vpn.example.com\"
OCSERV_PORT=\"8443\"
OCSERV_IPV4_NETWORK=\"10.66.0.0/24\"
OCSERV_DNS=(\"8.8.4.4\")
OCSERV_CERT_MODE=\"letsencrypt\"
CERT_NAME=\"vpn.example.com\"
LE_CONFIG_DIR=\"${le_dir}\"
"
  source_deployer
  load_config
  validate_common_config
  assert_success prepare_certificate
}

test_letsencrypt_missing_files_fail() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  local le_dir="$TEST_ROOT/letsencrypt"
  write_config "
OCSERV_ENDPOINT=\"vpn.example.com\"
OCSERV_PORT=\"8443\"
OCSERV_IPV4_NETWORK=\"10.66.0.0/24\"
OCSERV_DNS=(\"8.8.4.4\")
OCSERV_CERT_MODE=\"letsencrypt\"
CERT_NAME=\"vpn.example.com\"
LE_CONFIG_DIR=\"${le_dir}\"
"
  source_deployer
  load_config
  validate_common_config
  assert_failure prepare_certificate
}

test_letsencrypt_mismatched_key_fails() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  local le_dir="$TEST_ROOT/letsencrypt"
  local cert_dir="${le_dir}/live/vpn.example.com"
  install -d -m 0755 "$cert_dir"
  _generate_test_cert "vpn.example.com" "${cert_dir}/fullchain.pem" "${cert_dir}/privkey.pem"
  openssl genrsa -out "${cert_dir}/privkey.pem" 2048 2>/dev/null
  write_config "
OCSERV_ENDPOINT=\"vpn.example.com\"
OCSERV_PORT=\"8443\"
OCSERV_IPV4_NETWORK=\"10.66.0.0/24\"
OCSERV_DNS=(\"8.8.4.4\")
OCSERV_CERT_MODE=\"letsencrypt\"
CERT_NAME=\"vpn.example.com\"
LE_CONFIG_DIR=\"${le_dir}\"
"
  source_deployer
  load_config
  validate_common_config
  assert_failure prepare_certificate
}

test_letsencrypt_expired_cert_fails() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  local le_dir="$TEST_ROOT/letsencrypt"
  local cert_dir="${le_dir}/live/vpn.example.com"
  install -d -m 0755 "$cert_dir"
  _generate_expired_test_cert "${cert_dir}/fullchain.pem" "${cert_dir}/privkey.pem"
  write_config "
OCSERV_ENDPOINT=\"vpn.example.com\"
OCSERV_PORT=\"8443\"
OCSERV_IPV4_NETWORK=\"10.66.0.0/24\"
OCSERV_DNS=(\"8.8.4.4\")
OCSERV_CERT_MODE=\"letsencrypt\"
CERT_NAME=\"vpn.example.com\"
LE_CONFIG_DIR=\"${le_dir}\"
"
  source_deployer
  load_config
  validate_common_config
  assert_failure prepare_certificate
}

test_letsencrypt_endpoint_mismatch_fails() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  local le_dir="$TEST_ROOT/letsencrypt"
  local cert_dir="${le_dir}/live/vpn.example.com"
  install -d -m 0755 "$cert_dir"
  _generate_test_cert "other.example.com" "${cert_dir}/fullchain.pem" "${cert_dir}/privkey.pem"
  write_config "
OCSERV_ENDPOINT=\"vpn.example.com\"
OCSERV_PORT=\"8443\"
OCSERV_IPV4_NETWORK=\"10.66.0.0/24\"
OCSERV_DNS=(\"8.8.4.4\")
OCSERV_CERT_MODE=\"letsencrypt\"
CERT_NAME=\"vpn.example.com\"
LE_CONFIG_DIR=\"${le_dir}\"
"
  source_deployer
  load_config
  validate_common_config
  assert_failure prepare_certificate
}

test_render_certbot_hook() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="letsencrypt"
'
  source_deployer
  local hook_out="$TEST_ROOT/test-hook"
  render_certbot_hook "$hook_out"
  [[ -f "$hook_out" ]] || fail "hook file was not created"
  head -1 "$hook_out" | grep -q '^#!/usr/bin/env bash$' ||
    fail "hook must start with #!/usr/bin/env bash"
  grep -q 'source.*CONFIG_FILE' "$hook_out" ||
    fail "hook must source CONFIG_FILE"
  grep -q 'RENEWED_LINEAGE' "$hook_out" ||
    fail "hook must compare RENEWED_LINEAGE"
  grep -q 'systemctl reload ocserv.service' "$hook_out" ||
    fail "hook must invoke systemctl reload ocserv.service"
}

test_selfsigned_no_hook_created() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  validate_common_config
  prepare_certificate
  [[ ! -f "$CERT_HOOK" ]] ||
    fail "self-signed mode must not create a certbot hook"
}


# ---------- Fix 1: prepare_certificate must reject unsupported modes ----------

test_prepare_certificate_unknown_mode_fails() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  OCSERV_CERT_MODE="custom"
  assert_failure prepare_certificate
}

# ---------- Fix 2: generate_self_signed_certificate must clean up on failure --

test_generate_selfsigned_cleans_up_on_failure() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  validate_common_config
  # Force a late failure inside generate_self_signed_certificate so temp files
  # are already created when the function aborts.
  certificate_matches_endpoint() { return 1; }
  assert_failure generate_self_signed_certificate
  local ssl_dir leftover
  ssl_dir="$(dirname "$SELF_SIGNED_CERT")"
  leftover="$(find "$ssl_dir" -maxdepth 1 \( -name '.cert.*' -o -name '.key.*' \) 2>/dev/null | wc -l)"
  ((leftover == 0)) || fail "temp cert/key files were not cleaned up after failure (found $leftover)"
}

# ---------- Fix 3: self-signed mode must mark managed hook for deletion -------

test_selfsigned_marks_managed_hook_for_deletion() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  validate_common_config
  install -d -m 0755 "$(dirname "$CERT_HOOK")"
  # Create a managed hook (contains MANAGED_MARKER)
  printf '#!/usr/bin/env bash\n%s\n' "$MANAGED_MARKER" >"$CERT_HOOK"
  prepare_certificate
  assert_eq "1" "${CERT_HOOK_DELETE:-}" "CERT_HOOK_DELETE must be 1 when a managed hook exists"
}

test_selfsigned_does_not_mark_unmanaged_hook() {
  new_fixture
  trap remove_fixture EXIT
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  validate_common_config
  install -d -m 0755 "$(dirname "$CERT_HOOK")"
  # Create an unmanaged hook (no MANAGED_MARKER)
  printf '#!/usr/bin/env bash\n# Custom hook\n' >"$CERT_HOOK"
  prepare_certificate
  [[ -z "${CERT_HOOK_DELETE:-}" ]] ||
    fail "unmanaged hook must not be marked for deletion"
}

# ---------- Fix 4: certificate_matches_endpoint must propagate genuine errors -
# RED: current code returns 1 (from [[...]] fallthrough) instead of the real
#      OpenSSL exit code when openssl fails for a reason unrelated to mismatch.
# GREEN: with || rc=$? + result-text check, the genuine exit code is returned.

test_certificate_matches_endpoint_propagates_genuine_error() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  source_deployer
  local cert_dir="$TEST_ROOT/certs"
  install -d -m 0755 "$cert_dir"
  _generate_test_cert "vpn.example.com" "$cert_dir/cert.pem" "$cert_dir/key.pem"
  # Fake openssl: for -checkhost/-checkip, exit 2 with no match text on stdout
  # (simulates a genuine OpenSSL error, not a simple mismatch).
  cat >"$TEST_ROOT/bin/openssl" <<'FAKE_EOF'
#!/usr/bin/env bash
if [[ "$*" == *-checkhost* || "$*" == *-checkip* ]]; then
  printf 'could not read certificate\n' >&2
  exit 2
fi
exec /usr/bin/openssl "$@"
FAKE_EOF
  chmod +x "$TEST_ROOT/bin/openssl"
  local rc=0
  PATH="$TEST_ROOT/bin:$PATH" certificate_matches_endpoint "$cert_dir/cert.pem" "vpn.example.com" || rc=$?
  assert_eq "2" "$rc" "genuine OpenSSL error exit code must be propagated (not 1)"
}

run_test "valid common config" test_valid_common_config
run_test "invalid port" test_rejects_invalid_port
run_test "self-signed without DDNS" test_selfsigned_does_not_require_ddns_or_certbot_fields
run_test "rejects scalar DNS" test_rejects_scalar_dns
run_test "self-signed IP SAN" test_selfsigned_ip_san
run_test "self-signed DNS SAN" test_selfsigned_dns_san
run_test "self-signed reuse matching pair" test_selfsigned_reuse_matching_pair
run_test "self-signed one missing file fails" test_selfsigned_one_missing_file_fails
run_test "Lets Encrypt matching SAN succeeds" test_letsencrypt_matching_san_succeeds
run_test "Lets Encrypt missing files fail" test_letsencrypt_missing_files_fail
run_test "Lets Encrypt mismatched key fails" test_letsencrypt_mismatched_key_fails
run_test "Lets Encrypt expired cert fails" test_letsencrypt_expired_cert_fails
run_test "Lets Encrypt endpoint mismatch fails" test_letsencrypt_endpoint_mismatch_fails
run_test "render certbot hook" test_render_certbot_hook
run_test "self-signed no hook created" test_selfsigned_no_hook_created
run_test "prepare certificate unknown mode fails" test_prepare_certificate_unknown_mode_fails
run_test "generate selfsigned cleans up on failure" test_generate_selfsigned_cleans_up_on_failure
run_test "selfsigned marks managed hook for deletion" test_selfsigned_marks_managed_hook_for_deletion
run_test "selfsigned does not mark unmanaged hook" test_selfsigned_does_not_mark_unmanaged_hook
run_test "certificate matches endpoint propagates genuine error" test_certificate_matches_endpoint_propagates_genuine_error

# ==================== Task 3: Password-File User Management ====================

_write_mock_ocpasswd() {
  cat >"$TEST_ROOT/bin/ocpasswd" <<'MOCK_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'ARGS: %s\n' "$*" >> "${TEST_ROOT}/ocpasswd-args.log"
delete_mode=0
password_file=""
username=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) password_file="$2"; shift 2 ;;
    -d) delete_mode=1; shift ;;
    *) username="$1"; shift ;;
  esac
done
if ((delete_mode)); then
  [[ -f "$password_file" ]] || { printf 'no password file\n' >&2; exit 1; }
  awk -F: -v u="$username" '$1==u{f=1}END{exit !f}' "$password_file" ||
    { printf 'user not found\n' >&2; exit 1; }
  tmpf="$(mktemp "${password_file}.XXXXXX")"
  awk -F: -v u="$username" '$1!=u' "$password_file" > "$tmpf"
  mv "$tmpf" "$password_file"
  exit 0
fi
IFS= read -r p1
IFS= read -r p2
[[ -n "$p1" ]] || { printf 'empty password\n' >&2; exit 1; }
[[ "$p1" == "$p2" ]] || { printf 'passwords do not match\n' >&2; exit 1; }
[[ -f "$password_file" ]] || touch "$password_file"
tmpf="$(mktemp "${password_file}.XXXXXX")"
awk -F: -v u="$username" '$1!=u' "$password_file" > "$tmpf"
printf '%s:%s\n' "$username" "$p1" >> "$tmpf"
mv "$tmpf" "$password_file"
MOCK_EOF
  chmod +x "$TEST_ROOT/bin/ocpasswd"
}

test_validate_username_valid_forms() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  assert_success validate_username "alice"
  assert_success validate_username "alice.smith"
  assert_success validate_username "alice_test"
  assert_success validate_username "alice-2"
}

test_validate_username_rejects_empty() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  assert_failure validate_username ""
}

test_validate_username_rejects_leading_dash() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  assert_failure validate_username "-alice"
}

test_validate_username_rejects_whitespace() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  assert_failure validate_username "alice smith"
}

test_validate_username_rejects_slash() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  assert_failure validate_username "alice/smith"
}

test_validate_username_rejects_colon() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  assert_failure validate_username "alice:smith"
}

test_validate_username_rejects_over_64_chars() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  local long_name
  long_name="$(python3 -c 'print("a"*65, end="")')"
  assert_failure validate_username "$long_name"
}

test_read_confirmed_password_mismatch_rejected() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  local rc=0
  (read_confirmed_password) < <(printf 'pass1\npass2\n') 2>/dev/null || rc=$?
  ((rc != 0)) || fail "mismatched passwords must be rejected"
}

test_read_confirmed_password_empty_rejected() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  local rc=0
  (read_confirmed_password) < <(printf '\n\n') 2>/dev/null || rc=$?
  ((rc != 0)) || fail "empty password must be rejected"
}

test_set_user_password_clears_password_on_failure() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  cat >"$TEST_ROOT/bin/ocpasswd" <<'MOCK_EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 1
MOCK_EOF
  chmod +x "$TEST_ROOT/bin/ocpasswd"
  local passwd_file="$TEST_ROOT/ocpasswd"
  install -m 0600 /dev/null "$passwd_file"
  local result_file="$TEST_ROOT/pw_state"

  # Run set_user_password in a fresh shell where set -e is genuinely
  # active so the production bug (early exit leaving CONFIRMED_PASSWORD
  # set) is visible via the EXIT trap.
  local rc=0
  TEST_ROOT="$TEST_ROOT" REPO_ROOT="$REPO_ROOT" RESULT_FILE="$result_file" \
    PATH="$TEST_ROOT/bin:$PATH" OCSERV_DEPLOY_ROOT="$OCSERV_DEPLOY_ROOT" \
    bash <<'SUBSH' || rc=$?
set -Eeuo pipefail
OCSERV_DEPLOY_SOURCE_ONLY=1 source "$REPO_ROOT/ocserv-deploy.sh"
CONFIRMED_PASSWORD="topsecret"
trap 'printf "${CONFIRMED_PASSWORD+still_set}" > "${RESULT_FILE}"' EXIT
set_user_password alice "$TEST_ROOT/ocpasswd"
SUBSH

  ((rc != 0)) || fail "set_user_password must propagate nonzero exit from ocpasswd"
  [[ -f "$result_file" ]] || fail "EXIT trap did not write result file"
  local pw_state
  pw_state="$(cat "$result_file")"
  [[ -z "$pw_state" ]] ||
    fail "CONFIRMED_PASSWORD must be cleared after ocpasswd failure (EXIT trap saw: still_set)"
}

test_add_user_no_password_in_args() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _write_mock_ocpasswd
  source_deployer
  local passwd_file="$TEST_ROOT/ocpasswd"
  install -m 0600 /dev/null "$passwd_file"
  export PATH="$TEST_ROOT/bin:$PATH"
  add_user "alice" "$passwd_file" < <(printf 'secretpassword\nsecretpassword\n')
  grep -q '^alice:' "$passwd_file" ||
    fail "user alice was not added to password file"
  [[ -f "$TEST_ROOT/ocpasswd-args.log" ]] ||
    fail "ocpasswd-args.log must exist — mock ocpasswd was not invoked"
  grep -qF "secretpassword" "$TEST_ROOT/ocpasswd-args.log" &&
    fail "password must not appear in ocpasswd arguments" || true
}

test_add_user_duplicate_rejected() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _write_mock_ocpasswd
  source_deployer
  local passwd_file="$TEST_ROOT/ocpasswd"
  install -m 0600 /dev/null "$passwd_file"
  export PATH="$TEST_ROOT/bin:$PATH"
  add_user "alice" "$passwd_file" < <(printf 'password1\npassword1\n')
  local rc=0
  (add_user "alice" "$passwd_file") < <(printf 'password1\npassword1\n') 2>/dev/null || rc=$?
  ((rc != 0)) || fail "duplicate add_user must be rejected"
}

test_delete_user_existing() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _write_mock_ocpasswd
  source_deployer
  local passwd_file="$TEST_ROOT/ocpasswd"
  install -m 0600 /dev/null "$passwd_file"
  export PATH="$TEST_ROOT/bin:$PATH"
  add_user "alice" "$passwd_file" < <(printf 'password1\npassword1\n')
  assert_success delete_user "alice" "$passwd_file"
  grep -q '^alice:' "$passwd_file" 2>/dev/null &&
    fail "user alice should have been deleted" || true
}

test_delete_user_missing_rejected() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _write_mock_ocpasswd
  source_deployer
  local passwd_file="$TEST_ROOT/ocpasswd"
  install -m 0600 /dev/null "$passwd_file"
  export PATH="$TEST_ROOT/bin:$PATH"
  assert_failure delete_user "alice" "$passwd_file"
}

test_ensure_initial_user_empty_prompts() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _write_mock_ocpasswd
  source_deployer
  local passwd_file="$TEST_ROOT/ocpasswd"
  install -m 0600 /dev/null "$passwd_file"
  export PATH="$TEST_ROOT/bin:$PATH"
  ensure_initial_user "$passwd_file" < <(printf 'testuser\ntestpass\ntestpass\n')
  grep -q '^testuser:' "$passwd_file" ||
    fail "initial user was not added to empty password file"
}

test_ensure_initial_user_nonempty_skips() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _write_mock_ocpasswd
  source_deployer
  local passwd_file="$TEST_ROOT/ocpasswd"
  install -m 0600 /dev/null "$passwd_file"
  printf 'alice:hash\n' > "$passwd_file"
  export PATH="$TEST_ROOT/bin:$PATH"
  ensure_initial_user "$passwd_file" </dev/null
  grep -q '^alice:' "$passwd_file" ||
    fail "existing user should remain when file is non-empty"
  local line_count
  line_count="$(wc -l < "$passwd_file")"
  ((line_count == 1)) || fail "no new user should be added when file is non-empty"
}

run_test "valid username forms" test_validate_username_valid_forms
run_test "rejects empty username" test_validate_username_rejects_empty
run_test "rejects leading dash" test_validate_username_rejects_leading_dash
run_test "rejects whitespace in username" test_validate_username_rejects_whitespace
run_test "rejects slash in username" test_validate_username_rejects_slash
run_test "rejects colon in username" test_validate_username_rejects_colon
run_test "rejects username over 64 chars" test_validate_username_rejects_over_64_chars
run_test "password mismatch rejected" test_read_confirmed_password_mismatch_rejected
run_test "empty password rejected" test_read_confirmed_password_empty_rejected
run_test "ocpasswd failure clears password" test_set_user_password_clears_password_on_failure
run_test "add-user no password in args" test_add_user_no_password_in_args
run_test "add-user duplicate rejected" test_add_user_duplicate_rejected
run_test "delete existing user" test_delete_user_existing
run_test "delete missing user rejected" test_delete_user_missing_rejected
run_test "ensure initial user on empty file" test_ensure_initial_user_empty_prompts
run_test "ensure initial user skips non-empty" test_ensure_initial_user_nonempty_skips

# ==================== Task 4: Managed ocserv Configuration and Host Conflict Checks ====================

_prepare_rendered_fixture() {
  # Sets up a fully validated common config plus a self-signed certificate
  # so render_ocserv_config has every input it needs (OCSERV_PASSWD,
  # SERVER_CERT_FILE, SERVER_KEY_FILE, OCSERV_NETWORK_ADDRESS, ...).
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4" "1.1.1.1")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  validate_common_config
  prepare_certificate
}

# ---------- render_ocserv_config ----------

test_render_ocserv_config_marker_first_line() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _prepare_rendered_fixture
  local out="$TEST_ROOT/rendered.conf"
  render_ocserv_config "$out"
  local first_line
  first_line="$(head -n1 "$out")"
  assert_eq "$MANAGED_MARKER" "$first_line" "rendered config first line"
}

test_render_ocserv_config_ports() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _prepare_rendered_fixture
  local out="$TEST_ROOT/rendered.conf"
  render_ocserv_config "$out"
  local ok=0
  grep -Fqx "tcp-port = ${OCSERV_PORT}" "$out" ||
    { fail "tcp-port directive missing or wrong"; ok=1; }
  grep -Fqx "udp-port = ${OCSERV_PORT}" "$out" ||
    { fail "udp-port directive missing or wrong"; ok=1; }
  return "$ok"
}

test_render_ocserv_config_auth() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _prepare_rendered_fixture
  local out="$TEST_ROOT/rendered.conf"
  render_ocserv_config "$out"
  grep -Fqx "auth = \"plain[${OCSERV_PASSWD}]\"" "$out" ||
    fail "auth directive must reference the effective OCSERV_PASSWD"
}

test_render_ocserv_config_certs() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _prepare_rendered_fixture
  local out="$TEST_ROOT/rendered.conf"
  render_ocserv_config "$out"
  local ok=0
  grep -Fqx "server-cert = ${SERVER_CERT_FILE}" "$out" ||
    { fail "server-cert directive must match the selected certificate mode"; ok=1; }
  grep -Fqx "server-key = ${SERVER_KEY_FILE}" "$out" ||
    { fail "server-key directive must match the selected certificate mode"; ok=1; }
  return "$ok"
}

test_render_ocserv_config_network() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _prepare_rendered_fixture
  local out="$TEST_ROOT/rendered.conf"
  render_ocserv_config "$out"
  local ok=0
  grep -Fqx "ipv4-network = ${OCSERV_NETWORK_ADDRESS}" "$out" ||
    { fail "ipv4-network must derive from OCSERV_IPV4_NETWORK"; ok=1; }
  grep -Fqx "ipv4-netmask = ${OCSERV_NETMASK}" "$out" ||
    { fail "ipv4-netmask must derive from OCSERV_IPV4_NETWORK"; ok=1; }
  return "$ok"
}

test_render_ocserv_config_dns_multiple() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _prepare_rendered_fixture
  local out="$TEST_ROOT/rendered.conf"
  render_ocserv_config "$out"
  local ok=0
  grep -Fqx "dns = 8.8.4.4" "$out" ||
    { fail "expected dns = 8.8.4.4 directive"; ok=1; }
  grep -Fqx "dns = 1.1.1.1" "$out" ||
    { fail "expected dns = 1.1.1.1 directive"; ok=1; }
  local dns_count
  dns_count="$(grep -c '^dns = ' "$out")"
  assert_eq "2" "$dns_count" "each OCSERV_DNS array item must render as its own directive" ||
    ok=1
  return "$ok"
}

test_render_ocserv_config_route_and_no_compression() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _prepare_rendered_fixture
  local out="$TEST_ROOT/rendered.conf"
  render_ocserv_config "$out"
  local ok=0
  grep -Fqx "route = default" "$out" ||
    { fail "expected route = default directive"; ok=1; }
  if grep -q '^compression' "$out"; then
    fail "compression must not be enabled"
    ok=1
  fi
  return "$ok"
}

# ---------- check_existing_config ----------

test_check_existing_config_unknown_backed_up_and_fails() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  install -d -m 0755 "$(dirname "$OCSERV_CONF")"
  printf 'some unmanaged content\n' >"$OCSERV_CONF"
  local ok=0
  assert_failure check_existing_config || ok=1
  local backups
  backups=("${OCSERV_CONF}".pre-vpn-node-*.bak)
  [[ -f "${backups[0]}" ]] ||
    { fail "unmanaged config must be backed up before failing"; ok=1; }
  grep -qF "some unmanaged content" "${backups[0]}" 2>/dev/null ||
    { fail "backup must contain the original unmanaged content"; ok=1; }
  return "$ok"
}

test_check_existing_config_managed_accepted() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  install -d -m 0755 "$(dirname "$OCSERV_CONF")"
  printf '%s\n' "$MANAGED_MARKER" >"$OCSERV_CONF"
  local ok=0
  assert_success check_existing_config || ok=1
  assert_eq "1" "$CONF_EXISTED_BEFORE_INSTALL" \
    "CONF_EXISTED_BEFORE_INSTALL must be captured for pre-existing managed config" || ok=1
  return "$ok"
}

test_check_existing_config_absent_passes() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  local ok=0
  assert_success check_existing_config || ok=1
  assert_eq "0" "$CONF_EXISTED_BEFORE_INSTALL" \
    "CONF_EXISTED_BEFORE_INSTALL must be 0 when no config existed before install" || ok=1
  return "$ok"
}

# ---------- check_port_available ----------

_free_tcp_port() {
  python3 - <<'PYEOF'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PYEOF
}

_start_test_listener() {
  # Starts a background TCP listener on the given port using the given
  # executable (invoked by full path so its process name/comm matches the
  # executable's own file name), and echoes its PID.
  local exe="$1" port="$2"
  "$exe" - "$port" >/dev/null 2>&1 <<'PYEOF' &
import socket, sys, time
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", port))
s.listen(1)
time.sleep(10)
PYEOF
  echo $!
}

_write_mock_ocserv_listener_binary() {
  # A real executable literally named "ocserv" so `ss -p` reports the
  # owning process name as "ocserv" (comm derives from the exec'd path).
  cp "$(command -v python3)" "$TEST_ROOT/bin/ocserv"
  chmod +x "$TEST_ROOT/bin/ocserv"
}

test_check_port_available_free_port_passes() {
  new_fixture
  trap remove_fixture EXIT
  source_deployer
  OCSERV_PORT="$(_free_tcp_port)"
  assert_success check_port_available
}

test_check_port_available_other_process_fails() {
  new_fixture
  listener_pid=""
  trap 'kill "$listener_pid" 2>/dev/null; remove_fixture' EXIT
  source_deployer
  OCSERV_PORT="$(_free_tcp_port)"
  listener_pid="$(_start_test_listener "$(command -v python3)" "$OCSERV_PORT")"
  sleep 0.5
  assert_failure check_port_available
}

test_check_port_available_managed_rerun_allows_ocserv() {
  new_fixture
  listener_pid=""
  trap 'kill "$listener_pid" 2>/dev/null; remove_fixture' EXIT
  source_deployer
  local port
  port="$(_free_tcp_port)"
  OCSERV_PORT="$port"
  install -d -m 0755 "$(dirname "$OCSERV_CONF")"
  printf '%s\ntcp-port = %s\nudp-port = %s\n' "$MANAGED_MARKER" "$port" "$port" >"$OCSERV_CONF"
  _write_mock_ocserv_listener_binary
  listener_pid="$(_start_test_listener "$TEST_ROOT/bin/ocserv" "$port")"
  sleep 0.5
  assert_success check_port_available
}

test_check_port_available_managed_rerun_port_change_conflict_fails() {
  new_fixture
  listener_pid=""
  trap 'kill "$listener_pid" 2>/dev/null; remove_fixture' EXIT
  source_deployer
  local old_port new_port
  old_port="$(_free_tcp_port)"
  new_port="$(_free_tcp_port)"
  while [[ "$new_port" == "$old_port" ]]; do
    new_port="$(_free_tcp_port)"
  done
  OCSERV_PORT="$new_port"
  install -d -m 0755 "$(dirname "$OCSERV_CONF")"
  printf '%s\ntcp-port = %s\nudp-port = %s\n' "$MANAGED_MARKER" "$old_port" "$old_port" >"$OCSERV_CONF"
  listener_pid="$(_start_test_listener "$(command -v python3)" "$new_port")"
  sleep 0.5
  assert_failure check_port_available
}

test_check_port_available_managed_rerun_same_port_non_ocserv_owner_fails() {
  new_fixture
  listener_pid=""
  trap 'kill "$listener_pid" 2>/dev/null; remove_fixture' EXIT
  source_deployer
  local port
  port="$(_free_tcp_port)"
  OCSERV_PORT="$port"
  install -d -m 0755 "$(dirname "$OCSERV_CONF")"
  printf '%s\ntcp-port = %s\nudp-port = %s\n' "$MANAGED_MARKER" "$port" "$port" >"$OCSERV_CONF"
  # Listener is plain python3 (not ocserv) on the same configured port.
  # The ownership check must reject it even on a managed rerun.
  listener_pid="$(_start_test_listener "$(command -v python3)" "$OCSERV_PORT")"
  sleep 0.5
  assert_failure check_port_available
}

# ---------- check_route_overlap ----------

_write_mock_ip() {
  local routes_file="$TEST_ROOT/mock_routes.txt"
  printf '%s\n' "$1" >"$routes_file"
  cat >"$TEST_ROOT/bin/ip" <<MOCK_EOF
#!/usr/bin/env bash
cat "$routes_file"
MOCK_EOF
  chmod +x "$TEST_ROOT/bin/ip"
}

test_check_route_overlap_conflict_fails() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  validate_common_config
  _write_mock_ip 'default via 172.16.0.1 dev eth0 proto dhcp src 172.16.0.4 metric 100
10.66.0.128/26 dev eth0 proto kernel scope link src 10.66.0.129 metric 100'
  PATH="$TEST_ROOT/bin:$PATH" assert_failure check_route_overlap
}

test_check_route_overlap_unrelated_passes() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  source_deployer
  load_config
  validate_common_config
  _write_mock_ip 'default via 172.16.0.1 dev eth0 proto dhcp src 172.16.0.4 metric 100
172.16.0.0/24 dev eth0 proto kernel scope link src 172.16.0.4 metric 100
172.16.0.1 dev eth0 proto dhcp scope link src 172.16.0.4 metric 100'
  PATH="$TEST_ROOT/bin:$PATH" assert_success check_route_overlap
}

# ---------- test_ocserv_config ----------

_write_mock_ocserv_cli() {
  cat >"$TEST_ROOT/bin/ocserv" <<'MOCK_EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*" >> "${TEST_ROOT}/ocserv-args.log"
exit 0
MOCK_EOF
  chmod +x "$TEST_ROOT/bin/ocserv"
}

test_test_ocserv_config_invokes_test_config() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  source_deployer
  _write_mock_ocserv_cli
  local temp_conf="$TEST_ROOT/temp.conf"
  : >"$temp_conf"
  local ok=0
  PATH="$TEST_ROOT/bin:$PATH" assert_success test_ocserv_config "$temp_conf" || ok=1
  grep -qF "ARGS: -c ${temp_conf} --test-config" "$TEST_ROOT/ocserv-args.log" 2>/dev/null ||
    { fail "test_ocserv_config must invoke: ocserv -c \$TEMP_CONF --test-config"; ok=1; }
  return "$ok"
}

run_test "render config marker first line" test_render_ocserv_config_marker_first_line
run_test "render config TCP/UDP ports" test_render_ocserv_config_ports
run_test "render config auth" test_render_ocserv_config_auth
run_test "render config certificate paths" test_render_ocserv_config_certs
run_test "render config network/mask" test_render_ocserv_config_network
run_test "render config multiple DNS directives" test_render_ocserv_config_dns_multiple
run_test "render config route default, no compression" test_render_ocserv_config_route_and_no_compression
run_test "unknown existing config backed up and fails" test_check_existing_config_unknown_backed_up_and_fails
run_test "managed existing config accepted" test_check_existing_config_managed_accepted
run_test "absent existing config passes" test_check_existing_config_absent_passes
run_test "free port passes" test_check_port_available_free_port_passes
run_test "port owned by other process fails" test_check_port_available_other_process_fails
run_test "managed rerun allows ocserv listener on same port" test_check_port_available_managed_rerun_allows_ocserv
run_test "managed rerun port change conflict fails" test_check_port_available_managed_rerun_port_change_conflict_fails
run_test "managed rerun same port non-ocserv owner fails" test_check_port_available_managed_rerun_same_port_non_ocserv_owner_fails
run_test "route overlap conflict fails" test_check_route_overlap_conflict_fails
run_test "route overlap unrelated route passes" test_check_route_overlap_unrelated_passes
run_test "test_ocserv_config invokes ocserv --test-config" test_test_ocserv_config_invokes_test_config

# ==================== Task 5: nftables Helper and systemd Lifecycle ====================

_write_mock_ip_route_get() {
  local interface="$1"
  cat >"$TEST_ROOT/bin/ip" <<MOCK_EOF
#!/usr/bin/env bash
printf '1.1.1.1 via 172.16.0.1 dev ${interface} src 172.16.0.4 uid 0\n'
printf '    cache\n'
MOCK_EOF
  chmod +x "$TEST_ROOT/bin/ip"
}

_write_mock_sysctl() {
  cat >"$TEST_ROOT/bin/sysctl" <<'MOCK_EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*" >> "${TEST_ROOT}/sysctl-args.log"
exit 0
MOCK_EOF
  chmod +x "$TEST_ROOT/bin/sysctl"
}

# Fake nft that tracks table/chain existence as marker files under
# $TEST_ROOT/nft-state/<table>/chain_<name>, logs every invocation (with
# start/end timestamps for lock-serialization checks), and records the last
# rule file it was given so tests can inspect rendered rule content.
_write_mock_nft() {
  cat >"$TEST_ROOT/bin/nft" <<'MOCK_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE_DIR="${TEST_ROOT}/nft-state"
LOG="${TEST_ROOT}/nft-args.log"
TIMELINE_LOG="${TEST_ROOT}/nft-timeline.log"
mkdir -p "$STATE_DIR"
start_ts="$(date +%s%N)"
finish() {
  local end_ts
  end_ts="$(date +%s%N)"
  printf '%s %s\n' "$start_ts" "$end_ts" >> "$TIMELINE_LOG"
}
trap finish EXIT
printf 'ARGS: %s\n' "$*" >> "$LOG"
sleep 0.2

case "$1" in
  list)
    case "$2" in
      table)
        [[ -d "${STATE_DIR}/$4" ]] || exit 1
        exit 0
        ;;
      chain)
        [[ -f "${STATE_DIR}/$4/chain_$5" ]] || exit 1
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
  --check)
    [[ "$2" == "-f" ]] || exit 1
    file="$3"
    cp -- "$file" "${TEST_ROOT}/last-ruleset.nft"
    [[ -s "$file" ]] || exit 1
    exit 0
    ;;
  -f)
    file="$2"
    cp -- "$file" "${TEST_ROOT}/last-ruleset.nft"
    [[ -s "$file" ]] || exit 1
    name="$(awk '$1=="table"{print $3; exit}' "$file")"
    mkdir -p "${STATE_DIR}/${name}"
    while IFS= read -r chain_name; do
      : >"${STATE_DIR}/${name}/chain_${chain_name}"
    done < <(awk '$1=="chain"{print $2}' "$file")
    exit 0
    ;;
  delete)
    [[ "$2" == "table" ]] || exit 1
    name="$4"
    rm -rf -- "${STATE_DIR:?}/${name}"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
MOCK_EOF
  chmod +x "$TEST_ROOT/bin/nft"
}

_seed_owned_table() {
  mkdir -p "$TEST_ROOT/nft-state/vpn_node_ocserv"
  : >"$TEST_ROOT/nft-state/vpn_node_ocserv/chain__managed_by_vpn_node_maintenance"
}

_seed_unowned_table() {
  mkdir -p "$TEST_ROOT/nft-state/vpn_node_ocserv"
  : >"$TEST_ROOT/nft-state/vpn_node_ocserv/chain_input"
}

_network_helper_fixture() {
  local subnet="${1:-10.66.0.0/24}"
  write_config "
OCSERV_ENDPOINT=\"vpn.example.com\"
OCSERV_PORT=\"8443\"
OCSERV_IPV4_NETWORK=\"${subnet}\"
OCSERV_DNS=(\"8.8.4.4\")
OCSERV_CERT_MODE=\"selfsigned\"
"
  source_deployer
  load_config
  validate_common_config
  _write_mock_ip_route_get "eth0"
  _write_mock_sysctl
  _write_mock_nft
}

_render_helper() {
  local helper="$TEST_ROOT/network-helper"
  render_network_helper "$helper"
  printf '%s' "$helper"
}

test_render_network_helper_output_is_executable() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  local helper; helper="$(_render_helper)"
  [[ -x "$helper" ]] || fail "rendered network helper must be executable"
}

test_render_network_helper_check_absent_table_succeeds() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" check
}

test_render_network_helper_check_invokes_check_only_no_apply() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" check
  local ok=0
  grep -qE '^ARGS: --check -f' "$TEST_ROOT/nft-args.log" ||
    { fail "check must invoke nft --check -f"; ok=1; }
  if grep -qE '^ARGS: -f ' "$TEST_ROOT/nft-args.log"; then
    fail "check must not apply a table via nft -f"
    ok=1
  fi
  if [[ -n "$(find "$TEST_ROOT/nft-state" -mindepth 1 2>/dev/null)" ]]; then
    fail "check must not leave any applied nftables state behind"
    ok=1
  fi
  return "$ok"
}

test_render_network_helper_check_does_not_touch_ip_forward() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" check
  [[ ! -s "$TEST_ROOT/sysctl-args.log" ]] ||
    fail "check must not modify net.ipv4.ip_forward"
}

test_render_network_helper_up_absent_table_succeeds() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" up
}

test_render_network_helper_up_sets_ip_forward() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" up
  grep -qF 'ARGS: -w net.ipv4.ip_forward=1' "$TEST_ROOT/sysctl-args.log" ||
    fail "up must invoke sysctl -w net.ipv4.ip_forward=1"
}

test_render_network_helper_up_rules_contain_expected_elements_only() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" up
  local out="$TEST_ROOT/last-ruleset.nft" ok=0
  grep -Fq '10.66.0.0/24' "$out" || { fail "ruleset must reference the configured subnet"; ok=1; }
  grep -Fq 'oifname "eth0"' "$out" || { fail "ruleset must reference the detected egress interface"; ok=1; }
  grep -Fq 'masquerade' "$out" || { fail "ruleset must contain a masquerade rule"; ok=1; }
  grep -Fq 'ct state established,related accept' "$out" ||
    { fail "ruleset must return established/related traffic"; ok=1; }
  return "$ok"
}

test_render_network_helper_forward_chain_policy_accept() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" up
  grep -Fq 'type filter hook forward priority filter; policy accept;' "$TEST_ROOT/last-ruleset.nft" ||
    fail "forward base chain must use policy accept"
}

test_render_network_helper_no_input_chain_or_drop_policy() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" up
  local out="$TEST_ROOT/last-ruleset.nft" ok=0
  if grep -qi 'hook input' "$out"; then
    fail "ruleset must not define an INPUT chain"
    ok=1
  fi
  if grep -qi 'policy drop' "$out"; then
    fail "ruleset must not use a DROP policy"
    ok=1
  fi
  return "$ok"
}

test_render_network_helper_table_contains_sentinel_chain() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" up
  grep -Fq 'chain _managed_by_vpn_node_maintenance {' "$TEST_ROOT/last-ruleset.nft" ||
    fail "table must contain the sentinel chain"
}

test_render_network_helper_uses_configured_subnet_not_hardcoded() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture "10.77.0.0/24"
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" up
  local out="$TEST_ROOT/last-ruleset.nft" ok=0
  grep -Fq '10.77.0.0/24' "$out" ||
    { fail "ruleset must use the configured subnet"; ok=1; }
  if grep -Fq '10.66.0.0/24' "$out"; then
    fail "ruleset must not contain an unrelated hardcoded subnet"
    ok=1
  fi
  return "$ok"
}

test_render_network_helper_up_replaces_owned_table() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  _seed_owned_table
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" up
  local ok=0
  grep -qF 'ARGS: delete table ip vpn_node_ocserv' "$TEST_ROOT/nft-args.log" ||
    { fail "up must delete the previously owned table before re-applying"; ok=1; }
  [[ -f "$TEST_ROOT/nft-state/vpn_node_ocserv/chain__managed_by_vpn_node_maintenance" ]] ||
    { fail "re-applied table must contain the sentinel chain"; ok=1; }
  [[ -f "$TEST_ROOT/nft-state/vpn_node_ocserv/chain_forward" ]] ||
    { fail "re-applied table must contain the forward chain"; ok=1; }
  return "$ok"
}

test_render_network_helper_down_absent_table_succeeds() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" down
  if grep -qF 'ARGS: delete' "$TEST_ROOT/nft-args.log" 2>/dev/null; then
    fail "down must not attempt to delete a table that does not exist"
  fi
}

test_render_network_helper_down_deletes_owned_table() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  _seed_owned_table
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" down
  [[ ! -d "$TEST_ROOT/nft-state/vpn_node_ocserv" ]] ||
    fail "down must delete the owned table"
}

test_render_network_helper_down_never_resets_ip_forward() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  _seed_owned_table
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" down
  [[ ! -s "$TEST_ROOT/sysctl-args.log" ]] ||
    fail "down must never modify net.ipv4.ip_forward"
}

test_render_network_helper_check_unowned_table_fails_without_deletion() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  _seed_unowned_table
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_failure "$helper" check
  local ok=0
  [[ -d "$TEST_ROOT/nft-state/vpn_node_ocserv" ]] ||
    { fail "unowned table must not be deleted by check"; ok=1; }
  if grep -qE '^ARGS: (delete|--check|-f )' "$TEST_ROOT/nft-args.log" 2>/dev/null; then
    fail "check must abort before deleting or applying anything when table is unowned"
    ok=1
  fi
  return "$ok"
}

test_render_network_helper_up_unowned_table_fails_without_deletion() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  _seed_unowned_table
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_failure "$helper" up
  local ok=0
  [[ -d "$TEST_ROOT/nft-state/vpn_node_ocserv" ]] ||
    { fail "unowned table must not be deleted by up"; ok=1; }
  [[ -f "$TEST_ROOT/nft-state/vpn_node_ocserv/chain_input" ]] ||
    { fail "unowned table contents must be left untouched by up"; ok=1; }
  [[ ! -s "$TEST_ROOT/sysctl-args.log" ]] ||
    { fail "up must not touch ip_forward when ownership check fails"; ok=1; }
  return "$ok"
}

test_render_network_helper_down_unowned_table_fails_without_deletion() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  _seed_unowned_table
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_failure "$helper" down
  [[ -d "$TEST_ROOT/nft-state/vpn_node_ocserv" ]] ||
    fail "unowned table must not be deleted by down"
}

test_render_network_helper_ownership_verified_before_deletion() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  _seed_owned_table
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" down
  local ok=0
  local chain_check_line delete_line
  chain_check_line="$(grep -nF 'ARGS: list chain ip vpn_node_ocserv _managed_by_vpn_node_maintenance' \
    "$TEST_ROOT/nft-args.log" | head -1 | cut -d: -f1)"
  delete_line="$(grep -nF 'ARGS: delete table ip vpn_node_ocserv' \
    "$TEST_ROOT/nft-args.log" | head -1 | cut -d: -f1)"
  if [[ -z "$chain_check_line" || -z "$delete_line" ]]; then
    fail "expected both a sentinel-chain check and a delete invocation"
    ok=1
  elif ((chain_check_line >= delete_line)); then
    fail "sentinel-chain ownership must be verified before the table is deleted"
    ok=1
  fi
  return "$ok"
}

test_render_network_helper_lock_serializes_concurrent_checks() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  local helper; helper="$(_render_helper)"
  PATH="$TEST_ROOT/bin:$PATH" "$helper" check &
  local pid1=$!
  PATH="$TEST_ROOT/bin:$PATH" "$helper" check &
  local pid2=$!
  wait "$pid1"
  wait "$pid2"
  local ok=0
  if [[ ! -f "$TEST_ROOT/nft-timeline.log" ]]; then
    fail "expected nft-timeline.log to be created by the mocked nft invocations"
    return 1
  fi
  local line_count
  line_count="$(wc -l < "$TEST_ROOT/nft-timeline.log")"
  if ((line_count < 4)); then
    fail "expected at least 4 nft invocations across two concurrent check runs (got $line_count)"
    ok=1
  fi
  local prev_end=0 start end
  while read -r start end; do
    if ((start < prev_end)); then
      fail "nft invocations from concurrent helper runs overlapped; the lock did not serialize them"
      ok=1
    fi
    prev_end="$end"
  done < <(sort -n -k1,1 "$TEST_ROOT/nft-timeline.log")
  return "$ok"
}

# Regression test: earlier drafts hardcoded LOCK_FILE="/run/lock/ocserv-network.lock"
# in the generated helper even when rendering under OCSERV_DEPLOY_ROOT, so
# running the helper under a test root still created/opened the *real* host
# lock file. This asserts both that the lock is rendered under the test
# root and that the real host lock file is never created or touched.
test_render_network_helper_lock_confined_to_root_prefix() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _network_helper_fixture
  local helper; helper="$(_render_helper)"
  local ok=0
  grep -qFx "readonly LOCK_FILE=\"${OCSERV_DEPLOY_ROOT}/run/lock/ocserv-network.lock\"" "$helper" ||
    { fail "rendered LOCK_FILE must be confined under OCSERV_DEPLOY_ROOT in a test root"; ok=1; }
  local real_lock="/run/lock/ocserv-network.lock"
  local before="absent"
  [[ -e "$real_lock" ]] && before="$(stat -c '%Y:%i' "$real_lock")"
  PATH="$TEST_ROOT/bin:$PATH" assert_success "$helper" check || ok=1
  local expected_lock="${OCSERV_DEPLOY_ROOT}/run/lock/ocserv-network.lock"
  [[ -e "$expected_lock" ]] ||
    { fail "expected the lock file to be created under OCSERV_DEPLOY_ROOT: $expected_lock"; ok=1; }
  local after="absent"
  [[ -e "$real_lock" ]] && after="$(stat -c '%Y:%i' "$real_lock")"
  [[ "$before" == "$after" ]] ||
    { fail "helper must never create or touch the real host lock file $real_lock (before=$before after=$after)"; ok=1; }
  return "$ok"
}

# Regression test: when ROOT_PREFIX is empty (no OCSERV_DEPLOY_ROOT, i.e. a
# real production install), the rendered LOCK_FILE must remain byte-for-byte
# identical to the historical hardcoded production path. Sourced in a
# separate bash process (via env -u) so the readonly ROOT_PREFIX/etc.
# constants are computed fresh without OCSERV_DEPLOY_ROOT in the environment.
test_render_network_helper_lock_file_matches_production_path_when_root_prefix_empty() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  write_config '
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=("8.8.4.4")
OCSERV_CERT_MODE="selfsigned"
'
  local helper="$TEST_ROOT/network-helper-prod"
  env -u OCSERV_DEPLOY_ROOT bash -c '
    set -Eeuo pipefail
    OCSERV_DEPLOY_SOURCE_ONLY=1 source "$0"
    load_config
    validate_common_config
    render_network_helper "$1"
  ' "$REPO_ROOT/ocserv-deploy.sh" "$helper"
  grep -qFx 'readonly LOCK_FILE="/run/lock/ocserv-network.lock"' "$helper" ||
    fail "production rendering (empty ROOT_PREFIX) must preserve the exact real lock path"
}

# ---------- render_systemd_dropin ----------

test_render_systemd_dropin_contents() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  source_deployer
  local out="$TEST_ROOT/10-network.conf"
  render_systemd_dropin "$out"
  local ok=0
  grep -Fqx "$MANAGED_MARKER" "$out" || { fail "drop-in must start with the managed marker"; ok=1; }
  grep -Fqx 'Wants=network-online.target' "$out" || { fail "missing Wants=network-online.target"; ok=1; }
  grep -Fqx 'After=network-online.target nftables.service' "$out" ||
    { fail "missing After=network-online.target nftables.service"; ok=1; }
  grep -Fqx 'PartOf=nftables.service' "$out" || { fail "missing PartOf=nftables.service"; ok=1; }
  grep -Fqx 'ExecStartPre=/usr/local/libexec/vpn-node/ocserv-network up' "$out" ||
    { fail "missing ExecStartPre for ocserv-network up"; ok=1; }
  grep -Fqx 'ExecStopPost=/usr/local/libexec/vpn-node/ocserv-network down' "$out" ||
    { fail "missing ExecStopPost for ocserv-network down"; ok=1; }
  return "$ok"
}

run_test "network helper output is executable" test_render_network_helper_output_is_executable
run_test "check succeeds when table is absent" test_render_network_helper_check_absent_table_succeeds
run_test "check invokes nft --check without applying" test_render_network_helper_check_invokes_check_only_no_apply
run_test "check does not touch ip_forward" test_render_network_helper_check_does_not_touch_ip_forward
run_test "up succeeds when table is absent" test_render_network_helper_up_absent_table_succeeds
run_test "up sets net.ipv4.ip_forward=1" test_render_network_helper_up_sets_ip_forward
run_test "up rules contain only expected elements" test_render_network_helper_up_rules_contain_expected_elements_only
run_test "forward chain uses policy accept" test_render_network_helper_forward_chain_policy_accept
run_test "no INPUT chain or DROP policy" test_render_network_helper_no_input_chain_or_drop_policy
run_test "table contains sentinel chain" test_render_network_helper_table_contains_sentinel_chain
run_test "uses configured subnet, not hardcoded" test_render_network_helper_uses_configured_subnet_not_hardcoded
run_test "up replaces an owned table" test_render_network_helper_up_replaces_owned_table
run_test "down succeeds when table is absent" test_render_network_helper_down_absent_table_succeeds
run_test "down deletes an owned table" test_render_network_helper_down_deletes_owned_table
run_test "down never resets ip_forward" test_render_network_helper_down_never_resets_ip_forward
run_test "check on unowned table fails without deletion" test_render_network_helper_check_unowned_table_fails_without_deletion
run_test "up on unowned table fails without deletion" test_render_network_helper_up_unowned_table_fails_without_deletion
run_test "down on unowned table fails without deletion" test_render_network_helper_down_unowned_table_fails_without_deletion
run_test "ownership verified before deletion" test_render_network_helper_ownership_verified_before_deletion
run_test "lock serializes concurrent check invocations" test_render_network_helper_lock_serializes_concurrent_checks
run_test "lock file confined to OCSERV_DEPLOY_ROOT, real host lock untouched" test_render_network_helper_lock_confined_to_root_prefix
run_test "lock file matches production path when ROOT_PREFIX is empty" test_render_network_helper_lock_file_matches_production_path_when_root_prefix_empty
run_test "systemd drop-in contents" test_render_systemd_dropin_contents

# ==================== Task 6: Transactional Installer and Service Verification ====================

_write_os_release() {
  local id="$1" version="$2"
  cat >"$TEST_ROOT/os-release" <<EOF
ID=${id}
VERSION_ID="${version}"
EOF
}

# Writes the full set of system-command mocks used by the orchestration
# tests. Every real system command (apt-get, dpkg, systemctl, ss, ip, nft,
# sysctl, ocserv, ocpasswd) is intercepted under $TEST_ROOT/bin so no test
# ever touches real packages, services, sockets, or the host firewall.
_write_orch_mocks() {
  cat >"$TEST_ROOT/bin/apt-get" <<'MOCK_EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*" >> "$TEST_ROOT/apt-get-args.log"
if [[ "$1" == "install" && -f "$TEST_ROOT/ctl/apt_creates_default" ]]; then
  install -d -m 0755 "$OCSERV_DEPLOY_ROOT/etc/ocserv"
  printf 'stock package default\n' > "$OCSERV_DEPLOY_ROOT/etc/ocserv/ocserv.conf"
fi
exit 0
MOCK_EOF

  cat >"$TEST_ROOT/bin/dpkg" <<'MOCK_EOF'
#!/usr/bin/env bash
[[ "$1" == "--print-architecture" ]] && { printf '%s\n' "${MOCK_ARCH:-amd64}"; exit 0; }
exit 0
MOCK_EOF

  cat >"$TEST_ROOT/bin/systemctl" <<'MOCK_EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*" >> "$TEST_ROOT/systemctl-args.log"
ctl="$TEST_ROOT/ctl"
mkdir -p "$ctl"
case "$1" in
  is-active) [[ -f "$ctl/is_active" ]] && exit 0 || exit 1 ;;
  is-enabled) [[ -f "$ctl/is_enabled" ]] && exit 0 || exit 1 ;;
  enable) touch "$ctl/is_enabled"; exit 0 ;;
  disable) rm -f "$ctl/is_enabled"; exit 0 ;;
  restart) [[ -f "$ctl/restart_fail" ]] && exit 1; exit 0 ;;
  stop) exit 0 ;;
  daemon-reload) exit 0 ;;
  *) exit 0 ;;
esac
MOCK_EOF

  cat >"$TEST_ROOT/bin/ss" <<'MOCK_EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*" >> "$TEST_ROOT/ss-args.log"
flags="$2"
if [[ "$flags" == *p* ]]; then
  # Port-availability probe (-ltnp / -lunp): report the port free.
  exit 0
fi
ctl="$TEST_ROOT/ctl"
if [[ "$flags" == *t* && -f "$ctl/no_tcp" ]]; then exit 0; fi
if [[ "$flags" == *u* && -f "$ctl/no_udp" ]]; then exit 0; fi
printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n' "${OCSERV_PORT:-8443}"
exit 0
MOCK_EOF

  cat >"$TEST_ROOT/bin/ip" <<'MOCK_EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"route get"*)
    printf '1.1.1.1 via 172.16.0.1 dev eth0 src 172.16.0.4 uid 0\n    cache\n' ;;
  *"route show"*)
    printf 'default via 172.16.0.1 dev eth0 proto dhcp src 172.16.0.4 metric 100\n'
    printf '172.16.0.0/24 dev eth0 proto kernel scope link src 172.16.0.4 metric 100\n' ;;
  *) : ;;
esac
exit 0
MOCK_EOF

  cat >"$TEST_ROOT/bin/ocserv" <<'MOCK_EOF'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*" >> "$TEST_ROOT/ocserv-args.log"
[[ -f "$TEST_ROOT/ctl/testconfig_fail" ]] && exit 1
exit 0
MOCK_EOF

  _write_mock_sysctl
  _write_mock_nft
  _write_mock_ocpasswd
  chmod +x "$TEST_ROOT/bin/"*
}

# Sets up a fully validated config plus every system-command mock. The
# optional second argument injects extra config lines (e.g. Let's Encrypt
# fields). Leaves PATH pointing at the mock bin and OS_RELEASE_FILE at a
# supported Ubuntu 24.04 fixture.
_orchestration_fixture() {
  local cert_mode="${1:-selfsigned}" extra="${2:-}"
  write_config "
OCSERV_ENDPOINT=\"vpn.example.com\"
OCSERV_PORT=\"8443\"
OCSERV_IPV4_NETWORK=\"10.66.0.0/24\"
OCSERV_DNS=(\"8.8.4.4\")
OCSERV_CERT_MODE=\"${cert_mode}\"
${extra}
"
  source_deployer
  load_config
  validate_common_config
  _write_orch_mocks
  _write_os_release ubuntu 24.04
  mkdir -p "$TEST_ROOT/ctl"
  OS_RELEASE_FILE="$TEST_ROOT/os-release"
  export PATH="$TEST_ROOT/bin:$PATH"
}

_seed_prior_managed_files() {
  install -d -m 0755 "$(dirname "$OCSERV_CONF")"
  printf '%s\nPRIOR-CONF\n' "$MANAGED_MARKER" >"$OCSERV_CONF"
  chmod 0600 "$OCSERV_CONF"
  install -d -m 0755 "$(dirname "$NETWORK_HELPER")"
  printf '%s\nPRIOR-HELPER\n' "$MANAGED_MARKER" >"$NETWORK_HELPER"
  chmod 0755 "$NETWORK_HELPER"
  install -d -m 0755 "$(dirname "$SYSTEMD_DROPIN")"
  printf '%s\nPRIOR-DROPIN\n' "$MANAGED_MARKER" >"$SYSTEMD_DROPIN"
  chmod 0644 "$SYSTEMD_DROPIN"
}

# ---------- platform and dependency installation ----------

test_install_dependencies_supported_platform_succeeds() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  assert_success install_dependencies
}

test_install_dependencies_installs_exact_packages() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  install_dependencies
  local ok=0
  grep -qFx 'ARGS: update' "$TEST_ROOT/apt-get-args.log" ||
    { fail "apt-get update must run"; ok=1; }
  grep -qFx 'ARGS: install -y --no-install-recommends ocserv nftables openssl iproute2 util-linux' \
    "$TEST_ROOT/apt-get-args.log" ||
    { fail "dependencies must be exactly ocserv nftables openssl iproute2 util-linux"; ok=1; }
  return "$ok"
}

test_install_dependencies_unsupported_id_fails_before_apt() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  _write_os_release debian 12
  assert_failure install_dependencies
  [[ ! -f "$TEST_ROOT/apt-get-args.log" ]] ||
    fail "apt-get must not run for an unsupported OS ID"
}

test_install_dependencies_unsupported_version_fails_before_apt() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  _write_os_release ubuntu 20.04
  assert_failure install_dependencies
  [[ ! -f "$TEST_ROOT/apt-get-args.log" ]] ||
    fail "apt-get must not run for an unsupported Ubuntu version"
}

test_install_dependencies_unsupported_arch_fails_before_apt() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  export MOCK_ARCH="armhf"
  local rc=0
  assert_failure install_dependencies || rc=1
  unset MOCK_ARCH
  [[ ! -f "$TEST_ROOT/apt-get-args.log" ]] ||
    { fail "apt-get must not run for an unsupported architecture"; rc=1; }
  return "$rc"
}

# ---------- install lock ----------

test_install_lock_rejects_concurrent_runs() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  install -d -m 0755 "$(dirname "$INSTALL_LOCK")"
  exec 8>"$INSTALL_LOCK"
  flock -n 8 || { fail "test harness could not acquire the install lock"; return 1; }
  local rc=0
  ( main install ) </dev/null >/dev/null 2>&1 || rc=$?
  exec 8>&-
  ((rc != 0)) || fail "a concurrent install must be rejected while the lock is held"
}

# ---------- staging, validation, and atomic replacement ----------

test_first_install_replaces_package_default() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  touch "$TEST_ROOT/ctl/apt_creates_default"
  touch "$TEST_ROOT/ctl/is_active"
  ( main install ) < <(printf 'vpnuser\nsecretpass\nsecretpass\n') >/dev/null 2>&1 ||
    { fail "install must succeed and replace the package default"; return 1; }
  grep -qF "$MANAGED_MARKER" "$OCSERV_CONF" ||
    fail "the package-created default config must be replaced by the managed config"
}

test_install_validates_staged_config_before_replacement() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  touch "$TEST_ROOT/ctl/is_active"
  ( main install ) < <(printf 'vpnuser\nsecretpass\nsecretpass\n') >/dev/null 2>&1 ||
    { fail "install must succeed"; return 1; }
  grep -qE 'ARGS: -c .*/stage/ocserv\.conf --test-config' "$TEST_ROOT/ocserv-args.log" ||
    fail "ocserv --test-config must validate the STAGED config, not the live file"
}

test_install_empty_db_creates_initial_user() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  touch "$TEST_ROOT/ctl/is_active"
  ( main install ) < <(printf 'vpnuser\nsecretpass\nsecretpass\n') >/dev/null 2>&1 ||
    { fail "install must succeed and create the initial user"; return 1; }
  grep -q '^vpnuser:' "$OCSERV_PASSWD" ||
    fail "the initial user must be created and present in the live password database"
}

test_install_nonempty_db_preserved() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  install -d -m 0755 "$(dirname "$OCSERV_PASSWD")"
  printf 'alice:hash\n' >"$OCSERV_PASSWD"
  chmod 0600 "$OCSERV_PASSWD"
  touch "$TEST_ROOT/ctl/is_active"
  ( main install ) </dev/null >/dev/null 2>&1 ||
    { fail "install must succeed and preserve the existing database"; return 1; }
  local ok=0
  grep -q '^alice:' "$OCSERV_PASSWD" ||
    { fail "the existing VPN user must be preserved"; ok=1; }
  local lines
  lines="$(wc -l <"$OCSERV_PASSWD")"
  ((lines == 1)) ||
    { fail "no additional user must be created for a non-empty database"; ok=1; }
  return "$ok"
}

# ---------- service activation and verification ----------

test_activate_service_order() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  activate_service
  local reload enable restart
  reload="$(grep -nFx 'ARGS: daemon-reload' "$TEST_ROOT/systemctl-args.log" | head -1 | cut -d: -f1)"
  enable="$(grep -nFx 'ARGS: enable ocserv.service' "$TEST_ROOT/systemctl-args.log" | head -1 | cut -d: -f1)"
  restart="$(grep -nFx 'ARGS: restart ocserv.service' "$TEST_ROOT/systemctl-args.log" | head -1 | cut -d: -f1)"
  local ok=0
  [[ -n "$reload" && -n "$enable" && -n "$restart" ]] ||
    { fail "daemon-reload, enable, and restart must all be invoked"; ok=1; }
  if [[ -n "$reload" && -n "$enable" && -n "$restart" ]] &&
     ! ((reload < enable && enable < restart)); then
    fail "activation order must be daemon-reload, enable, then restart"
    ok=1
  fi
  return "$ok"
}

test_verify_service_success() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  touch "$TEST_ROOT/ctl/is_active"
  assert_success verify_service
}

test_verify_service_requires_active() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  assert_failure verify_service
}

test_verify_service_requires_tcp_listener() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  touch "$TEST_ROOT/ctl/is_active"
  touch "$TEST_ROOT/ctl/no_tcp"
  assert_failure verify_service
}

test_verify_service_requires_udp_listener() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  touch "$TEST_ROOT/ctl/is_active"
  touch "$TEST_ROOT/ctl/no_udp"
  assert_failure verify_service
}

# ---------- rollback on failure ----------

_assert_prior_files_restored() {
  local ok=0
  grep -qFx 'PRIOR-CONF' "$OCSERV_CONF" 2>/dev/null ||
    { fail "prior ocserv.conf must be restored on rollback"; ok=1; }
  grep -qFx 'PRIOR-HELPER' "$NETWORK_HELPER" 2>/dev/null ||
    { fail "prior network helper must be restored on rollback"; ok=1; }
  grep -qFx 'PRIOR-DROPIN' "$SYSTEMD_DROPIN" 2>/dev/null ||
    { fail "prior systemd drop-in must be restored on rollback"; ok=1; }
  [[ ! -e "$SELF_SIGNED_CERT" ]] ||
    { fail "a newly created self-signed cert must be removed on rollback"; ok=1; }
  [[ ! -e "$SELF_SIGNED_KEY" ]] ||
    { fail "a newly created self-signed key must be removed on rollback"; ok=1; }
  return "$ok"
}

test_rollback_on_config_check_failure() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  _seed_prior_managed_files
  touch "$TEST_ROOT/ctl/testconfig_fail"
  local rc=0
  ( install_server ) </dev/null >/dev/null 2>&1 || rc=$?
  local ok=0
  ((rc != 0)) || { fail "install_server must fail when the config check fails"; ok=1; }
  _assert_prior_files_restored || ok=1
  return "$ok"
}

test_rollback_on_nft_check_failure() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  _seed_prior_managed_files
  _seed_unowned_table
  local rc=0
  ( install_server ) </dev/null >/dev/null 2>&1 || rc=$?
  local ok=0
  ((rc != 0)) || { fail "install_server must fail when the nft check fails"; ok=1; }
  _assert_prior_files_restored || ok=1
  return "$ok"
}

test_rollback_on_user_creation_failure() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  _seed_prior_managed_files
  cat >"$TEST_ROOT/bin/ocpasswd" <<'MOCK_EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 1
MOCK_EOF
  chmod +x "$TEST_ROOT/bin/ocpasswd"
  local rc=0
  ( install_server ) < <(printf 'newuser\nsecret\nsecret\n') >/dev/null 2>&1 || rc=$?
  local ok=0
  ((rc != 0)) || { fail "install_server must fail when initial-user creation fails"; ok=1; }
  _assert_prior_files_restored || ok=1
  [[ ! -e "$OCSERV_PASSWD" ]] ||
    { fail "no live password database must be created when user creation fails"; ok=1; }
  return "$ok"
}

test_rollback_on_restart_failure() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  _seed_prior_managed_files
  install -d -m 0755 "$(dirname "$OCSERV_PASSWD")"
  printf 'alice:hash\n' >"$OCSERV_PASSWD"
  chmod 0600 "$OCSERV_PASSWD"
  touch "$TEST_ROOT/ctl/restart_fail"
  local rc=0
  ( install_server ) </dev/null >/dev/null 2>&1 || rc=$?
  local ok=0
  ((rc != 0)) || { fail "install_server must fail when restart fails"; ok=1; }
  _assert_prior_files_restored || ok=1
  grep -q '^alice:' "$OCSERV_PASSWD" ||
    { fail "the prior password database must be restored after a restart failure"; ok=1; }
  return "$ok"
}

test_rollback_on_inactive_service() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  _seed_prior_managed_files
  install -d -m 0755 "$(dirname "$OCSERV_PASSWD")"
  printf 'alice:hash\n' >"$OCSERV_PASSWD"
  chmod 0600 "$OCSERV_PASSWD"
  # restart "succeeds" but the service never becomes active (no is_active).
  local rc=0
  ( install_server ) </dev/null >/dev/null 2>&1 || rc=$?
  local ok=0
  ((rc != 0)) || { fail "install_server must fail when the service is not active"; ok=1; }
  _assert_prior_files_restored || ok=1
  return "$ok"
}

test_rollback_on_missing_listener() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  _seed_prior_managed_files
  install -d -m 0755 "$(dirname "$OCSERV_PASSWD")"
  printf 'alice:hash\n' >"$OCSERV_PASSWD"
  chmod 0600 "$OCSERV_PASSWD"
  touch "$TEST_ROOT/ctl/is_active"
  touch "$TEST_ROOT/ctl/no_udp"
  local rc=0
  ( install_server ) </dev/null >/dev/null 2>&1 || rc=$?
  local ok=0
  ((rc != 0)) || { fail "install_server must fail when a listener is missing"; ok=1; }
  _assert_prior_files_restored || ok=1
  return "$ok"
}

test_rollback_on_int_signal() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  _seed_prior_managed_files
  local rc=0
  (
    set -Eeuo pipefail
    begin_transaction
    snapshot_target "$OCSERV_CONF"
    snapshot_target "$SELF_SIGNED_CERT"
    install -d -m 0700 "$(dirname "$SELF_SIGNED_CERT")"
    printf 'NEW-CERT\n' >"$SELF_SIGNED_CERT"
    kill -INT "$BASHPID"
    sleep 5
  ) >/dev/null 2>&1 || rc=$?
  local ok=0
  ((rc == 130)) || { fail "INT must trigger rollback and exit 130 (got $rc)"; ok=1; }
  grep -qFx 'PRIOR-CONF' "$OCSERV_CONF" ||
    { fail "INT rollback must restore the prior config"; ok=1; }
  [[ ! -e "$SELF_SIGNED_CERT" ]] ||
    { fail "INT rollback must remove a newly created file"; ok=1; }
  return "$ok"
}

test_rollback_on_term_signal() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  _seed_prior_managed_files
  local rc=0
  (
    set -Eeuo pipefail
    begin_transaction
    snapshot_target "$OCSERV_CONF"
    snapshot_target "$SELF_SIGNED_CERT"
    install -d -m 0700 "$(dirname "$SELF_SIGNED_CERT")"
    printf 'NEW-CERT\n' >"$SELF_SIGNED_CERT"
    kill -TERM "$BASHPID"
    sleep 5
  ) >/dev/null 2>&1 || rc=$?
  local ok=0
  ((rc == 143)) || { fail "TERM must trigger rollback and exit 143 (got $rc)"; ok=1; }
  grep -qFx 'PRIOR-CONF' "$OCSERV_CONF" ||
    { fail "TERM rollback must restore the prior config"; ok=1; }
  [[ ! -e "$SELF_SIGNED_CERT" ]] ||
    { fail "TERM rollback must remove a newly created file"; ok=1; }
  return "$ok"
}

test_rollback_restores_inactive_disabled_state() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  _seed_prior_managed_files
  # Prior state: service inactive and disabled (no is_active/is_enabled).
  touch "$TEST_ROOT/ctl/testconfig_fail"
  local rc=0
  ( install_server ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc != 0)) || { fail "install_server must fail"; return 1; }
  local ok=0
  grep -qFx 'ARGS: disable ocserv.service' "$TEST_ROOT/systemctl-args.log" ||
    { fail "rollback must restore the previously disabled state"; ok=1; }
  grep -qFx 'ARGS: stop ocserv.service' "$TEST_ROOT/systemctl-args.log" ||
    { fail "rollback must stop the previously inactive service"; ok=1; }
  return "$ok"
}

test_rollback_restores_active_enabled_state() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  _seed_prior_managed_files
  # Prior state: service active and enabled.
  touch "$TEST_ROOT/ctl/is_active"
  touch "$TEST_ROOT/ctl/is_enabled"
  touch "$TEST_ROOT/ctl/testconfig_fail"
  local rc=0
  ( install_server ) </dev/null >/dev/null 2>&1 || rc=$?
  ((rc != 0)) || { fail "install_server must fail"; return 1; }
  local ok=0
  grep -qFx 'ARGS: enable ocserv.service' "$TEST_ROOT/systemctl-args.log" ||
    { fail "rollback must restore the previously enabled state"; ok=1; }
  grep -qFx 'ARGS: restart ocserv.service' "$TEST_ROOT/systemctl-args.log" ||
    { fail "rollback must restart the previously active service"; ok=1; }
  return "$ok"
}

# ---------- certificate hook behaviour ----------

test_selfsigned_install_creates_no_hook() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  touch "$TEST_ROOT/ctl/is_active"
  ( main install ) < <(printf 'vpnuser\nsecretpass\nsecretpass\n') >/dev/null 2>&1 ||
    { fail "self-signed install must succeed"; return 1; }
  [[ ! -e "$CERT_HOOK" ]] ||
    fail "self-signed install must not create a Certbot deploy hook"
}

test_letsencrypt_install_creates_managed_hook() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture letsencrypt \
    "$(printf 'CERT_NAME="vpn.example.com"\nLE_CONFIG_DIR="%s/etc/letsencrypt"' "$OCSERV_DEPLOY_ROOT")"
  local live="$OCSERV_DEPLOY_ROOT/etc/letsencrypt/live/vpn.example.com"
  install -d -m 0755 "$live"
  _generate_test_cert vpn.example.com "$live/fullchain.pem" "$live/privkey.pem"
  touch "$TEST_ROOT/ctl/is_active"
  ( main install ) < <(printf 'vpnuser\nsecretpass\nsecretpass\n') >/dev/null 2>&1 ||
    { fail "letsencrypt install must succeed"; return 1; }
  local ok=0
  [[ -f "$CERT_HOOK" ]] || { fail "letsencrypt install must create the deploy hook"; ok=1; }
  [[ -x "$CERT_HOOK" ]] || { fail "the deploy hook must be executable"; ok=1; }
  grep -qF "$MANAGED_MARKER" "$CERT_HOOK" 2>/dev/null ||
    { fail "the deploy hook must carry the management marker"; ok=1; }
  return "$ok"
}

test_switch_le_to_selfsigned_removes_managed_hook() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  install -d -m 0755 "$(dirname "$CERT_HOOK")"
  printf '%s\n# stale managed hook\n' "$MANAGED_MARKER" >"$CERT_HOOK"
  chmod +x "$CERT_HOOK"
  touch "$TEST_ROOT/ctl/is_active"
  ( main install ) < <(printf 'vpnuser\nsecretpass\nsecretpass\n') >/dev/null 2>&1 ||
    { fail "self-signed install must succeed"; return 1; }
  [[ ! -e "$CERT_HOOK" ]] ||
    fail "switching to self-signed must remove the managed Let's Encrypt hook"
}

test_selfsigned_leaves_unmanaged_hook() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  install -d -m 0755 "$(dirname "$CERT_HOOK")"
  printf 'UNMANAGED-HOOK\n' >"$CERT_HOOK"
  chmod +x "$CERT_HOOK"
  touch "$TEST_ROOT/ctl/is_active"
  ( main install ) < <(printf 'vpnuser\nsecretpass\nsecretpass\n') >/dev/null 2>&1 ||
    { fail "self-signed install must succeed"; return 1; }
  local ok=0
  [[ -f "$CERT_HOOK" ]] || { fail "an unmanaged hook must never be deleted"; ok=1; }
  grep -qFx 'UNMANAGED-HOOK' "$CERT_HOOK" 2>/dev/null ||
    { fail "an unmanaged hook must be left byte-for-byte untouched"; ok=1; }
  return "$ok"
}

# ---------- unknown collision safety ----------

test_install_refuses_unmanaged_helper() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  install -d -m 0755 "$(dirname "$NETWORK_HELPER")"
  printf 'UNMANAGED-HELPER\n' >"$NETWORK_HELPER"
  chmod 0755 "$NETWORK_HELPER"
  local rc=0
  ( main install ) < <(printf 'vpnuser\nsecretpass\nsecretpass\n') >/dev/null 2>&1 || rc=$?
  local ok=0
  ((rc != 0)) || { fail "install must refuse an unmanaged network helper"; ok=1; }
  grep -qFx 'UNMANAGED-HELPER' "$NETWORK_HELPER" 2>/dev/null ||
    { fail "the unmanaged network helper must be left untouched"; ok=1; }
  return "$ok"
}

test_install_refuses_unmanaged_dropin() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  install -d -m 0755 "$(dirname "$SYSTEMD_DROPIN")"
  printf 'UNMANAGED-DROPIN\n' >"$SYSTEMD_DROPIN"
  chmod 0644 "$SYSTEMD_DROPIN"
  local rc=0
  ( main install ) < <(printf 'vpnuser\nsecretpass\nsecretpass\n') >/dev/null 2>&1 || rc=$?
  local ok=0
  ((rc != 0)) || { fail "install must refuse an unmanaged systemd drop-in"; ok=1; }
  grep -qFx 'UNMANAGED-DROPIN' "$SYSTEMD_DROPIN" 2>/dev/null ||
    { fail "the unmanaged systemd drop-in must be left untouched"; ok=1; }
  return "$ok"
}

test_install_refuses_unmanaged_hook_in_letsencrypt_mode() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture letsencrypt \
    "$(printf 'CERT_NAME="vpn.example.com"\nLE_CONFIG_DIR="%s/etc/letsencrypt"' "$OCSERV_DEPLOY_ROOT")"
  local live="$OCSERV_DEPLOY_ROOT/etc/letsencrypt/live/vpn.example.com"
  install -d -m 0755 "$live"
  _generate_test_cert vpn.example.com "$live/fullchain.pem" "$live/privkey.pem"
  install -d -m 0755 "$(dirname "$CERT_HOOK")"
  printf 'UNMANAGED-HOOK\n' >"$CERT_HOOK"
  chmod +x "$CERT_HOOK"
  local rc=0
  ( main install ) < <(printf 'vpnuser\nsecretpass\nsecretpass\n') >/dev/null 2>&1 || rc=$?
  local ok=0
  ((rc != 0)) || { fail "letsencrypt install must refuse an unmanaged hook"; ok=1; }
  grep -qFx 'UNMANAGED-HOOK' "$CERT_HOOK" 2>/dev/null ||
    { fail "the unmanaged hook must be left untouched"; ok=1; }
  return "$ok"
}

run_test "supported platform succeeds" test_install_dependencies_supported_platform_succeeds
run_test "dependencies are the exact package set" test_install_dependencies_installs_exact_packages
run_test "unsupported OS ID fails before apt" test_install_dependencies_unsupported_id_fails_before_apt
run_test "unsupported Ubuntu version fails before apt" test_install_dependencies_unsupported_version_fails_before_apt
run_test "unsupported architecture fails before apt" test_install_dependencies_unsupported_arch_fails_before_apt
run_test "install lock rejects concurrent runs" test_install_lock_rejects_concurrent_runs
run_test "first install replaces package default" test_first_install_replaces_package_default
run_test "config validated in staging before replacement" test_install_validates_staged_config_before_replacement
run_test "empty database creates initial user" test_install_empty_db_creates_initial_user
run_test "non-empty database preserved" test_install_nonempty_db_preserved
run_test "activation order is reload/enable/restart" test_activate_service_order
run_test "verify succeeds when active with listeners" test_verify_service_success
run_test "verify requires active service" test_verify_service_requires_active
run_test "verify requires TCP listener" test_verify_service_requires_tcp_listener
run_test "verify requires UDP listener" test_verify_service_requires_udp_listener
run_test "config-check failure rolls back" test_rollback_on_config_check_failure
run_test "nft-check failure rolls back" test_rollback_on_nft_check_failure
run_test "user-creation failure rolls back" test_rollback_on_user_creation_failure
run_test "restart failure rolls back" test_rollback_on_restart_failure
run_test "inactive service rolls back" test_rollback_on_inactive_service
run_test "missing listener rolls back" test_rollback_on_missing_listener
run_test "INT triggers rollback" test_rollback_on_int_signal
run_test "TERM triggers rollback" test_rollback_on_term_signal
run_test "rollback restores inactive/disabled state" test_rollback_restores_inactive_disabled_state
run_test "rollback restores active/enabled state" test_rollback_restores_active_enabled_state
run_test "self-signed creates no hook" test_selfsigned_install_creates_no_hook
run_test "letsencrypt creates managed hook" test_letsencrypt_install_creates_managed_hook
run_test "switch LE to selfsigned removes managed hook" test_switch_le_to_selfsigned_removes_managed_hook
run_test "selfsigned leaves unmanaged hook" test_selfsigned_leaves_unmanaged_hook
run_test "install refuses unmanaged helper" test_install_refuses_unmanaged_helper
run_test "install refuses unmanaged drop-in" test_install_refuses_unmanaged_dropin
run_test "letsencrypt refuses unmanaged hook" test_install_refuses_unmanaged_hook_in_letsencrypt_mode

finish_tests
