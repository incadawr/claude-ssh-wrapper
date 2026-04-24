#!/usr/bin/env bash
# wrapper-check.sh — replays exactly what bin/claude does (read config, open
# SSH ControlMaster, export HTTPS_PROXY/...), but instead of exec'ing claude
# it runs `curl` through the proxy and prints the egress IP.
#
# Use when you installed the wrapper but aren't sure whether claude is really
# going through the proxy. If this script prints a Helsinki IP, the wrapper
# side works — any remaining "claude not proxied" behavior lies inside claude,
# not in our code.
set -euo pipefail

CONFIG="${CLAUDE_WRAPPER_CONFIG:-$HOME/.claude-wrapper/config.json}"
WRAPPER_DIR="$(dirname "$CONFIG")"
CONTROL_SOCK="$WRAPPER_DIR/tunnel.sock"

BOLD=$(tput bold 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)

pass() { echo "${GREEN}✓${RESET} $*"; }
fail() { echo "${RED}✗${RESET} $*" >&2; }
info() { echo "${BOLD}▸${RESET} $*"; }
warn() { echo "${YELLOW}!${RESET} $*"; }

die() { fail "$*"; exit 1; }

command -v jq  >/dev/null || die "jq not found (brew install jq)"
command -v ssh >/dev/null || die "ssh not found"

[[ -f "$CONFIG" ]] || die "config not found: $CONFIG (run ./install.sh first)"

# --- read config exactly like bin/claude does ------------------------------
REMOTE_HOST=$(jq -er '.server.host' "$CONFIG") \
  || die "config: .server.host is required"
REMOTE_USER=$(jq -er '.server.user' "$CONFIG") \
  || die "config: .server.user is required"
REMOTE_PORT=$(jq -r '.server.port // 22' "$CONFIG")
PROXY_LOCAL_PORT=$(jq -r '.proxy.localPort // 8888' "$CONFIG")
PROXY_REMOTE_PORT=$(jq -r '.proxy.remotePort // 18080' "$CONFIG")

info "config @ $CONFIG"
echo "    server     : $REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT"
echo "    local port : $PROXY_LOCAL_PORT"
echo "    remote port: $PROXY_REMOTE_PORT"

# --- open (or reuse) ssh master --------------------------------------------
WE_OPENED_MASTER=0
mkdir -p "$WRAPPER_DIR"

if ssh -S "$CONTROL_SOCK" -O check "$REMOTE_USER@$REMOTE_HOST" >/dev/null 2>&1; then
  pass "ssh master already running ($CONTROL_SOCK)"
else
  [[ -S "$CONTROL_SOCK" ]] && rm -f "$CONTROL_SOCK"
  info "opening ssh master..."
  if ! ssh -M -S "$CONTROL_SOCK" -fN \
       -p "$REMOTE_PORT" \
       -o ExitOnForwardFailure=yes \
       -o ServerAliveInterval=30 \
       -o ServerAliveCountMax=3 \
       -o ConnectTimeout=10 \
       -L "127.0.0.1:$PROXY_LOCAL_PORT:127.0.0.1:$PROXY_REMOTE_PORT" \
       "$REMOTE_USER@$REMOTE_HOST"
  then
    die "failed to open ssh tunnel — fix SSH access first (try: ssh $REMOTE_USER@$REMOTE_HOST)"
  fi
  WE_OPENED_MASTER=1
  pass "ssh master opened"
fi

# If we opened it for this check, clean up at the end. If it was already up
# (wrapper/previous run), leave it alone — someone else is using it.
cleanup() {
  if [[ "$WE_OPENED_MASTER" -eq 1 ]]; then
    ssh -S "$CONTROL_SOCK" -O exit "$REMOTE_USER@$REMOTE_HOST" >/dev/null 2>&1 || true
    info "ssh master closed (we opened it, so we close it)"
  else
    warn "ssh master left running (it was up before this check)"
  fi
}
trap cleanup EXIT

# --- export env the way bin/claude does ------------------------------------
export HTTPS_PROXY="http://127.0.0.1:$PROXY_LOCAL_PORT"
export HTTP_PROXY="$HTTPS_PROXY"
export NO_PROXY="localhost,127.0.0.1,::1"
export https_proxy="$HTTPS_PROXY"
export http_proxy="$HTTP_PROXY"
export no_proxy="$NO_PROXY"

echo
info "env that wrapper would pass to claude:"
env | grep -Ei '^(HTTPS?_PROXY|NO_PROXY)=' | sed 's/^/    /'

# --- request via proxy ------------------------------------------------------
echo
info "curl https://api.ipify.org via the proxy..."
tmp=$(mktemp)
http_code=$(curl -sS --proxy "$HTTPS_PROXY" --max-time 15 \
                 -o "$tmp" -w '%{http_code}' \
                 https://api.ipify.org || echo "000")
proxy_ip=$(cat "$tmp"); rm -f "$tmp"

if [[ "$http_code" != "200" ]]; then
  fail "proxy request failed: HTTP $http_code"
  exit 1
fi
pass "HTTP $http_code, egress IP via proxy: ${BOLD}$proxy_ip${RESET}"

# --- baseline: direct request (may also hit Helsinki if you already route
# through it, that's fine — just shows both numbers)
echo
info "for comparison — curl https://api.ipify.org directly (no proxy):"
direct_ip=$(curl -sS --max-time 10 --noproxy '*' https://api.ipify.org || echo "error")
echo "    direct egress IP: $direct_ip"

echo
if [[ "$proxy_ip" == "$direct_ip" ]]; then
  warn "proxy and direct IPs are identical — this is fine if your mac itself"
  warn "already routes through the same exit (e.g. a system VPN to Helsinki)."
  warn "what this script DOES confirm: the wrapper-side tunnel is alive and"
  warn "carrying traffic; HTTP 200 came through your SSH + server + WG chain."
else
  pass "${BOLD}proxy reroutes traffic:${RESET} direct=$direct_ip, via-proxy=$proxy_ip"
fi
