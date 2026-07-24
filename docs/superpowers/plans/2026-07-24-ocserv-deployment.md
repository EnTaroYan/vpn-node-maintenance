# ocserv One-Click Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe, idempotent one-click ocserv installer with configurable TCP/UDP port, password-file authentication, full-tunnel IPv4 NAT, Let's Encrypt or self-signed certificates, user management, and boot-time systemd integration.

**Architecture:** A standalone `ocserv-deploy.sh` owns installation and user management while reusing `/etc/vpn-maintenance.env` as the configuration source. It renders the ocserv configuration, a lifecycle-bound nftables helper, a systemd drop-in, and an optional Certbot deploy hook; generated files carry ownership markers and are installed transactionally. A dependency-free Bash test harness uses temporary paths and mocked system commands to exercise behavior without touching the live host.

**Tech Stack:** Bash 5, Ubuntu 22.04/24.04 packages, ocserv/ocpasswd, systemd, nftables, OpenSSL, iproute2, util-linux/flock, Certbot hooks.

## Global Constraints

- Support Ubuntu 22.04 and 24.04 on `amd64` and `arm64`; install the distribution `ocserv` package rather than compiling.
- Use `ocpasswd` authentication only; passwords must never appear in argv or logs.
- Default endpoint is `vpn.example.com`; endpoint may be a DNS name or IPv4 address.
- Default port is `8443`, used for both TCP/TLS and UDP/DTLS; any free port in `1..65535`, including `443`, is valid.
- Default VPN network is `10.66.0.0/24`; only IPv4 `/24` pools are supported.
- Default client DNS is `8.8.4.4`.
- `OCSERV_CERT_MODE` accepts exactly `letsencrypt` or `selfsigned`.
- Let's Encrypt mode requires an already-issued matching certificate and never invokes Certbot issuance.
- Self-signed mode must work without DDNS, Cloudflare, Certbot, or certificate configuration and must not create a Certbot hook.
- Do not manage INPUT rules or default firewall policy; Azure NSG/cloud firewall remains an external prerequisite.
- Set `net.ipv4.ip_forward=1` at ocserv startup; do not create a persistent sysctl file and do not reset the value on stop.
- Manage only the dedicated `ip vpn_node_ocserv` nftables table, protected by a sentinel chain.
- Do not overwrite unknown ocserv configuration or other unknown generated-file collisions.
- Preserve `/etc/ocserv/ocpasswd` across managed reinstallations.
- Use the management marker `# Managed by vpn-node-maintenance: ocserv-deploy.sh`.
- Use `set -Eeuo pipefail`; `ERR`, `INT`, and `TERM` must enter the same idempotent rollback path once a transaction starts.
- The approved specification is `docs/superpowers/specs/2026-07-24-ocserv-deployment-design.md`.

## File Structure

| Path | Change | Responsibility |
|---|---|---|
| `ocserv-deploy.sh` | Create | Installer, validation, certificate handling, rendering, transaction, service control, and user CLI |
| `tests/testlib.sh` | Create | Minimal assertion runner and fixture helpers |
| `tests/ocserv-deploy-test.sh` | Create | Root-safe unit/integration tests using a temporary filesystem and command mocks |
| `vpn-maintenance.env.example` | Modify | Add documented ocserv defaults and enum |
| `README.md` | Modify | Document installation, modes, generated files, NSG boundary, user commands, and troubleshooting |

Generated runtime files are embedded templates in `ocserv-deploy.sh`; the repository does not require a separate template directory.

---

### Task 1: Configuration Contract and Test Harness

**Files:**
- Create: `ocserv-deploy.sh`
- Create: `tests/testlib.sh`
- Create: `tests/ocserv-deploy-test.sh`
- Modify: `vpn-maintenance.env.example`

**Interfaces:**
- Consumes: `/etc/vpn-maintenance.env` or `VPN_MAINTENANCE_CONFIG`.
- Produces: `load_config`, `validate_common_config`, `valid_ipv4`, `valid_hostname`, `validate_endpoint`, `parse_ipv4_24`, and normalized globals `OCSERV_NETWORK_ADDRESS`, `OCSERV_NETMASK`.

- [ ] **Step 1: Add the test runner and failing configuration tests**

Create `tests/testlib.sh` with this exact public surface:

```bash
#!/usr/bin/env bash

set -Eeuo pipefail

TESTS_RUN=0
TESTS_FAILED=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "$actual" == "$expected" ]] ||
    fail "$message (expected=$expected actual=$actual)"
}

assert_success() {
  "$@" || fail "expected success: $*"
}

assert_failure() {
  if ("$@"); then
    fail "expected failure: $*"
  fi
}

run_test() {
  local name="$1"
  local function_name="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if ("$function_name"); then
    printf 'PASS: %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

finish_tests() {
  printf '%s tests, %s failures\n' "$TESTS_RUN" "$TESTS_FAILED"
  ((TESTS_FAILED == 0))
}
```

Start `tests/ocserv-deploy-test.sh` with root re-exec, temporary cleanup, and these tests:

```bash
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

run_test "valid common config" test_valid_common_config
run_test "invalid port" test_rejects_invalid_port
run_test "self-signed without DDNS" test_selfsigned_does_not_require_ddns_or_certbot_fields
finish_tests
```

- [ ] **Step 2: Run the tests and confirm the missing script fails**

Run:

```bash
sudo bash tests/ocserv-deploy-test.sh
```

Expected: FAIL while sourcing missing `ocserv-deploy.sh`.

- [ ] **Step 3: Implement the script skeleton and validation functions**

Create `ocserv-deploy.sh` with:

```bash
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
```

Failure helpers exit so production cannot continue after invalid input. `assert_failure` executes the tested function in a nested subshell, allowing negative tests to observe the exit without terminating the test case.

- [ ] **Step 4: Add exact defaults to the shared env template**

Append to `vpn-maintenance.env.example`:

```bash
# OpenConnect / ocserv settings.
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=(
  "8.8.4.4"
)

# Allowed values: letsencrypt | selfsigned
OCSERV_CERT_MODE="letsencrypt"
```

- [ ] **Step 5: Run configuration tests**

Run:

```bash
bash -n ocserv-deploy.sh
sudo bash tests/ocserv-deploy-test.sh
```

Expected: syntax succeeds and all three tests pass.

- [ ] **Step 6: Commit the configuration foundation**

```bash
git add ocserv-deploy.sh tests/testlib.sh tests/ocserv-deploy-test.sh vpn-maintenance.env.example
git commit -m "Add ocserv deployment configuration foundation"
```

---

### Task 2: Certificate Modes and Certbot Hook

**Files:**
- Modify: `ocserv-deploy.sh`
- Modify: `tests/ocserv-deploy-test.sh`

**Interfaces:**
- Consumes: normalized config from Task 1.
- Produces: `prepare_certificate`, `validate_certificate_pair`, `certificate_matches_endpoint`, `generate_self_signed_certificate`, `render_certbot_hook`; sets `SERVER_CERT_FILE` and `SERVER_KEY_FILE`.

- [ ] **Step 1: Add failing tests for mode-specific certificate behavior**

Add test cases that:

1. Set `OCSERV_CERT_MODE=selfsigned` with no `CERT_NAME`, `LE_CONFIG_DIR`, DDNS, or Cloudflare fields and assert certificate generation succeeds.
2. Assert an IPv4 endpoint produces `IP Address:104.46.217.92` in `openssl x509 -text`.
3. Assert a DNS endpoint produces `DNS:vpn.example.com`.
4. Assert reusing a matching self-signed pair succeeds.
5. Assert one missing self-signed file fails instead of replacing the pair.
6. Set `OCSERV_CERT_MODE=letsencrypt`, generate a temporary CA-independent self-signed leaf at `${LE_CONFIG_DIR}/live/${CERT_NAME}`, and assert a matching SAN succeeds.
7. Assert missing files, mismatched key, expired certificate, and endpoint mismatch fail.
8. Assert the rendered hook starts with `#!/usr/bin/env bash`, sources the shared env, compares `RENEWED_LINEAGE`, and invokes `systemctl reload ocserv.service`.
9. Assert self-signed mode does not render or create a hook.

Use real OpenSSL in tests:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 \
  -subj "/CN=vpn.example.com" \
  -addext "subjectAltName=DNS:vpn.example.com" \
  -keyout "$key" -out "$cert"
```

Run:

```bash
sudo bash tests/ocserv-deploy-test.sh
```

Expected: new certificate tests fail because functions are undefined.

- [ ] **Step 2: Implement certificate validation**

Add:

```bash
SERVER_CERT_FILE=""
SERVER_KEY_FILE=""

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
  local cert="$1" endpoint="$2"
  if valid_ipv4 "$endpoint"; then
    openssl x509 -in "$cert" -noout -checkip "$endpoint" >/dev/null
  else
    openssl x509 -in "$cert" -noout -checkhost "$endpoint" >/dev/null
  fi
}
```

In `prepare_letsencrypt_certificate`, require only:

```bash
[[ -n "${CERT_NAME:-}" ]] || die "missing CERT_NAME for letsencrypt mode"
LE_CONFIG_DIR="${LE_CONFIG_DIR:-/etc/letsencrypt}"
SERVER_CERT_FILE="${LE_CONFIG_DIR}/live/${CERT_NAME}/fullchain.pem"
SERVER_KEY_FILE="${LE_CONFIG_DIR}/live/${CERT_NAME}/privkey.pem"
```

Do not call `vpn-maintenance.sh`, Certbot, or Cloudflare APIs.

- [ ] **Step 3: Implement self-signed generation and reuse**

Generate into same-directory temporary files, validate, then atomically install:

```bash
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
```

If both final files exist, validate and reuse them. If exactly one exists or SAN mismatches, fail without overwriting.

- [ ] **Step 4: Render a managed Bash Certbot hook**

`render_certbot_hook OUTPUT` must produce:

```bash
#!/usr/bin/env bash
# Managed by vpn-node-maintenance: ocserv-deploy.sh

set -Eeuo pipefail

readonly CONFIG_FILE="${VPN_MAINTENANCE_CONFIG:-/etc/vpn-maintenance.env}"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

readonly CERT_LIVE_DIR="${LE_CONFIG_DIR:-/etc/letsencrypt}/live/${CERT_NAME}"
[[ "${RENEWED_LINEAGE:-}" == "$CERT_LIVE_DIR" ]] || exit 0
systemctl reload ocserv.service
```

In self-signed mode, mark a managed existing hook for transactional deletion. Never delete an unmarked hook.

- [ ] **Step 5: Run certificate tests**

```bash
bash -n ocserv-deploy.sh
sudo bash tests/ocserv-deploy-test.sh
```

Expected: all certificate and Task 1 tests pass.

- [ ] **Step 6: Commit certificate support**

```bash
git add ocserv-deploy.sh tests/ocserv-deploy-test.sh
git commit -m "Add ocserv certificate modes"
```

---

### Task 3: Password-File User Management

**Files:**
- Modify: `ocserv-deploy.sh`
- Modify: `tests/ocserv-deploy-test.sh`

**Interfaces:**
- Consumes: `OCSERV_PASSWD`.
- Produces: `validate_username USERNAME`, `user_exists USERNAME [PASSWORD_FILE]`, `read_confirmed_password`, `set_user_password USERNAME [PASSWORD_FILE]`, `add_user USERNAME [PASSWORD_FILE]`, `delete_user USERNAME [PASSWORD_FILE]`, `ensure_initial_user PASSWORD_FILE`.

- [ ] **Step 1: Add failing user-management tests**

Create a mock `ocpasswd` in the fixture `PATH` that reads two password lines, rejects mismatches, and updates the requested test password file. Add tests for:

- Valid usernames `alice`, `alice.smith`, `alice_test`, and `alice-2`.
- Rejection of empty names, leading `-`, whitespace, slash, colon, and names over 64 characters.
- Password confirmation mismatch.
- Empty password.
- New user creation without password in argv or captured command log.
- Duplicate `add-user` rejection.
- Existing user deletion.
- Missing user deletion rejection.
- Initial-user prompt only when the password file has no users.

Run:

```bash
sudo bash tests/ocserv-deploy-test.sh
```

Expected: new tests fail because user functions and commands are absent.

- [ ] **Step 2: Implement username and database helpers**

Use this exact validation:

```bash
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
```

Every database helper accepts an optional password-file path so installation can populate a staged database before activation. Create the selected database with `install -m 0600 /dev/null` only when absent; never truncate an existing database.

- [ ] **Step 3: Implement hidden password confirmation and ocpasswd piping**

`read_confirmed_password` reads twice with `read -r -s`, rejects empty/mismatch, and stores the result in global `CONFIRMED_PASSWORD`. `set_user_password` resolves `password_file="${2:-$OCSERV_PASSWD}"` and must invoke:

```bash
printf '%s\n%s\n' "$CONFIRMED_PASSWORD" "$CONFIRMED_PASSWORD" |
  ocpasswd -c "$password_file" "$username"
unset CONFIRMED_PASSWORD
```

Do not use `echo`, command arguments, environment variables, or temporary files for the password.

- [ ] **Step 4: Wire `add-user` and `del-user` commands**

Add cases to `main`; both commands load and validate config, require the `ocpasswd` command, and accept an optional username. `add-user` fails if the user exists. `del-user` calls:

```bash
ocpasswd -c "$OCSERV_PASSWD" -d "$username"
```

`ensure_initial_user PASSWORD_FILE` calls `add_user "$username" "$PASSWORD_FILE"` only when `awk -F: 'NF { found=1 } END { exit !found }'` reports that staged database is empty.

- [ ] **Step 5: Run user tests**

```bash
bash -n ocserv-deploy.sh
sudo bash tests/ocserv-deploy-test.sh
```

Expected: all user, certificate, and configuration tests pass.

- [ ] **Step 6: Commit user management**

```bash
git add ocserv-deploy.sh tests/ocserv-deploy-test.sh
git commit -m "Add ocserv password user management"
```

---

### Task 4: Managed ocserv Configuration and Host Conflict Checks

**Files:**
- Modify: `ocserv-deploy.sh`
- Modify: `tests/ocserv-deploy-test.sh`

**Interfaces:**
- Consumes: normalized config and certificate paths.
- Produces: `render_ocserv_config`, `check_existing_config`, `check_port_available`, `check_route_overlap`, `test_ocserv_config`.

- [ ] **Step 1: Add failing renderer and safety tests**

Add tests that assert:

- Rendered config begins with the exact management marker.
- TCP/UDP ports both use `OCSERV_PORT`.
- Authentication points to the effective `OCSERV_PASSWD`.
- Certificate paths match the selected mode.
- Network and mask derive from `OCSERV_IPV4_NETWORK`.
- Every DNS array item renders as its own directive, such as `dns = 8.8.4.4` and `dns = 1.1.1.1`.
- `route = default` is present and compression is not enabled.
- An unknown pre-existing config is copied to `ocserv.conf.pre-vpn-node-<UTC timestamp>.bak` and installation policy fails.
- A marked config is accepted.
- A free port passes; a listener owned by another process fails.
- A managed rerun permits only an ocserv listener on the currently configured port.
- A route overlapping `10.66.0.0/24` fails; unrelated routes pass.
- The config test calls `ocserv -c "$TEMP_CONF" --test-config`.

Run:

```bash
sudo bash tests/ocserv-deploy-test.sh
```

Expected: new tests fail.

- [ ] **Step 2: Implement the ocserv config renderer**

Render compatible Ubuntu 22.04/24.04 directives:

```ini
# Managed by vpn-node-maintenance: ocserv-deploy.sh
auth = "plain[/etc/ocserv/ocpasswd]"
tcp-port = 8443
udp-port = 8443
run-as-user = nobody
run-as-group = daemon
socket-file = /run/ocserv.socket
occtl-socket-file = /run/occtl.socket
server-cert = /path/to/fullchain.pem
server-key = /path/to/privkey.pem
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
ipv4-network = 10.66.0.0
ipv4-netmask = 255.255.255.0
dns = 8.8.4.4
route = default
cisco-client-compat = true
log-level = 1
use-occtl = true
```

Substitute validated values. Use the production path `/etc/ocserv/ocpasswd` in a production config; when `ROOT_PREFIX` is set for tests, use the prefixed path so the mock config checker remains isolated.

- [ ] **Step 3: Implement existing-file ownership and backup policy**

`is_managed_file PATH` checks the exact marker with `grep -Fqx`. At the beginning of install, capture `CONF_EXISTED_BEFORE_INSTALL`. If it existed without the marker:

```bash
backup="${OCSERV_CONF}.pre-vpn-node-$(date -u +%Y%m%dT%H%M%SZ).bak"
cp -a -- "$OCSERV_CONF" "$backup"
die "existing unmanaged ocserv config backed up to $backup; refusing to overwrite"
```

If no config existed before package installation, allow replacement of the package-created default.

- [ ] **Step 4: Implement route and port conflict checks**

For route overlap, use these helpers:

```bash
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
```

Read destinations from `ip -4 route show table main type unicast`; ignore only `default`. Parse every other first field with `cidr_bounds`, then fail when `selected_start <= route_end && route_start <= selected_end`. Malformed route output is an error rather than an assumed non-conflict.

For ports, query both protocols:

```bash
ss -H -ltnp "sport = :${OCSERV_PORT}"
ss -H -lunp "sport = :${OCSERV_PORT}"
```

Any output fails on a new install. On a managed rerun, accept output only if every process annotation identifies `ocserv`; changing to a port held by another process fails.

- [ ] **Step 5: Implement exact temporary config validation**

```bash
test_ocserv_config() {
  local temp_conf="$1"
  ocserv -c "$temp_conf" --test-config
}
```

Never test the installed path before the staged file has passed.

- [ ] **Step 6: Run renderer and host-safety tests**

```bash
bash -n ocserv-deploy.sh
sudo bash tests/ocserv-deploy-test.sh
```

Expected: all tests pass.

- [ ] **Step 7: Commit managed configuration**

```bash
git add ocserv-deploy.sh tests/ocserv-deploy-test.sh
git commit -m "Add managed ocserv configuration"
```

---

### Task 5: nftables Helper and systemd Lifecycle

**Files:**
- Modify: `ocserv-deploy.sh`
- Modify: `tests/ocserv-deploy-test.sh`

**Interfaces:**
- Consumes: `OCSERV_IPV4_NETWORK`.
- Produces: `render_network_helper`, `render_systemd_dropin`; generated helper commands `check`, `up`, `down`.

- [ ] **Step 1: Add failing network-template tests**

Render the helper into a temporary executable and use mocked `ip`, `nft`, and `sysctl`. Assert:

- `check` detects the current default interface and invokes `nft --check` without applying a table.
- `up` executes `sysctl -w net.ipv4.ip_forward=1`.
- Rules contain only `10.66.0.0/24`, the detected egress interface, a masquerade rule, and established/related return traffic.
- No INPUT chain or DROP policy exists.
- The FORWARD base chain uses `policy accept`.
- The actual table contains sentinel chain `_managed_by_vpn_node_maintenance`.
- An absent table succeeds.
- A table with the sentinel is replaced/deleted.
- A table without the sentinel causes `check`, `up`, and `down` to fail without deletion.
- `down` never writes `net.ipv4.ip_forward=0`.
- The systemd drop-in contains `Wants=network-online.target`, `After=network-online.target nftables.service`, `PartOf=nftables.service`, `ExecStartPre=/usr/local/libexec/vpn-node/ocserv-network up`, and `ExecStopPost=/usr/local/libexec/vpn-node/ocserv-network down`.

Run:

```bash
sudo bash tests/ocserv-deploy-test.sh
```

Expected: network tests fail because renderers are undefined.

- [ ] **Step 2: Implement the generated helper command contract**

The generated Bash helper must:

```bash
set -Eeuo pipefail
readonly TABLE_FAMILY="ip"
readonly TABLE_NAME="vpn_node_ocserv"
readonly SENTINEL="_managed_by_vpn_node_maintenance"
readonly VPN_SUBNET="10.66.0.0/24"
readonly LOCK_FILE="/run/lock/ocserv-network.lock"
```

Acquire `flock` for all subcommands. Resolve the interface with:

```bash
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
```

Ownership checks use:

```bash
nft list table ip vpn_node_ocserv
nft list chain ip vpn_node_ocserv _managed_by_vpn_node_maintenance
```

If the table exists but the chain does not, abort.

- [ ] **Step 3: Render and apply the minimal ruleset**

The actual nftables body must be:

```nft
table ip vpn_node_ocserv {
  chain _managed_by_vpn_node_maintenance {
  }

  chain forward {
    type filter hook forward priority filter; policy accept;
    ip saddr 10.66.0.0/24 oifname "eth0" accept
    ip daddr 10.66.0.0/24 iifname "eth0" ct state established,related accept
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr 10.66.0.0/24 oifname "eth0" masquerade
  }
}
```

Substitute only validated subnet and interface values.

For `check`, render the identical chain and rule body under a process-unique, non-applied table name such as `vpn_node_ocserv_check_${BASHPID}` so validation cannot collide with an already-active table; run `nft --check -f "$RULE_FILE"` and do not apply it. The only difference from `up` is this table identifier. For `up`, verify/delete only an owned existing table and apply the actual table using `nft -f`. For `down`, no table is success; an owned table is deleted; an unowned table fails.

- [ ] **Step 4: Render the systemd drop-in**

Generate:

```ini
# Managed by vpn-node-maintenance: ocserv-deploy.sh
[Unit]
Wants=network-online.target
After=network-online.target nftables.service
PartOf=nftables.service

[Service]
ExecStartPre=/usr/local/libexec/vpn-node/ocserv-network up
ExecStopPost=/usr/local/libexec/vpn-node/ocserv-network down
```

Use prefixed paths only in tests.

- [ ] **Step 5: Run network tests**

```bash
bash -n ocserv-deploy.sh
sudo bash tests/ocserv-deploy-test.sh
```

Expected: all tests pass and mocks show no live nftables mutation.

- [ ] **Step 6: Commit lifecycle networking**

```bash
git add ocserv-deploy.sh tests/ocserv-deploy-test.sh
git commit -m "Add ocserv lifecycle NAT rules"
```

---

### Task 6: Transactional Installer and Service Verification

**Files:**
- Modify: `ocserv-deploy.sh`
- Modify: `tests/ocserv-deploy-test.sh`

**Interfaces:**
- Consumes: all renderers and validators from Tasks 1-5.
- Produces: `install_dependencies`, `begin_transaction`, `snapshot_target`, `rollback_transaction`, `commit_transaction`, `install_server`, `verify_service`.

- [ ] **Step 1: Add failing orchestration and rollback tests**

Mock `apt-get`, `systemctl`, `ocserv`, `ss`, `ip`, `nft`, `sysctl`, and `ocpasswd`. Cover:

- Supported OS/architecture succeeds; unsupported ID/version/architecture fails before apt.
- Dependencies are exactly `ocserv nftables openssl iproute2 util-linux`.
- The install lock rejects concurrent runs.
- First install may replace the package-created default only when no config existed before apt.
- All staged files pass validation before replacement.
- Empty database triggers initial-user creation; non-empty database is preserved.
- `systemctl daemon-reload`, `enable ocserv.service`, and `restart ocserv.service` occur in that order.
- Success requires service active plus TCP and UDP listeners.
- Config-check, nft-check, user creation, restart, inactive-service, and missing-listener failures each restore prior files.
- `INT` and `TERM` invoke the same rollback.
- Previous enabled/active state is restored on rollback.
- Self-signed install has no Certbot hook.
- Let's Encrypt install creates a managed executable hook.
- Switching from managed Let's Encrypt to self-signed removes only the managed hook.
- Unknown helper/drop-in/hook collisions are never overwritten or deleted.

Run:

```bash
sudo bash tests/ocserv-deploy-test.sh
```

Expected: orchestration tests fail.

- [ ] **Step 2: Implement OS checks and dependency installation**

Read `/etc/os-release` through an overridable `OS_RELEASE_FILE`, require `ID=ubuntu` and `VERSION_ID` in `22.04|24.04`, and require `dpkg --print-architecture` in `amd64|arm64`.

Install:

```bash
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ocserv nftables openssl iproute2 util-linux
```

Packages remain installed if a later step fails.

- [ ] **Step 3: Implement fixed-target snapshots and rollback**

Use a root-only transaction directory under `/run`. Snapshot only these known targets:

```text
/etc/ocserv/ocserv.conf
/etc/ocserv/ocpasswd
/etc/ocserv/ssl/selfsigned-cert.pem
/etc/ocserv/ssl/selfsigned-key.pem
/usr/local/libexec/vpn-node/ocserv-network
/etc/systemd/system/ocserv.service.d/10-network.conf
/etc/letsencrypt/renewal-hooks/deploy/20-ocserv
```

Record existence and mode for each path. Rollback restores existing snapshots and removes only newly created files at those exact paths. Track:

```bash
TRANSACTION_ACTIVE=0
ROLLBACK_RUNNING=0
SERVICE_WAS_ACTIVE=0
SERVICE_WAS_ENABLED=0
```

The rollback function must be idempotent and guarded against recursive traps. Once transactions exist, update `die` to call `rollback_transaction 1` when `TRANSACTION_ACTIVE=1` before exiting. Install:

```bash
trap 'rollback_transaction $?' ERR
trap 'rollback_transaction 130' INT
trap 'rollback_transaction 143' TERM
```

After file restoration, run `systemctl daemon-reload`, restore enabled state, and either restart the previously active service or stop the previously inactive one.

- [ ] **Step 4: Implement staging and the deferred atomic-install mechanism**

Render every managed file into the transaction directory. Copy an existing password database into the transaction directory, or create an empty staged database with mode `0600`. Run:

```bash
ocserv -c "$STAGED_OCSERV_CONF" --test-config
"$STAGED_NETWORK_HELPER" check
```

Implement `install_staged_files`, but do not call it in this step's render/validation phase. It installs these exact modes only after Step 6 has successfully created the initial user in the staged password database:

```text
ocserv.conf                                  0600
ocpasswd                                    0600
ocserv-network                              0755
10-network.conf                             0644
20-ocserv                                   0755
selfsigned-key.pem                          0600
selfsigned-cert.pem                         0644
```

Use `install -D` and same-filesystem temporary targets followed by `mv` for configuration files. Never recursively copy or delete `/etc/ocserv` or `/etc/letsencrypt`.

- [ ] **Step 5: Implement service activation and verification**

Activation:

```bash
systemctl daemon-reload
systemctl enable ocserv.service
systemctl restart ocserv.service
```

Verification:

```bash
systemctl is-active --quiet ocserv.service
ss -H -ltn "sport = :${OCSERV_PORT}"
ss -H -lun "sport = :${OCSERV_PORT}"
```

Only after all checks succeed, disable transaction traps, remove the transaction directory, and print:

```text
OpenConnect endpoint: vpn.example.com:8443
Azure NSG required: allow TCP 8443 and UDP 8443
Certificate mode: letsencrypt|selfsigned
```

For self-signed mode also print the SHA-256 certificate fingerprint and `pin-sha256` public-key pin.

- [ ] **Step 6: Wire the `install` command and lock**

`main install` creates the lock parent, acquires:

```bash
exec 9>"$INSTALL_LOCK"
flock -n 9 || die "another installation is running"
```

Then call, in order: preflight ownership/config checks, host conflict checks, dependency installation, certificate preparation, staging, config/network validation, initial user creation in the staged password database, `install_staged_files`, service activation, and verification. No staged config/helper/drop-in/hook becomes live before initial-user creation succeeds.

- [ ] **Step 7: Run the complete automated suite**

```bash
bash -n ocserv-deploy.sh
sudo bash tests/ocserv-deploy-test.sh
git diff --check
```

Expected: all tests pass with zero modifications outside the temporary fixture.

- [ ] **Step 8: Commit the installer**

```bash
git add ocserv-deploy.sh tests/ocserv-deploy-test.sh
git commit -m "Implement transactional ocserv deployment"
```

---

### Task 7: Documentation and Target-System Validation

**Files:**
- Modify: `README.md`
- Modify: `tests/ocserv-deploy-test.sh` only if target validation exposes a reproducible missing assertion

**Interfaces:**
- Consumes: completed installer.
- Produces: operator-facing installation and verification procedure.

- [ ] **Step 1: Add README installation documentation**

Document:

- Supported Ubuntu versions and architecture.
- The five new env settings with exact defaults.
- `letsencrypt` mode prerequisites and the fact that missing cert files abort.
- `selfsigned` mode independence from DDNS/Cloudflare/Certbot and absence of a hook.
- DNS vs bare-IP endpoint certificate behavior.
- `install`, `add-user`, and `del-user` commands.
- Generated-file paths and management-marker behavior.
- Full-tunnel/NAT behavior and the fact that no INPUT firewall policy is installed.
- Azure NSG requirement for both TCP and UDP.
- Boot behavior through `ocserv.service`.
- `systemctl`, `journalctl`, `ss`, `nft`, and `occtl` troubleshooting commands.
- SoftEther coexistence: reserve a different port/address pool/table.

- [ ] **Step 2: Run all non-destructive validation**

On the Ubuntu 24.04 ARM64 target:

```bash
bash -n ocserv-deploy.sh
sudo bash tests/ocserv-deploy-test.sh
git diff --check
certbot --version
apt-cache policy ocserv nftables
```

Expected: tests pass; packages are available for `arm64`.

- [ ] **Step 3: Run a real staged config check**

Install runtime packages if absent, without invoking the installer:

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ocserv nftables openssl iproute2 util-linux
```

Add a `--real-tools` mode to `tests/ocserv-deploy-test.sh`. It creates a temporary self-signed certificate and rendered config/helper, uses real `ocserv`, `nft`, and `ip` while retaining prefixed temporary paths, then runs:

```bash
sudo bash tests/ocserv-deploy-test.sh --real-tools
```

Expected: both commands exit zero and do not start ocserv or apply nftables rules.

- [ ] **Step 4: Perform live installation only with confirmed operator configuration**

Confirm `/etc/vpn-maintenance.env` contains the intended endpoint, port, network, DNS, and certificate mode, and that Azure NSG allows both protocols. Then run:

```bash
sudo ./ocserv-deploy.sh install
systemctl is-enabled ocserv.service
systemctl is-active ocserv.service
OCSERV_PORT="$(
  sudo bash -c 'source /etc/vpn-maintenance.env; printf "%s\n" "$OCSERV_PORT"'
)"
sudo ss -lntup | grep -E ":${OCSERV_PORT}([[:space:]]|$)"
sudo nft list table ip vpn_node_ocserv
```

Expected: service enabled/active; TCP and UDP listeners present; dedicated table contains the sentinel chain, forward rules, and masquerade.

- [ ] **Step 5: Validate from a separate OpenConnect client**

For a trusted Let's Encrypt certificate:

```bash
sudo openconnect --protocol=anyconnect \
  "https://vpn.example.com:8443"
```

For self-signed mode, use the printed public-key pin:

```bash
read -r -p "Paste the complete pin-sha256 value printed by the installer: " SERVER_PIN
[[ "$SERVER_PIN" == pin-sha256:* ]]
sudo openconnect --protocol=anyconnect \
  --servercert "$SERVER_PIN" \
  "https://vpn.example.com:8443"
```

After connection:

```bash
curl -4 https://cloudflare.com/cdn-cgi/trace
```

Expected: authentication succeeds, DNS resolves, and the reported public IP is the VPN server's current public IPv4.

- [ ] **Step 6: Validate boot and renewal behavior**

After an approved maintenance reboot:

```bash
systemctl is-active ocserv.service
sudo nft list chain ip vpn_node_ocserv _managed_by_vpn_node_maintenance
```

For Let's Encrypt mode:

```bash
sudo bash -c '
  source /etc/vpn-maintenance.env
  export RENEWED_LINEAGE="${LE_CONFIG_DIR:-/etc/letsencrypt}/live/${CERT_NAME}"
  exec /etc/letsencrypt/renewal-hooks/deploy/20-ocserv
'
```

Expected: service remains active, the dedicated table returns after boot, and the deploy hook exits zero via `systemctl reload`.

- [ ] **Step 7: Commit documentation**

```bash
git add README.md
git commit -m "Document ocserv one-click deployment"
```

- [ ] **Step 8: Request final code review before merge**

Run a read-only review against the implementation commits, address only high-confidence correctness or security findings, rerun the full test suite, and push the final branch.
