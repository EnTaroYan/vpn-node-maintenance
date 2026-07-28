# ImmortalWrt Dual-Stack Ingress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add boot/hotplug public-address detection, managed Cloudflare A+AAAA updates, and dual-stack WireGuard/LuCI ingress.

**Architecture:** The client installer renders an isolated procd detector/updater with hotplug and cron triggers. Services listen dual-stack statically; detection controls status, DDNS records, and no-domain WireGuard templates without blocking network startup.

**Tech Stack:** Bash/ash, procd, ubus/jsonfilter, fw4, uhttpd, WireGuard, Cloudflare API.

## Global Constraints

- Both public families are published when available; clients may prefer IPv6.
- Unknown external-detection state never deletes DNS.
- Only records marked `managed-by=vpn-node` may be deleted.
- IPv4 requires non-reserved WAN address and matching external observation.
- IPv6 requires stable GUA and default route.
- VPN inner networks remain IPv4-only.
- DNS-01 certificate flow remains address-family independent.
- Tests cannot touch real network or Cloudflare.

---

### Task 1: Public Address Lifecycle

**Files:**
- Modify: `client/immortalwrt-deploy.sh`
- Modify: `client/immortalwrt.env.example`
- Modify: `tests/client/immortalwrt-deploy-test.sh`
- Modify: `README.md`

- [ ] Add RED tests for IPv4 classification/observation, IPv6 filtering, dual/single/unknown states, DDNS create/update/delete protection, hotplug/cron/procd rendering, no-domain endpoint priority, dual-stack LuCI/firewall.
- [ ] Render `/usr/libexec/vpn-node/ingress-update`, `/etc/init.d/vpn-node-ingress`, hotplug and cron entries; store runtime status under `/var/run`.
- [ ] Update DDNS updater to independently manage A/AAAA with Cloudflare comments and unknown preservation.
- [ ] Render WireGuard rules as `family any`; use domain or selected literal for templates.
- [ ] Render uhttpd IPv4+IPv6 HTTPS listeners and dual-stack firewall rule.
- [ ] Preserve current DNS-01/selfsigned behavior.
- [ ] Run `bash -n`, full client tests, server tests, `git diff --check`; verify no live state changed.
- [ ] Commit with tests and documentation.
