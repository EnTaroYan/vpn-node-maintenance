# Platform Gate Removal and README Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all hardcoded OS/version/CPU platform gates from the ocserv installer and replace the long README with a concise optional-DDNS → optional-certificate → OpenConnect → SoftEther-placeholder workflow.

**Architecture:** `install_dependencies` will gate only on the concrete package-manager command it invokes, then let apt and `ocserv --test-config` report real compatibility failures. README remains the single quick-start entry point, while detailed implementation rationale stays in existing `docs/superpowers/` documents.

**Tech Stack:** Bash 5, apt, ocserv, nftables, OpenSSL, systemd, existing Bash test harness.

## Global Constraints

- Do not inspect or reject `/etc/os-release`, distro ID, distro version, or CPU architecture.
- Keep the exact dependency install command for `ocserv nftables openssl iproute2 util-linux`.
- Fail explicitly when `apt-get` is unavailable; do not add adapters for non-apt package managers.
- Do not change DDNS, certificate, ocserv, nftables, systemd, transaction, or user-management behavior.
- README states only that Ubuntu `amd64` and `arm64` were tested; other apt/systemd platforms are unverified.
- README workflow order is: preparation → DDNS (optional) → Let's Encrypt (optional) → OpenConnect/ocserv → SoftEther placeholder.
- README explicitly says both DDNS and Let's Encrypt may be skipped; `selfsigned` permits direct ocserv deployment.
- Keep README concise; detailed hook/network/rollback design remains under `docs/superpowers/`.
- Follow strict TDD for installer behavior changes.

## File Structure

| Path | Change | Responsibility |
|---|---|---|
| `ocserv-deploy.sh` | Modify | Remove platform detection and retain concrete apt dependency installation |
| `tests/ocserv-deploy-test.sh` | Modify | Replace platform whitelist tests/fixtures with platform-agnostic dependency tests |
| `README.md` | Rewrite | Concise ordered deployment guide |

---

### Task 1: Remove Platform Gates

**Files:**
- Modify: `ocserv-deploy.sh`
- Modify: `tests/ocserv-deploy-test.sh`

**Interfaces:**
- Consumes: existing `install_dependencies`.
- Produces: platform-agnostic `install_dependencies` that requires `apt-get` and invokes the unchanged apt commands.

- [ ] **Step 1: Write the failing platform-agnostic test**

Replace the Ubuntu whitelist tests with:

```bash
test_install_dependencies_does_not_gate_platform_metadata() {
  new_fixture
  trap 'rm -rf -- "$TEST_ROOT"' EXIT
  _orchestration_fixture selfsigned
  OS_RELEASE_FILE="$TEST_ROOT/does-not-exist"
  assert_success install_dependencies
  grep -qFx 'ARGS: update' "$TEST_ROOT/apt-get-args.log" ||
    fail "apt-get update must run without OS metadata"
  grep -qFx \
    'ARGS: install -y --no-install-recommends ocserv nftables openssl iproute2 util-linux' \
    "$TEST_ROOT/apt-get-args.log" ||
    fail "dependency install arguments changed"
}
```

Delete both the function bodies and `run_test` registrations for:

- `test_install_dependencies_supported_platform_succeeds`
- `test_install_dependencies_unsupported_id_fails_before_apt`
- `test_install_dependencies_unsupported_version_fails_before_apt`
- `test_install_dependencies_unsupported_arch_fails_before_apt`

Register the new test under `install dependencies ignores platform metadata`.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
sudo bash tests/ocserv-deploy-test.sh
```

Expected: the new test fails because current `check_supported_platform` rejects the missing os-release file before apt runs.

- [ ] **Step 3: Remove platform-specific production code**

Delete:

```bash
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
```

Delete `_os_release_field` and `check_supported_platform` entirely.

Change `install_dependencies` to:

```bash
install_dependencies() {
  command -v apt-get >/dev/null 2>&1 ||
    die "required command not found: apt-get"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ocserv nftables openssl iproute2 util-linux
}
```

- [ ] **Step 4: Remove obsolete test fixtures**

Delete `_write_os_release`, the mock `dpkg` executable, `MOCK_ARCH`, and assignments to `OS_RELEASE_FILE`. Update `_orchestration_fixture` comments so it promises command mocks and valid shared configuration, not Ubuntu metadata.

The `OS_RELEASE_FILE="$TEST_ROOT/does-not-exist"` line added in Step 1 is a RED-only sentinel proving the old gate executes. Remove that sentinel after deleting the production gate, rename the final test to `test_install_dependencies_uses_apt_directly`, and register it as `install dependencies uses apt directly`. Its lasting assertions are the exact `apt-get update` and dependency-install calls; the zero-match source scan below proves no platform probe remains.

Search:

```bash
grep -R -n -E \
  'OS_RELEASE_FILE|_os_release_field|check_supported_platform|_write_os_release|MOCK_ARCH|print-architecture' \
  ocserv-deploy.sh tests/ocserv-deploy-test.sh
```

Expected: no matches.

- [ ] **Step 5: Run GREEN and regression validation**

```bash
bash -n ocserv-deploy.sh
bash -n tests/ocserv-deploy-test.sh
sudo bash tests/ocserv-deploy-test.sh
sudo bash tests/ocserv-deploy-test.sh --real-tools
git diff --check
```

Expected: syntax passes, complete mock suite reports zero failures, real-tools reports zero failures, and diff check is clean.

- [ ] **Step 6: Commit platform-gate removal**

```bash
git add ocserv-deploy.sh tests/ocserv-deploy-test.sh
git commit -m "Remove ocserv platform whitelist"
```

---

### Task 2: Rewrite README as the Four-Step Quick Start

**Files:**
- Rewrite: `README.md`

**Interfaces:**
- Consumes: existing script commands and env names.
- Produces: concise operator workflow with no change to runtime code.

- [ ] **Step 1: Replace README structure**

Use exactly these top-level headings:

```text
# VPN Node Maintenance
## 已测试环境
## 文件
## 准备
## 1. DDNS（可选）
## 2. Let's Encrypt 证书（可选）
## 3. OpenConnect / ocserv 部署
## 4. SoftEther 部署
## 状态检查
## 安全提醒
```

`已测试环境` states:

```text
本项目仅在 Ubuntu amd64 和 arm64 上完成测试。其他提供 apt、systemd、
ocserv 和 nftables 的平台可能兼容，但未经过验证；脚本不会按发行版、
版本或 CPU 架构提前拒绝安装。
```

- [ ] **Step 2: Write preparation and optional DDNS steps**

`准备` contains only:

```bash
sudo install -m 0755 vpn-maintenance.sh /usr/local/sbin/vpn-maintenance.sh
sudo install -m 0644 vpn-ddns.service vpn-ddns.timer /etc/systemd/system/
sudo install -m 0600 vpn-maintenance.env.example /etc/vpn-maintenance.env
sudo -e /etc/vpn-maintenance.env
```

State that old env files must be incrementally updated rather than overwritten.

DDNS section labels itself optional, explains it is needed only for dynamic public IP plus domain tracking, shows only `CF_DDNS_API_TOKEN`, `CF_ZONE_ID`, `CF_RECORD_NAMES`, and:

```bash
sudo apt update
sudo apt install -y curl jq
sudo /usr/local/sbin/vpn-maintenance.sh ddns
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-ddns.timer
```

- [ ] **Step 3: Write optional certificate step**

State that this step is optional and skipped for `OCSERV_CERT_MODE="selfsigned"`. Show only:

```bash
CERT_NAME="example.com"
CERT_DOMAINS=(
  "*.example.com"
)
LE_EMAIL="admin@example.com"
CF_DNS_CREDENTIALS_FILE="/etc/letsencrypt/cloudflare-acme.ini"
LE_CONFIG_DIR="/etc/letsencrypt"
```

Then:

```bash
sudo apt install -y certbot python3-certbot-dns-cloudflare
sudo install -d -m 0700 /etc/letsencrypt
sudo -e /etc/letsencrypt/cloudflare-acme.ini
sudo chmod 600 /etc/letsencrypt/cloudflare-acme.ini
sudo /usr/local/sbin/vpn-maintenance.sh issue-cert
sudo systemctl enable --now certbot.timer
```

Include the credentials-file line:

```ini
dns_cloudflare_api_token = ACME_API_TOKEN
```

- [ ] **Step 4: Write OpenConnect and SoftEther steps**

OpenConnect shows exactly the five config fields:

```bash
OCSERV_ENDPOINT="vpn.example.com"
OCSERV_PORT="8443"
OCSERV_IPV4_NETWORK="10.66.0.0/24"
OCSERV_DNS=(
  "8.8.4.4"
)
# letsencrypt | selfsigned
OCSERV_CERT_MODE="letsencrypt"
```

Then:

```bash
sudo ./ocserv-deploy.sh install
sudo ./ocserv-deploy.sh add-user USERNAME
sudo ./ocserv-deploy.sh del-user USERNAME
```

State that Azure/cloud firewall must allow both TCP and UDP for `OCSERV_PORT`. State that skipping both optional steps is valid when using a fixed IP/domain plus self-signed mode.

SoftEther section contains only:

```text
SoftEther 自动部署脚本尚未实现。计划使用 443，并与 ocserv 使用不同端口、
地址池和 nftables 表。
```

- [ ] **Step 5: Add minimal status and security sections**

Status commands:

```bash
systemctl status vpn-ddns.timer certbot.timer ocserv.service
journalctl -u vpn-ddns.service -u ocserv.service -e
sudo ss -H -ltnp "sport = :8443"
sudo ss -H -lunp "sport = :8443"
sudo nft list table ip vpn_node_ocserv
```

Security reminders are limited to:

- Cloudflare records are DNS-only.
- Token/env/key/password files remain root-only and never enter Git.
- Self-signed clients use the printed `pin-sha256`.
- DDNS and certificate success do not prove Azure inbound ports are open.

Keep `README.md` below 220 lines.

- [ ] **Step 6: Validate documentation against code**

```bash
grep -n '^## ' README.md
wc -l README.md
grep -n -E 'Ubuntu 22\\.04|Ubuntu 24\\.04|requires 22|unsupported Ubuntu' \
  README.md ocserv-deploy.sh
bash -n ocserv-deploy.sh
sudo bash tests/ocserv-deploy-test.sh
sudo bash tests/ocserv-deploy-test.sh --real-tools
git diff --check
```

Expected:

- headings appear in the specified order;
- README has fewer than 220 lines;
- no hardcoded Ubuntu version requirement remains;
- test suites report zero failures.

- [ ] **Step 7: Commit README rewrite**

```bash
git add README.md
git commit -m "Simplify VPN deployment guide"
```
