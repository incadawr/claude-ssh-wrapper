#!/usr/bin/env bash
# Read-only stability logger for the server side of the claude tunnel.
# Appends one status line per run to /var/log/wg-tunnel-stat.log and exits.
# It changes nothing — only observes — so it is safe to run from cron.
#
# Deploy: copy to /usr/local/bin/wg-tunnel-stat.sh on the proxy server,
#         chmod 755, and add to root crontab:  * * * * * /usr/local/bin/wg-tunnel-stat.sh
#
# No `set -e`/`pipefail` on purpose: the script must finish and log a line
# even when a probe command fails — failing probes are the whole point.
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

IFACE=wg-tunnel          # WireGuard tunnel to the upstream exit (Hetzner)
PEER=10.88.88.1          # tunnel-internal IP of the upstream peer
LOG=/var/log/wg-tunnel-stat.log

ts=$(date '+%Y-%m-%d %H:%M:%S')
xray=$(systemctl is-active xray 2>/dev/null || true)

if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "$ts FAIL iface=DOWN xray=$xray" >> "$LOG"
else
    hs=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    age=$(( $(date +%s) - ${hs:-0} ))
    read -r _ rx tx <<<"$(wg show "$IFACE" transfer 2>/dev/null)"

    if ping -c1 -W3 "$PEER" >/dev/null 2>&1; then ping_st=ok; else ping_st=FAIL; fi

    # e2e: drive a request through the exact path Xray uses for claude
    # (http inbound 127.0.0.1:18080 -> direct outbound -> wg-tunnel -> upstream).
    e2e=$(curl -s -o /dev/null -w '%{http_code}/%{time_total}' --max-time 12 \
          --proxy http://127.0.0.1:18080 https://api.anthropic.com/ 2>/dev/null \
          || echo "000/timeout")

    status=OK
    [ "$ping_st" = FAIL ] && status=FAIL
    case "$e2e" in 000/*) status=FAIL;; esac

    echo "$ts $status iface=up hs_age=${age}s ping=$ping_st e2e=$e2e xray=$xray rx=${rx:-?} tx=${tx:-?}" >> "$LOG"
fi

# keep the log bounded (~10000 lines ≈ 1 week at one run per minute)
tail -n 10000 "$LOG" 2>/dev/null > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
