#!/usr/bin/env bash
# Uninstaller for claude-ssh-wrapper. Removes the wrapper and closes the SSH
# master connection. Config is preserved unless --purge is passed.
set -euo pipefail

BIN_DST="$HOME/bin/claude"
DOCTOR_DST="$HOME/bin/claude-doctor"
WRAPPER_DIR="$HOME/.claude-wrapper"
CONFIG="$WRAPPER_DIR/config.json"
CONTROL_SOCK="$WRAPPER_DIR/tunnel.sock"
WATCHDOG_PID_FILE="$WRAPPER_DIR/watchdog.pid"

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help)
      echo "usage: $0 [--purge]"
      echo "  --purge   also remove $WRAPPER_DIR (config included)"
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

info() { echo "uninstall: $*"; }

# Stop watchdog before closing the master, so it doesn't log spurious
# "master gone" entries during teardown. SIGTERM can be delayed up to one
# probe interval if the watchdog is sleeping, so wait briefly and escalate
# to SIGKILL.
if [[ -f "$WATCHDOG_PID_FILE" ]]; then
  watchdog_pid=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null || true)
  if [[ -n "$watchdog_pid" ]] && kill -0 "$watchdog_pid" 2>/dev/null; then
    kill "$watchdog_pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$watchdog_pid" 2>/dev/null || break
      sleep 0.5
    done
    if kill -0 "$watchdog_pid" 2>/dev/null; then
      kill -9 "$watchdog_pid" 2>/dev/null || true
      info "force-killed watchdog (pid=$watchdog_pid) — it didn't honor SIGTERM"
    else
      info "stopped watchdog (pid=$watchdog_pid)"
    fi
  fi
  rm -f "$WATCHDOG_PID_FILE"
fi

# Close SSH master if it's alive. We need user/host for the -O exit command,
# but ssh -O exit with just the control socket also works.
if [[ -S "$CONTROL_SOCK" ]]; then
  if command -v jq >/dev/null 2>&1 && [[ -f "$CONFIG" ]]; then
    host=$(jq -r '.server.host // empty' "$CONFIG" 2>/dev/null || true)
    user=$(jq -r '.server.user // empty' "$CONFIG" 2>/dev/null || true)
    if [[ -n "$host" && -n "$user" ]]; then
      ssh -S "$CONTROL_SOCK" -O exit "$user@$host" >/dev/null 2>&1 || true
      info "closed SSH master"
    fi
  fi
  rm -f "$CONTROL_SOCK"
fi

if [[ -e "$BIN_DST" || -L "$BIN_DST" ]]; then
  rm -f "$BIN_DST"
  info "removed $BIN_DST"
fi

if [[ -e "$DOCTOR_DST" || -L "$DOCTOR_DST" ]]; then
  rm -f "$DOCTOR_DST"
  info "removed $DOCTOR_DST"
fi

# The watchdog binary lives under ~/.claude-wrapper/ but it's an artifact,
# not user state — drop it on non-purge uninstall too. Config and tunnel.log
# stay (those are the only files worth preserving).
WATCHDOG_DST="$WRAPPER_DIR/tunnel-watchdog"
if [[ -e "$WATCHDOG_DST" || -L "$WATCHDOG_DST" ]]; then
  rm -f "$WATCHDOG_DST"
  info "removed $WATCHDOG_DST"
fi

if [[ "$PURGE" -eq 1 ]]; then
  rm -rf "$WRAPPER_DIR"
  info "purged $WRAPPER_DIR"
else
  info "config preserved at $CONFIG (use --purge to remove)"
fi

info "done"
