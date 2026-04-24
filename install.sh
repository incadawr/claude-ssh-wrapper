#!/usr/bin/env bash
# Installer for claude-ssh-wrapper. Idempotent: safe to re-run.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="$REPO_DIR/bin/claude"

BIN_DIR="$HOME/bin"
BIN_DST="$BIN_DIR/claude"
WRAPPER_DIR="$HOME/.claude-wrapper"
CONFIG="$WRAPPER_DIR/config.json"

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

# --- 2. find real claude BEFORE we install the wrapper ---------------------
# Walk PATH matches and skip our own wrapper (it may already be installed).
find_real_claude() {
  local candidate resolved
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    resolved="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
    [[ "$resolved" == "$BIN_DST" ]] && continue
    printf '%s\n' "$resolved"
    return 0
  done < <(type -aP claude 2>/dev/null || true)
  return 1
}

REAL_CLAUDE="$(find_real_claude || true)"

if [[ -z "$REAL_CLAUDE" ]]; then
  # Offer to run the official installer when we're interactive; otherwise bail.
  if [[ -t 0 && -t 1 ]]; then
    echo
    info "Claude Code is not installed."
    read -rp "  Install it now via https://claude.ai/install.sh ? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      info "running official installer..."
      if ! curl -fsSL https://claude.ai/install.sh | bash; then
        die "official installer failed"
      fi
      # The installer may have extended PATH only for subshells via ~/.zshrc;
      # for *this* shell we need to look in the default install location too.
      export PATH="$HOME/.local/bin:$PATH"
      hash -r 2>/dev/null || true
      REAL_CLAUDE="$(find_real_claude || true)"
    fi
  fi
fi

if [[ -z "$REAL_CLAUDE" ]]; then
  err "real 'claude' binary not found in PATH."
  err "Install Claude Code manually (https://claude.ai/install.sh), then re-run this installer."
  exit 1
fi
info "found real claude at $REAL_CLAUDE"

# --- 3. create directories -------------------------------------------------
mkdir -p "$BIN_DIR"
mkdir -p "$WRAPPER_DIR"

# --- 4. install wrapper ----------------------------------------------------
install -m 0755 "$BIN_SRC" "$BIN_DST"
info "installed wrapper to $BIN_DST"

# --- 5. create config if missing -------------------------------------------
if [[ ! -f "$CONFIG" ]]; then
  host=""
  user="root"

  # Prompt only if stdin AND stdout are terminals — otherwise fall back to a
  # placeholder the user edits by hand (handles `curl … | bash`-style installs).
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

  cat > "$CONFIG" <<EOF
{
  "server": {
    "host": "$host",
    "user": "$user",
    "port": 22
  },
  "proxy": {
    "localPort": 8888,
    "remotePort": 18080
  },
  "claude": {
    "binary": "$REAL_CLAUDE"
  }
}
EOF
  chmod 0600 "$CONFIG"
  info "created config at $CONFIG"
  if [[ "$host" == "example.com" ]]; then
    info "  -> edit server.host and server.user before first run"
  fi
else
  info "config already exists at $CONFIG (not overwriting)"
fi

# --- 6. PATH ordering check + auto-fix -------------------------------------
# ~/bin must resolve BEFORE the directory of the real claude binary, and of
# course needs to be in PATH at all. If it isn't, append an export to the
# user's shell rc file (with a marker so repeat runs are idempotent).

# Pick the rc file that the user's login shell actually reads on startup.
# On macOS Terminal.app launches each shell as a login shell, so for bash
# that's ~/.bash_profile, not ~/.bashrc. For zsh it's ~/.zshrc.
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

# Returns 0 if ~/bin comes first (or at least before real_dir) in PATH.
path_is_good() {
  local real_dir entry
  real_dir="$(dirname "$REAL_CLAUDE")"
  IFS=':' read -r -a path_entries <<< "$PATH"
  for entry in "${path_entries[@]}"; do
    [[ "$entry" == "$BIN_DIR" || "$entry" == "$HOME/bin" ]] && return 0
    [[ "$entry" == "$real_dir" ]] && return 1
  done
  return 1  # never saw BIN_DIR
}

append_path_export() {
  local rc marker='# claude-ssh-wrapper: ~/bin must come first for the claude wrapper'
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
    # Literal string on purpose — $HOME/$PATH must expand when the rc is
    # sourced by the user's shell, not at install time.
    # shellcheck disable=SC2016
    printf '%s\n' 'export PATH="$HOME/bin:$PATH"'
  } >> "$rc"
  echo "$rc"
}

if ! path_is_good; then
  if [[ -t 0 && -t 1 ]]; then
    echo
    info "\$HOME/bin is not (first) in PATH — the wrapper won't intercept 'claude'."
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
    err "\$HOME/bin is not (first) in PATH — wrapper won't be picked up."
    err "Add this line to your shell rc and open a new terminal:"
    err "  export PATH=\"\$HOME/bin:\$PATH\""
    err ""
    exit 1
  fi
fi

info ""
info "done. Next steps:"
info "  1. edit $CONFIG (set server.host and server.user)"
info "  2. make sure SSH key auth to that host works: ssh <user>@<host>"
info "  3. ensure an HTTP proxy is listening on the server at 127.0.0.1:<remotePort>"
info "  4. run: claude"
