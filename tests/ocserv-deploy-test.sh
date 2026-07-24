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
