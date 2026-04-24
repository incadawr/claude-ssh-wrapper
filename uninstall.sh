#!/usr/bin/env bash
# Uninstaller for claude-ssh-wrapper. Removes the wrapper and closes the SSH
# master connection. Config is preserved unless --purge is passed.
set -euo pipefail

BIN_DST="$HOME/bin/claude"
WRAPPER_DIR="$HOME/.claude-wrapper"
CONFIG="$WRAPPER_DIR/config.json"
CONTROL_SOCK="$WRAPPER_DIR/tunnel.sock"

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

if [[ "$PURGE" -eq 1 ]]; then
  rm -rf "$WRAPPER_DIR"
  info "purged $WRAPPER_DIR"
else
  info "config preserved at $CONFIG (use --purge to remove)"
fi

info "done"
