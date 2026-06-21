# Design spec: self-healing SSH tunnel

Status: **deferred — not implemented** (current setup works; revisit when drops become painful again).
Date: 2026-05-15.

## Problem

The SSH ControlMaster tunnel drops mid-session. Likely cause: Cisco AnyConnect VPN
reconnects and/or Wi-Fi transport instability — the SSH TCP socket is *physically*
severed (not just silent), so `ServerAlive*` keepalive tuning cannot save it.

Evidence (`~/.claude-wrapper/tunnel.log`, 7–15 May): repeated `FAIL ssh master down`
followed by watchdog `STOP`, plus `FAIL proxy probe: no HTTP response (master alive)`
flapping. Today the master died twice within 1.5h of active work.

**Root cause is architectural, not just network:** `bin/tunnel-watchdog` only
*observes* and logs; it exits after `FAIL_LIMIT` cycles. The master is reopened
**only** by a fresh `claude` invocation. Any mid-session drop leaves the tunnel dead
until the user re-launches `claude`. Goal: automatic recovery without re-launching
`claude`.

Recovery is feasible: `claude` uses `HTTPS_PROXY=127.0.0.1:8888` and opens a fresh
HTTP connection per request. Once the local forward port listens again, `claude`'s
own retry succeeds — the `claude` process does not need restarting.

## Chosen approach

**Watchdog self-heals.** Rejected alternatives: launchd `KeepAlive` (heavier; its only
edge over the watchdog — surviving reboot/sleep while `claude` is *not* running — is
not needed, since mid-session the watchdog is alive anyway); `autossh` (new brew
dependency, violates the "only ssh + jq" invariant).

## Plan (revised after Codex review)

Codex reviewed the first draft and flagged real concurrency gaps. Net design:

### New: `bin/_tunnel-lib.sh` (shared)
Single home for tunnel logic so it is not copy-pasted across 4 scripts. Sourced by
`bin/claude`, `bin/codex`, `bin/tunnel-watchdog`, `bin/claude-tunnel`. Provides:
- `acquire_lock` / `release_lock` — atomic via `mkdir "$WRAPPER_DIR/tunnel.lock.d"`
  (macOS has no `flock` command). Trap-based cleanup.
- `open_master` — the `ssh -M -S sock -fN -L ...` invocation, single source of truth.
- `close_master` — `ssh -O exit` + stale-socket removal.
- `clear_sentinel` — remove the stop file.

### `bin/tunnel-watchdog` — becomes the tunnel liveness owner
- Also reads `server.port` and `proxy.remotePort` from config (today: only
  host/user/localPort).
- On `master down`: **reopen** the master via `open_master` instead of exiting at
  `FAIL_LIMIT`. Log `RECONNECT ok/fail`.
- On `proxy probe fail` while `ssh -O check` passes for N consecutive cycles
  (wedged forward channel): `close_master` then `open_master`.
- Classify probe failure: capture `curl` exit code + CONNECT status. `curl 000` is not
  always a dead local forward — do not recycle SSH forever when the *remote* proxy is
  genuinely down.
- **Capped exponential backoff** on reconnect (15s → 30 → 60 → 120, reset on OK) — a
  server/VPN outage at a 15s probe interval would otherwise be an SSH/log storm.
- `open_master` for reconnects uses `BatchMode=yes` + `ConnectTimeout=10` — a host-key
  or auth prompt must never hang the daemon.
- Default probe interval lowered 30s → 15s (faster heal of an active session).
- Exits **only** on the sentinel stop file or `SIGTERM`/`SIGINT` — no longer on
  `FAIL_LIMIT`. Lives the whole session.
- PID lock: before `kill`, verify the target process command actually contains
  `tunnel-watchdog` (PID reuse hazard for a long-lived daemon).

### New: `bin/claude-tunnel` — installed to `~/bin` (on PATH, like `claude-doctor`)
- `stop` — write sentinel (with nonce), acquire `tunnel.lock`, re-verify the nonce is
  still current, `close_master`, kill the verified watchdog process.
- `start` — `open_master` + spawn watchdog, without launching `claude`.
- `restart` — stop + start.
- `status` — master / port / watchdog / sentinel state + last log lines.

### Sentinel stop file
- Path `"$WRAPPER_DIR/stop"` — **not** hardcoded `~/.claude-wrapper/stop` (respects
  `CLAUDE_WRAPPER_CONFIG` alternate profiles).
- Contains a **nonce**. `bin/claude`, `bin/codex`, and `claude-tunnel start/restart`
  remove it on startup (explicit "I want to work" wins races). `stop` re-checks the
  nonce before its final `close_master` — if it changed/disappeared, a fresh
  `claude`/`codex` start happened, so `stop` aborts the close.

### `bin/claude` and `bin/codex`
- Both: remove stale sentinel on startup; add `-o ConnectTimeout`; route socket
  check/remove/open through `_tunnel-lib.sh` under the lock. `bin/codex` (currently
  untracked) mirrors `bin/claude` and must get the same treatment.

### `install.sh` / `uninstall.sh`
- Install/remove `bin/claude-tunnel` and `bin/_tunnel-lib.sh`.
- `--purge` also removes the sentinel and `tunnel.lock.d`.

### Docs
- `CLAUDE.md` — rewrite the watchdog invariant: the watchdog becomes the tunnel
  liveness owner after first start; raw `ssh -O exit` is now a *transient fault* the
  watchdog repairs, **not** a stop command; explicit stop is `claude-tunnel stop`. Add
  `bin/claude-tunnel` and `bin/_tunnel-lib.sh` to repo structure + runtime files.
- `README.md` — replace the raw `ssh -O exit` instruction (~line 94) with
  `claude-tunnel stop`; document self-healing and `claude-tunnel start/status/restart`.
- `claude-doctor` — report sentinel state; suggest `claude-tunnel start/restart`
  instead of only "run claude".
- `extras/swiftbar/claude-tunnel.30s.sh` — any "reopen tunnel" action calls
  `claude-tunnel restart`.

## Invariants

Only the watchdog invariant in `CLAUDE.md` changes; that is acceptable if documented
explicitly. "Thin bash wrapper, SSH + HTTP proxy, env vars only, ssh + jq deps"
invariants remain intact.

## Verification (when implemented)

- `bash -n` + `shellcheck` clean on every changed file (project convention).
- Manual reconnect test: kill the master by hand, confirm the watchdog reopens it
  within one backoff cycle and an in-flight `claude` recovers without restart.
- Concurrency test: run `claude` and `codex` simultaneously; run `claude-tunnel stop`
  while a reconnect is in flight — confirm no live socket is unlinked and no stale
  master survives.
