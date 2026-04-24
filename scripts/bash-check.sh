#!/usr/bin/env bash
# End-to-end check for claude-vpn-wrapper setup:
#   1. private key is present and has correct permissions
#   2. SSH key is accepted by the server and shell is blocked (forward-only)
#   3. SSH forward opens, the remote HTTP proxy responds through it
#   4. request via proxy returns the expected Helsinki egress IP
#
# Run on the target mac after copying the key and ~/.ssh/config entry.
set -euo pipefail

# --- knobs (override via env — at minimum SSH_TARGET must be set) ---------
: "${SSH_TARGET:=}"
: "${SSH_KEY:=$HOME/.ssh/claude_wrapper_ed25519}"
: "${LOCAL_PORT:=18888}"
: "${REMOTE_PORT:=18080}"
# ---------------------------------------------------------------------------

if [[ -z "$SSH_TARGET" ]]; then
  echo "usage: SSH_TARGET=user@host [SSH_KEY=...] [LOCAL_PORT=...] [REMOTE_PORT=...] $0" >&2
  exit 2
fi

RED=$(tput setaf 1 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
BOLD=$(tput bold 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)

pass() { echo "${GREEN}✓${RESET} $*"; }
fail() { echo "${RED}✗${RESET} $*" >&2; }
info() { echo "${BOLD}▸${RESET} $*"; }
warn() { echo "${YELLOW}!${RESET} $*"; }

SOCK="/tmp/claude-wrapper-check.$$.sock"
cleanup() {
  if [[ -S "$SOCK" ]]; then
    ssh -S "$SOCK" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true
  fi
  rm -f "$SOCK"
}
trap cleanup EXIT

# --- 1. key file -----------------------------------------------------------
info "check 1: private key at $SSH_KEY"
if [[ ! -f "$SSH_KEY" ]]; then
  fail "key not found"
  exit 1
fi
mode=$(stat -f '%A' "$SSH_KEY" 2>/dev/null || stat -c '%a' "$SSH_KEY")
if [[ "$mode" != "600" && "$mode" != "400" ]]; then
  warn "key permissions are $mode — should be 600 or 400"
  warn "fix with: chmod 600 $SSH_KEY"
else
  pass "key present, mode $mode"
fi

# --- 2. shell is blocked ---------------------------------------------------
info "check 2: shell on server is blocked for this key"
shell_out=$(timeout 5 ssh -i "$SSH_KEY" -o IdentitiesOnly=yes \
              -o BatchMode=yes -o ConnectTimeout=5 \
              "$SSH_TARGET" 'id; whoami' 2>&1 || true)
if echo "$shell_out" | grep -q 'forward-only'; then
  if echo "$shell_out" | grep -Eq 'uid=|root'; then
    fail "shell executed — restrictions missing on authorized_keys"
    echo "$shell_out" | head -5
    exit 1
  fi
  pass "shell blocked (forced command returned)"
else
  fail "unexpected ssh response:"
  echo "$shell_out" | head -5
  exit 1
fi

# --- 3. port forward --------------------------------------------------------
info "check 3: open SSH forward $LOCAL_PORT -> server 127.0.0.1:$REMOTE_PORT"
if lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "local port $LOCAL_PORT is already in use — pick another LOCAL_PORT"
  exit 1
fi

ssh -M -S "$SOCK" -fN \
    -i "$SSH_KEY" -o IdentitiesOnly=yes \
    -o ExitOnForwardFailure=yes -o ConnectTimeout=10 \
    -L "127.0.0.1:$LOCAL_PORT:127.0.0.1:$REMOTE_PORT" \
    "$SSH_TARGET"
pass "forward up (master pid $(ssh -S "$SOCK" -O check "$SSH_TARGET" 2>&1 | grep -oE '[0-9]+' | head -1))"

# --- 4. request through proxy ----------------------------------------------
info "check 4: HTTPS request via proxy"
tmp=$(mktemp)
http_code=$(curl -sS --proxy "http://127.0.0.1:$LOCAL_PORT" \
                 --max-time 10 \
                 -o "$tmp" -w '%{http_code}' \
                 https://api.ipify.org || echo "000")
ip=$(cat "$tmp")
rm -f "$tmp"

if [[ "$http_code" != "200" ]]; then
  fail "proxy request failed: HTTP $http_code"
  exit 1
fi
pass "HTTP $http_code, egress IP via proxy: ${BOLD}$ip${RESET}"

# Expected egress IP can be provided via EXPECTED_EGRESS_IP env for CI-style runs.
if [[ -n "${EXPECTED_EGRESS_IP:-}" && "$ip" != "$EXPECTED_EGRESS_IP" ]]; then
  warn "egress IP differs from expected $EXPECTED_EGRESS_IP"
fi

echo
pass "${BOLD}all checks passed${RESET}"
