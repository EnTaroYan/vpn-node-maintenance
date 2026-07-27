# ocserv Readiness and Rollback Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate false listener failures after service restart and remove owned nftables state during rollback.

**Architecture:** Replace the one-shot service/listener check with bounded condition polling. Add a rollback cleanup helper that prefers the currently installed managed network helper and otherwise deletes only a table proven owned by its sentinel chain.

**Tech Stack:** Bash 5, systemd, `ss`, nftables, existing Bash mocks and real-tools validation.

## Global Constraints

- Poll for up to 15 seconds at 200ms intervals.
- Readiness requires active service plus TCP and UDP listeners on `OCSERV_PORT`.
- Return immediately when all conditions are true.
- Timeout emits service/listener diagnostics without masking the original failure.
- Rollback removes only an owned `ip vpn_node_ocserv` table.
- Unknown same-name nftables tables are never deleted.
- Network cleanup failure never prevents file/service restoration.
- No live installation or service/nft mutation during automated tests.
- Follow strict TDD.

---

### Task 1: Readiness Polling and Rollback Network Cleanup

**Files:**
- Modify: `ocserv-deploy.sh`
- Modify: `tests/ocserv-deploy-test.sh`

**Interfaces:**
- Produces: `service_is_ready`, `wait_for_service_ready`, `print_readiness_diagnostics`, `cleanup_owned_network_state`.
- Replaces: one-shot `verify_service`.

- [ ] **Step 1: Add failing readiness tests**

Add command mocks whose state advances per call. Cover:

```text
empty listeners followed by TCP+UDP -> success
ready on first check -> no sleep
TCP absent through timeout -> failure
UDP absent through timeout -> failure
service inactive through timeout -> failure
timeout invokes systemctl status and journalctl diagnostics
```

Use test-only function overrides for the interval/count:

```bash
READINESS_ATTEMPTS=3
READINESS_INTERVAL_SECONDS=0
```

Production defaults remain `75` and `0.2`.

- [ ] **Step 2: Verify RED**

```bash
sudo bash tests/ocserv-deploy-test.sh
```

Expected: delayed-listener test fails because current verification checks once.

- [ ] **Step 3: Implement readiness polling**

Add:

```bash
READINESS_ATTEMPTS="${READINESS_ATTEMPTS:-75}"
READINESS_INTERVAL_SECONDS="${READINESS_INTERVAL_SECONDS:-0.2}"

service_is_ready() {
  systemctl is-active --quiet ocserv.service &&
    [[ -n "$(ss -H -ltn "sport = :${OCSERV_PORT}")" ]] &&
    [[ -n "$(ss -H -lun "sport = :${OCSERV_PORT}")" ]]
}

print_readiness_diagnostics() {
  systemctl status ocserv.service --no-pager -l >&2 || true
  journalctl -u ocserv.service -n 50 --no-pager >&2 || true
}

wait_for_service_ready() {
  local attempt
  for ((attempt=1; attempt<=READINESS_ATTEMPTS; attempt++)); do
    service_is_ready && return 0
    ((attempt < READINESS_ATTEMPTS)) &&
      sleep "$READINESS_INTERVAL_SECONDS"
  done
  print_readiness_diagnostics
  die "ocserv did not become ready on TCP and UDP port ${OCSERV_PORT} within 15 seconds"
}
```

Call `wait_for_service_ready` after `activate_service`.

- [ ] **Step 4: Add failing rollback cleanup tests**

Cover:

```text
managed executable helper -> down called
helper absent -> sentinel table deleted
helper failure -> sentinel fallback deletion
unknown table without sentinel -> not deleted
nft failure -> rollback still restores files/service state
inactive prior service -> no owned table remains after rollback
```

- [ ] **Step 5: Implement owned network cleanup**

`cleanup_owned_network_state`:

1. If `NETWORK_HELPER` is executable and begins with `MANAGED_MARKER`, invoke `down`; success returns.
2. Query sentinel chain using `nft list chain ip vpn_node_ocserv _managed_by_vpn_node_maintenance`.
3. Delete `ip vpn_node_ocserv` only when the sentinel query succeeds.
4. Return nonzero on cleanup failure.

At the beginning of active transaction rollback:

```bash
cleanup_owned_network_state ||
  log "WARNING: could not fully clean ocserv network state during rollback"
```

Continue rollback regardless.

- [ ] **Step 6: Run GREEN verification**

```bash
bash -n ocserv-deploy.sh
bash -n tests/ocserv-deploy-test.sh
sudo bash tests/ocserv-deploy-test.sh
sudo bash tests/ocserv-deploy-test.sh --real-tools
git diff --check
```

Expected: all tests pass and the real host remains inactive with no new config or table changes.

- [ ] **Step 7: Commit**

```bash
git add ocserv-deploy.sh tests/ocserv-deploy-test.sh
git commit -m "Wait for ocserv listeners before verification"
```
