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
run_test "route overlap conflict fails" test_check_route_overlap_conflict_fails
run_test "route overlap unrelated route passes" test_check_route_overlap_unrelated_passes
run_test "test_ocserv_config invokes ocserv --test-config" test_test_ocserv_config_invokes_test_config

finish_tests
