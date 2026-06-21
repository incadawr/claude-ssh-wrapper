#!/usr/bin/env bash
# Installer for claude-ssh-wrapper. Idempotent: safe to re-run.
# Installs a wrapper for `claude`, `codex`, or both — interactive prompt.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_SRC="$REPO_DIR/bin/claude"
CODEX_SRC="$REPO_DIR/bin/codex"
DOCTOR_SRC="$REPO_DIR/bin/claude-doctor"
WATCHDOG_SRC="$REPO_DIR/bin/tunnel-watchdog"

BIN_DIR="$HOME/bin"
CLAUDE_DST="$BIN_DIR/claude"
CODEX_DST="$BIN_DIR/codex"
DOCTOR_DST="$BIN_DIR/claude-doctor"
WRAPPER_DIR="$HOME/.claude-wrapper"
CONFIG="$WRAPPER_DIR/config.json"
WATCHDOG_DST="$WRAPPER_DIR/tunnel-watchdog"

err() { echo "install: $*" >&2; }
info() { echo "install: $*"; }
die() { err "$*"; exit 1; }

# --- 1. dependencies -------------------------------------------------------
if ! command -v ssh >/dev/null 2>&1; then
  die "ssh not found — unexpected on macOS; aborting"
fi

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required. Install it with:"
  err "  brew install jq"
  exit 1
fi

# --- 2. find real binaries -------------------------------------------------
# Walk PATH matches and skip our own wrapper (it may already be installed).
find_real() {
  local name="$1" wrapper_dst="$2"
  local candidate resolved
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    resolved="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
    [[ "$resolved" == "$wrapper_dst" ]] && continue
    printf '%s\n' "$resolved"
    return 0
  done < <(type -aP "$name" 2>/dev/null || true)
  return 1
}

REAL_CLAUDE="$(find_real claude "$CLAUDE_DST" || true)"
REAL_CODEX="$(find_real codex "$CODEX_DST" || true)"

# Offer to install Claude Code via the official installer if missing AND
# we're interactive. We don't do the same for codex — its install path is
# less standard (npm/brew/binary) and we don't want to make a choice here.
if [[ -z "$REAL_CLAUDE" && -t 0 && -t 1 ]]; then
  echo
  info "Claude Code is not installed."
  read -rp "  Install it now via https://claude.ai/install.sh ? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    info "running official installer..."
    if curl -fsSL https://claude.ai/install.sh | bash; then
      export PATH="$HOME/.local/bin:$PATH"
      hash -r 2>/dev/null || true
      REAL_CLAUDE="$(find_real claude "$CLAUDE_DST" || true)"
    else
      err "official installer failed; continuing without claude wrapper"
    fi
  fi
fi

# --- 3. choose what to install --------------------------------------------
INSTALL_CLAUDE=0
INSTALL_CODEX=0

prompt_yes() {
  # Returns 0 for yes, 1 for no. Default Yes (Enter accepts).
  local q="$1" ans
  if [[ ! -t 0 || ! -t 1 ]]; then
    return 0  # non-interactive: default to yes
  fi
  read -rp "  $q [Y/n] " ans
  [[ ! "$ans" =~ ^[Nn]$ ]]
}

echo
info "select which wrappers to install:"
if [[ -n "$REAL_CLAUDE" ]]; then
  info "  found claude at $REAL_CLAUDE"
  if prompt_yes "Install claude wrapper?"; then
    INSTALL_CLAUDE=1
  fi
else
  info "  claude not found in PATH — skipping claude wrapper"
fi

if [[ -n "$REAL_CODEX" ]]; then
  info "  found codex at $REAL_CODEX"
  if prompt_yes "Install codex wrapper?"; then
    INSTALL_CODEX=1
  fi
else
  info "  codex not found in PATH — skipping codex wrapper"
fi

if [[ "$INSTALL_CLAUDE" -eq 0 && "$INSTALL_CODEX" -eq 0 ]]; then
  die "nothing selected to install. Install claude or codex first, then re-run."
fi

# --- 4. create directories -------------------------------------------------
mkdir -p "$BIN_DIR"
mkdir -p "$WRAPPER_DIR"

# --- 5. install wrappers + shared infra -----------------------------------
# Shared infra (doctor, watchdog) is installed regardless — both wrappers
# spawn the watchdog and benefit from claude-doctor's tunnel diagnostics.
install -m 0755 "$DOCTOR_SRC" "$DOCTOR_DST"
info "installed claude-doctor to $DOCTOR_DST"

install -m 0755 "$WATCHDOG_SRC" "$WATCHDOG_DST"
info "installed tunnel-watchdog to $WATCHDOG_DST"

if [[ "$INSTALL_CLAUDE" -eq 1 ]]; then
  install -m 0755 "$CLAUDE_SRC" "$CLAUDE_DST"
  info "installed claude wrapper to $CLAUDE_DST"
fi

if [[ "$INSTALL_CODEX" -eq 1 ]]; then
  install -m 0755 "$CODEX_SRC" "$CODEX_DST"
  info "installed codex wrapper to $CODEX_DST"
fi

# --- 6. config: create fresh OR merge missing fields ----------------------
if [[ ! -f "$CONFIG" ]]; then
  host=""
  user="root"

  if [[ -t 0 && -t 1 ]]; then
    echo
    info "configure the server (press Enter to accept defaults in brackets)"
    while [[ -z "$host" ]]; do
      read -rp "  SSH host (IP or ~/.ssh/config alias): " host
      host="${host// /}"
      if [[ -z "$host" || "$host" == "example.com" ]]; then
        err "  host is required"
        host=""
      fi
    done
    read -rp "  SSH user [root]: " user_in
    user="${user_in:-root}"
  else
    host="example.com"
    info "non-interactive install — writing placeholder host=example.com"
  fi

  # Build config from scratch with whichever blocks were selected.
  jq -n \
    --arg host "$host" --arg user "$user" \
    --arg claude_bin "${REAL_CLAUDE:-}" --arg codex_bin "${REAL_CODEX:-}" \
    --argjson install_claude "$INSTALL_CLAUDE" \
    --argjson install_codex  "$INSTALL_CODEX" \
    '{
       server: { host: $host, user: $user, port: 22 },
       proxy:  { localPort: 8888, remotePort: 18080 }
     }
     + (if $install_claude == 1 then { claude: { binary: $claude_bin } } else {} end)
     + (if $install_codex  == 1 then { codex:  { binary: $codex_bin  } } else {} end)' \
    > "$CONFIG"
  chmod 0600 "$CONFIG"
  info "created config at $CONFIG"
  if [[ "$host" == "example.com" ]]; then
    info "  -> edit server.host and server.user before first run"
  fi
else
  # Existing config — merge in any newly chosen .claude/.codex block
  # without touching server/proxy fields. Idempotent: rewriting the same
  # binary path is a no-op.
  tmp="$(mktemp)"
  jq \
    --arg claude_bin "${REAL_CLAUDE:-}" --arg codex_bin "${REAL_CODEX:-}" \
    --argjson install_claude "$INSTALL_CLAUDE" \
    --argjson install_codex  "$INSTALL_CODEX" \
    '. as $cfg
     | (if $install_claude == 1 then .claude = { binary: $claude_bin } else . end)
     | (if $install_codex  == 1 then .codex  = { binary: $codex_bin  } else . end)' \
    "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  chmod 0600 "$CONFIG"
  info "config already exists at $CONFIG (merged selected binaries)"
fi

# --- 7. PATH ordering check + auto-fix -------------------------------------
# ~/bin must resolve BEFORE the directory of the real binaries we wrap, and
# of course needs to be in PATH at all. If it isn't, append an export to the
# user's shell rc file (with a marker so repeat runs are idempotent).

pick_rc_file() {
  case "${SHELL:-}" in
    */zsh)  echo "$HOME/.zshrc" ;;
    */bash)
      if [[ "$(uname)" == "Darwin" ]]; then echo "$HOME/.bash_profile"
      else echo "$HOME/.bashrc"; fi
      ;;
    *) return 1 ;;
  esac
}

# Check PATH order against every wrapped binary we just installed.
path_is_good() {
  local entry real_dirs=()
  [[ "$INSTALL_CLAUDE" -eq 1 && -n "$REAL_CLAUDE" ]] && real_dirs+=("$(dirname "$REAL_CLAUDE")")
  [[ "$INSTALL_CODEX"  -eq 1 && -n "$REAL_CODEX"  ]] && real_dirs+=("$(dirname "$REAL_CODEX")")

  IFS=':' read -r -a path_entries <<< "$PATH"
  for entry in "${path_entries[@]}"; do
    [[ "$entry" == "$BIN_DIR" || "$entry" == "$HOME/bin" ]] && return 0
    for rd in "${real_dirs[@]}"; do
      [[ "$entry" == "$rd" ]] && return 1
    done
  done
  return 1  # never saw BIN_DIR
}

append_path_export() {
  local rc marker='# claude-ssh-wrapper: ~/bin must come first for the wrappers'
  if ! rc="$(pick_rc_file)"; then
    return 1
  fi
  touch "$rc"
  if grep -qF "$marker" "$rc"; then
    info "PATH line already present in $rc (another install run?)"
    echo "$rc"
    return 0
  fi
  {
    printf '\n%s\n' "$marker"
    # shellcheck disable=SC2016
    printf '%s\n' 'export PATH="$HOME/bin:$PATH"'
  } >> "$rc"
  echo "$rc"
}

if ! path_is_good; then
  if [[ -t 0 && -t 1 ]]; then
    echo
    info "\$HOME/bin is not (first) in PATH — wrappers won't intercept the real binaries."
    read -rp "  Append 'export PATH=\"\$HOME/bin:\$PATH\"' to your shell rc? [Y/n] " answer
    if [[ ! "$answer" =~ ^[Nn]$ ]]; then
      if rc_file="$(append_path_export)"; then
        info "updated $rc_file"
        info "  -> open a NEW terminal (or run: exec \$SHELL -l) for PATH to take effect"
      else
        err "couldn't detect your shell rc file (SHELL=${SHELL:-unset})"
        err "add this line manually to your rc, then open a new terminal:"
        err "  export PATH=\"\$HOME/bin:\$PATH\""
        exit 1
      fi
    else
      err "skipped PATH fix. Add this line manually to your shell rc:"
      err "  export PATH=\"\$HOME/bin:\$PATH\""
      exit 1
    fi
  else
    err ""
    err "\$HOME/bin is not (first) in PATH — wrappers won't be picked up."
    err "Add this line to your shell rc and open a new terminal:"
    err "  export PATH=\"\$HOME/bin:\$PATH\""
    err ""
    exit 1
  fi
fi

info ""
info "done. Next steps:"
info "  1. edit $CONFIG (set server.host and server.user if not yet set)"
info "  2. make sure SSH key auth to that host works: ssh <user>@<host>"
info "  3. ensure an HTTP proxy is listening on the server at 127.0.0.1:<remotePort>"
[[ "$INSTALL_CLAUDE" -eq 1 ]] && info "  4. run: claude"
[[ "$INSTALL_CODEX"  -eq 1 ]] && info "  4. run: codex"
info ""
info "diagnostics:"
info "  claude-doctor                          # one-shot health check (shared)"
info "  tail -f $WRAPPER_DIR/tunnel.log   # live tunnel status (watchdog auto-starts)"
