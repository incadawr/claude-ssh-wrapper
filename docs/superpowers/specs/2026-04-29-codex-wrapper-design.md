# codex-ssh-wrapper: extending claude-ssh-wrapper to wrap `codex`

**Date:** 2026-04-29
**Status:** Approved for implementation

## Goal

Make the OpenAI `codex` CLI route its HTTP(S) traffic through the SSH-tunneled proxy that `claude-ssh-wrapper` already maintains. Reuse all shared infrastructure (config, SSH ControlMaster, watchdog, doctor) instead of duplicating it.

Non-goal: a separate, fully featured `codex-ssh-wrapper` repo with its own diagnostics. Everything diagnostic stays under the `claude-*` namespace and is shared.

## Background

`claude-ssh-wrapper` already wraps `claude` by:

1. Reading `~/.claude-wrapper/config.json`.
2. Bringing up an SSH ControlMaster with `-L 127.0.0.1:<localPort>:127.0.0.1:<remotePort>` (idempotent — checks `tunnel.sock` first).
3. Exporting `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY`.
4. Running pre-flight, spawning watchdog, printing banner.
5. `exec`-ing the real `claude`.

Investigation of the codex 0.125.0 binary confirms it honors standard proxy env vars (`HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`, `NO_PROXY`) — the same hook-point as `claude`. There is no `config.toml` proxy field yet (issue #6060 still open), so env vars are the only mechanism.

## Design

### New file: `bin/codex`

Thin shim, ~30 lines. Mirrors steps 1–3 and 5 of `bin/claude`, omitting pre-flight. Intentionally duplicates the tunnel-up block instead of refactoring `bin/claude` — keeps risk localized.

Behavior:

1. Read `~/.claude-wrapper/config.json` (same path as `bin/claude`; `CLAUDE_WRAPPER_CONFIG` env override still respected for parity).
2. Require `.codex.binary`; clear error if missing.
3. Reuse or open SSH master at `~/.claude-wrapper/tunnel.sock` (same code path as `bin/claude`, same `ssh -O check` idempotency).
4. Export `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` (uppercase + lowercase).
5. Spawn `tunnel-watchdog` if its PID file shows no live instance — same single-instance logic as `bin/claude`. Ensures users who only install codex still get the health log.
6. Print banner to stderr: `codex-wrapper: via <user>@<host> (127.0.0.1:<localPort> → :<remotePort>)`. Suppressed by `CODEX_WRAPPER_QUIET=1`.
7. `exec` the real codex binary with all forwarded args.

Not included (deliberate):

- No pre-flight. `claude-doctor` already probes the tunnel and is binary-agnostic (it tests connectivity through the proxy, not Anthropic-specific behavior).
- No `codex-doctor`. The single `claude-doctor` covers the shared SSH+proxy chain.
- No new env vars beyond `CODEX_WRAPPER_QUIET` (mirrors `CLAUDE_WRAPPER_QUIET`). Note: `CLAUDE_WRAPPER_NO_PREFLIGHT` does not apply since codex shim has no pre-flight.

### Config schema

`~/.claude-wrapper/config.json` gains an optional `codex.binary` field:

```json
{
  "server":  { "host": "...", "user": "...", "port": 22 },
  "proxy":   { "localPort": 8888, "remotePort": 18080 },
  "claude":  { "binary": "/path/to/claude" },
  "codex":   { "binary": "/opt/homebrew/bin/codex" }
}
```

Both `claude` and `codex` blocks are independently optional. Each wrapper checks only its own block — `bin/claude` ignores `codex.binary`; `bin/codex` ignores `claude.binary`. A user can have either or both installed.

### `install.sh` changes

Refactor to support installing either or both wrappers in one run.

- Detect `claude` and `codex` independently using the existing `find_real_*` strategy (walk `type -aP`, skip our own wrapper paths).
- For each, prompt interactively: `Install <name> wrapper? [Y/n]` — defaults to Yes if the binary is found. If a binary is absent, `claude` keeps the existing "install Claude Code now?" offer; `codex` skips silently with an info line (codex install path is less standard — leave to user).
- At least one wrapper must be selected; otherwise abort with a clear message.
- Config writing:
  - Fresh install: write a config with whichever `claude` / `codex` blocks were selected.
  - Existing config: merge in any newly chosen block via `jq` — never overwrite existing fields.
- Always install `tunnel-watchdog` to `~/.claude-wrapper/tunnel-watchdog` and `claude-doctor` to `~/bin/claude-doctor` regardless of which wrapper(s) were selected — they are shared infra.
- PATH check applies the same way (`~/bin` must come first).

### `uninstall.sh` changes

Remove `~/bin/codex` if present, in addition to existing claude/doctor cleanup. `--purge` continues to remove `~/.claude-wrapper` entirely.

### README changes

Add a short section: `codex` is wrapped the same way; one config file, one tunnel; `CODEX_WRAPPER_QUIET=1` mirror of `CLAUDE_WRAPPER_QUIET`. Update config schema sample. Update install/uninstall blurbs to mention the dual-wrapper prompt.

## Architecture & isolation

Three independent units after this change:

| Unit | Responsibility | Depends on |
|---|---|---|
| `bin/claude` | Wrap claude: tunnel-up + env + preflight + watchdog + exec claude | config, ssh, jq, watchdog binary |
| `bin/codex`  | Wrap codex: tunnel-up + env + watchdog + exec codex | config, ssh, jq, watchdog binary |
| `bin/claude-doctor`, `bin/tunnel-watchdog` | Health-check / live monitoring of the shared tunnel | config |

Wrappers do not depend on each other. They share config and the `tunnel.sock` filesystem coordination point — both interact with it through `ssh -O check` / `ssh -M`, which is idempotent and concurrent-safe.

## Trade-offs considered

- **Duplicate ~15 lines vs. extract a `lib/wrapper-common.sh`.** Chose duplication. The shared logic is small and stable; refactoring `bin/claude` to source a library risks regressions in working code for marginal benefit.
- **One config vs. two configs (`~/.codex-wrapper/`).** Chose one. Both wrappers point at the same SSH server and same proxy ports; splitting would invite drift and double-master if both were used in the same session.
- **Pre-flight in `bin/codex` or not.** Chose not. The single point of failure is the SSH+proxy chain, which `claude-doctor` already diagnoses. Adding a second pre-flight against `api.openai.com` doubles latency on every codex invocation for the same diagnostic value.

## Out of scope

- `codex-doctor` shortcut alias. (Trivial to add later — it would just exec `claude-doctor`.)
- Per-binary proxy config (different proxy for claude vs codex). YAGNI.
- `codex` Cloud / web variants. Wrapper targets the local `codex` CLI only.
- Linux support beyond what already works for `bin/claude`.

## Acceptance criteria

1. With both `claude` and `codex` selected at install time:
   - `~/bin/claude` and `~/bin/codex` exist and are executable.
   - `~/.claude-wrapper/config.json` contains both `.claude.binary` and `.codex.binary`.
   - Running `codex --version` succeeds and the SSH master is up afterwards (verifiable via `ssh -S ~/.claude-wrapper/tunnel.sock -O check`).
   - Running `codex` after `claude` reuses the same `tunnel.sock` (no second SSH process).
2. With only `codex` selected:
   - `~/bin/codex` exists, `~/bin/claude` does not.
   - Config has `.codex.binary` only.
   - `codex` works; `claude-doctor` works.
3. With only `claude` selected (existing behavior preserved):
   - No `~/bin/codex`. Config has no `.codex.binary` block.
   - Existing claude behavior unchanged.
4. `uninstall.sh` removes both wrapper symlinks if present; `--purge` clears `~/.claude-wrapper`.
5. `CODEX_WRAPPER_QUIET=1 codex --version` produces no banner on stderr from the wrapper.
