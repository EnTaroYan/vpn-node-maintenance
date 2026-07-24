#!/usr/bin/env bash

set -Eeuo pipefail

if ((EUID != 0)); then
  exec sudo --preserve-env=PATH bash "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/tests/testlib.sh"

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
finish_tests
