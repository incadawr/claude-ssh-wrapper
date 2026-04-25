#!/usr/bin/env bash
# claude-tunnel.30s.sh — SwiftBar/xbar plugin showing claude-ssh-wrapper
# tunnel health in the macOS menu bar.
#
# Filename suffix `.30s.sh` controls refresh interval (every 30 seconds).
# Compatible with both SwiftBar (https://swiftbar.app) and xbar (xbarapp.com).
#
# Install (SwiftBar):
#   1. brew install --cask swiftbar
#   2. Open SwiftBar, choose a plugins folder (default: ~/Library/Application Support/SwiftBar)
#   3. ln -s "$PWD/extras/swiftbar/claude-tunnel.30s.sh" \
#           "$HOME/Library/Application Support/SwiftBar/claude-tunnel.30s.sh"
#   4. SwiftBar menu → Refresh All
#
# The plugin only READS state (tunnel.log + watchdog.pid). It does not open
# the tunnel or spawn anything — that's still the wrapper's job.
set -uo pipefail

LOG_FILE="$HOME/.claude-wrapper/tunnel.log"
PID_FILE="$HOME/.claude-wrapper/watchdog.pid"
DOCTOR="$HOME/bin/claude-doctor"
WRAPPER="$HOME/bin/claude"

emit_header() { printf '%s\n' "$1"; printf '%s\n' "---"; }

# --- early exit: nothing installed yet -------------------------------------
if [[ ! -f "$LOG_FILE" ]]; then
  emit_header "⚪ tunnel?"
  echo "claude-ssh-wrapper not yet run | color=gray"
  echo "no log at $LOG_FILE | color=gray font=Menlo size=11"
  exit 0
fi

# --- parse last log line ---------------------------------------------------
last_line=$(tail -n 1 "$LOG_FILE" 2>/dev/null || true)

if [[ -z "$last_line" ]]; then
  emit_header "⚪ tunnel?"
  echo "tunnel.log is empty | color=gray"
  exit 0
fi

last_ts=$(printf '%s' "$last_line" | awk '{print $1}')
last_level=$(printf '%s' "$last_line" | awk '{print $2}')
last_msg=$(printf '%s' "$last_line" | cut -d' ' -f3-)

# Strip the timezone suffix (`+0300`/`-0500`); BSD date -j -f can't parse %z.
ts_no_tz="${last_ts%[+-]*}"
last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$ts_no_tz" "+%s" 2>/dev/null || echo 0)
now_epoch=$(date "+%s")
age=$(( now_epoch - last_epoch ))

# --- watchdog presence -----------------------------------------------------
watchdog_alive=0
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
  watchdog_alive=1
fi

# --- decide indicator ------------------------------------------------------
# A log line older than 90s means the watchdog isn't writing — either it died
# or someone shut down the machine and we're showing leftovers.
if [[ "$watchdog_alive" -eq 0 ]]; then
  icon="🟡"; short="off"
elif [[ "$age" -gt 90 ]]; then
  icon="🟡"; short="stale"
elif [[ "$last_level" == "OK" ]]; then
  icon="🟢"
  # Watchdog logs `time=0.192565s`; render as `192ms` for menubar brevity.
  latency_s=$(printf '%s' "$last_msg" | grep -oE 'time=[0-9.]+s' | head -1 \
              | sed 's/time=//; s/s$//')
  if [[ -n "$latency_s" ]]; then
    short=$(awk -v t="$latency_s" 'BEGIN{ printf "%dms", t * 1000 }')
  else
    short="ok"
  fi
elif [[ "$last_level" == "FAIL" ]]; then
  icon="🔴"; short="fail"
elif [[ "$last_level" == "STOP" ]]; then
  icon="⚪"; short="stopped"
elif [[ "$last_level" == "START" ]]; then
  icon="🟢"; short="starting"
else
  icon="⚫"; short="?"
fi

emit_header "$icon $short"

# --- dropdown: status block ------------------------------------------------
echo "claude-ssh-wrapper | font=Menlo"
if [[ "$watchdog_alive" -eq 1 ]]; then
  echo "watchdog: running (pid=$(cat "$PID_FILE")) | color=gray"
else
  echo "watchdog: not running | color=gray"
fi
echo "last entry: ${age}s ago — $last_level | color=gray"
echo "---"

# --- dropdown: recent log lines --------------------------------------------
echo "Recent log:"
# Pipe `|` is SwiftBar's separator between text and params. The watchdog
# never writes pipes, but be defensive and strip any to avoid parsing bugs.
tail -n 8 "$LOG_FILE" 2>/dev/null | tr '|' '¦' | while IFS= read -r line; do
  printf '%s | font=Menlo color=gray size=11\n' "$line"
done
echo "---"

# --- dropdown: actions -----------------------------------------------------
if [[ -x "$DOCTOR" ]]; then
  echo "Run claude-doctor | shell=$DOCTOR terminal=true refresh=true"
fi
echo "Tail tunnel.log | shell=tail param1=-f param2=$LOG_FILE terminal=true"
echo "Open tunnel.log | shell=open param1=$LOG_FILE"
if [[ -x "$WRAPPER" ]]; then
  echo "Reopen tunnel (claude --version) | shell=$WRAPPER param1=--version terminal=true refresh=true"
fi
echo "---"
echo "Refresh | refresh=true"
