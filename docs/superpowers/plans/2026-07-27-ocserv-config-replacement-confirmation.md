# ocserv Existing-Config Replacement Confirmation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace management-marker rejection for an existing `ocserv.conf` with mandatory interactive confirmation, collision-safe backup, and transactional overwrite.

**Architecture:** `install` checks the exact config path before host checks or package installation. A small confirmation unit requires a TTY and `y|Y`, creates a permanent `cp -a` backup, then lets the existing transaction snapshot and atomically replace the original; helper/drop-in/hook ownership protections remain unchanged.

**Tech Stack:** Bash 5, existing Bash test harness, systemd/nftables/ocserv mocks.

## Global Constraints

- Prompt for every existing `/etc/ocserv/ocserv.conf`, managed or unmanaged.
- Accept only `y` or `Y`; all other input, EOF, read failure, and non-TTY stdin abort.
- Refusal happens before apt, certificate generation, transaction start, or any managed-file mutation.
- Create a permanent `cp -a` backup before continuing.
- Backup name starts with `ocserv.conf.pre-vpn-node-<UTC timestamp>` and never overwrites an existing backup; append `.1`, `.2`, and so on before `.bak`.
- Do not remove the original before the existing atomic replacement runs.
- Later failure restores the original config/service state; the permanent confirmation backup remains.
- Existing unmanaged helper, systemd drop-in, and Certbot hook protections remain unchanged.
- Existing password database behavior remains unchanged.
- Do not add `--force`, environment auto-confirmation, or noninteractive bypass.
- Follow strict TDD.

## Files

| Path | Change |
|---|---|
| `ocserv-deploy.sh` | Replace config ownership check with interactive confirmation and backup |
| `tests/ocserv-deploy-test.sh` | Add confirmation/backup/rollback tests and adapt orchestration fixtures |
| `README.md` | Document the confirmation behavior |

---

### Task 1: Interactive Backup and Replacement

**Files:**
- Modify: `ocserv-deploy.sh`
- Modify: `tests/ocserv-deploy-test.sh`
- Modify: `README.md`

**Interfaces:**
- Produces: `stdin_is_terminal`, `read_config_replacement_answer`, `next_config_backup_path`, `check_existing_config`.
- Consumes: `OCSERV_CONF`, `die`, the existing transaction engine, and existing `main install` ordering.

- [ ] **Step 1: Add failing unit tests**

Replace the old config-ownership tests with focused tests for:

```text
absent config: succeeds without prompting or backup
managed existing config + y: backs up and succeeds
unmanaged existing config + Y: backs up and succeeds
n/other text: fails without backup
EOF/read failure: fails without backup
non-TTY stdin: fails even when y is piped
same-second backup collisions: chooses .1.bak, then .2.bak
backup preserves content, mode, and mtime
backup copy failure: fails and leaves original untouched
```

Expose two tiny seams:

```bash
stdin_is_terminal() {
  [[ -t 0 ]]
}

read_config_replacement_answer() {
  local prompt="$1"
  IFS= read -r -p "$prompt" CONFIG_REPLACEMENT_ANSWER
}
```

Unit tests may override these functions after sourcing:

```bash
stdin_is_terminal() { return 0; }
read_config_replacement_answer() { CONFIG_REPLACEMENT_ANSWER="y"; }
```

Use this override for the EOF/read-failure case:

```bash
stdin_is_terminal() { return 0; }
read_config_replacement_answer() { return 1; }
```

This is function-level injection only; production has no environment or CLI bypass.

- [ ] **Step 2: Verify RED**

Run:

```bash
sudo bash tests/ocserv-deploy-test.sh
```

Expected: new confirmation tests fail because current code accepts managed configs without prompting and rejects unmanaged configs regardless of confirmation.

- [ ] **Step 3: Implement collision-safe confirmation backup**

Implement:

```bash
stdin_is_terminal() {
  [[ -t 0 ]]
}

read_config_replacement_answer() {
  local prompt="$1"
  IFS= read -r -p "$prompt" CONFIG_REPLACEMENT_ANSWER
}

next_config_backup_path() {
  local timestamp base candidate suffix=0
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  base="${OCSERV_CONF}.pre-vpn-node-${timestamp}"
  candidate="${base}.bak"
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    suffix=$((suffix + 1))
    candidate="${base}.${suffix}.bak"
  done
  printf '%s\n' "$candidate"
}

check_existing_config() {
  CONFIG_REPLACEMENT_CONFIRMED=0
  [[ -e "$OCSERV_CONF" || -L "$OCSERV_CONF" ]] || return 0
  stdin_is_terminal ||
    die "existing ocserv config requires interactive replacement confirmation: $OCSERV_CONF"

  CONFIG_REPLACEMENT_ANSWER=""
  read_config_replacement_answer \
    "Existing config $OCSERV_CONF will be backed up and replaced. Continue? [y/N] " ||
    die "could not read config replacement confirmation"

  case "$CONFIG_REPLACEMENT_ANSWER" in
    y|Y) ;;
    *) die "config replacement declined" ;;
  esac

  local backup
  backup="$(next_config_backup_path)"
  cp -a -- "$OCSERV_CONF" "$backup" ||
    die "failed to back up existing ocserv config to $backup"
  CONFIG_REPLACEMENT_CONFIRMED=1
  log "Existing ocserv config backed up to $backup"
}
```

Do not call `rm` on `OCSERV_CONF`.

Declare `CONFIG_REPLACEMENT_CONFIRMED=0` once with the other script state globals. Reset it at the beginning of every `check_existing_config` call and set it only after `cp -a` succeeds, so rejected/failed/absent paths cannot inherit stale confirmation state.

- [ ] **Step 4: Preserve rerun port handling**

After successful confirmation, an existing config may still describe a currently running ocserv listener. Update `check_port_available` so its “same configured port, all owners are ocserv” rerun path applies to any confirmed existing config, not only a file containing `MANAGED_MARKER`.

Change `_configured_ocserv_port` to require the confirmation flag and a readable existing config, but not the management marker:

```bash
_configured_ocserv_port() {
  ((CONFIG_REPLACEMENT_CONFIRMED == 1)) || return 1
  [[ -f "$OCSERV_CONF" ]] || return 1
  awk -F' = ' '$1 == "tcp-port" { print $2; found=1 } END { exit !found }' \
    "$OCSERV_CONF"
}
```

The existing rerun allowance remains limited to the same configured port and listeners whose reported process name is exclusively `ocserv`. A non-ocserv owner still fails.

Keep the `main install` order explicit:

```bash
load_config
validate_common_config
check_existing_config
check_managed_targets
check_route_overlap
check_port_available
install_dependencies
install_server
```

`check_existing_config` must remain before `check_port_available`, because successful backup sets the confirmation state needed by `_configured_ocserv_port`.

- [ ] **Step 5: Adapt orchestration tests and add rollback coverage**

In `_orchestration_fixture`, inject interactive approval:

```bash
stdin_is_terminal() { return 0; }
read_config_replacement_answer() { CONFIG_REPLACEMENT_ANSWER="y"; }
```

This preserves existing orchestration tests without adding confirmation bytes ahead of initial-user input.

Add integration tests proving:

- `main install` with existing config and terminal refusal does not call apt.
- non-TTY `main install` with existing config does not call apt.
- confirmed existing config with an ocserv-owned listener on the unchanged port passes the port check.
- confirmation plus a later forced restart failure restores the original config and leaves the permanent `.bak`.
- unmanaged helper/drop-in/hook are still refused after config confirmation.

- [ ] **Step 6: Update README**

Under OpenConnect installation, add:

```text
若 /etc/ocserv/ocserv.conf 已存在，安装器会要求输入 y 确认，先备份原配置，
再用新配置替换；无交互终端时会中止。
```

- [ ] **Step 7: Run full verification**

```bash
bash -n ocserv-deploy.sh
bash -n tests/ocserv-deploy-test.sh
sudo bash tests/ocserv-deploy-test.sh
sudo bash tests/ocserv-deploy-test.sh --real-tools
git diff --check
```

Expected: syntax succeeds, mock and real-tools suites report zero failures, and the real host remains unchanged.

- [ ] **Step 8: Commit**

```bash
git add ocserv-deploy.sh tests/ocserv-deploy-test.sh README.md
git commit -m "Prompt before replacing existing ocserv config"
```
