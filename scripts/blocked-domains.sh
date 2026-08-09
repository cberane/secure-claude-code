#!/usr/bin/env bash
# blocked-domains — report the domains the egress proxy has denied since its
# last restart, so the user can extend the allowlist on the host.
#
# Usage: blocked-domains [domain ...]
#   Extra arguments are live-probed through the proxy, so domains a task
#   NEEDS but has not tried yet can be included in the same report.
#
# Reads the squid access log from the shared egress-logs volume (mounted
# read-only at /var/log/egress; truncated at every proxy start). Always
# exits 0 — this is a reporting tool, not a gate.

set -u

LOG="${EGRESS_LOG:-/var/log/egress/access.log}"
PROXY="${https_proxy:-http://egress-proxy:3128}"

# --- denied domains from the access log -----------------------------------
# squid logformat: field 4 = %Ss/%03>Hs (e.g. TCP_DENIED/403), field 7 = %ru
# (CONNECT: "host:443"; plain HTTP: "http://host/path"). Bare IP literals
# are dropped: to_localnet denials are by design and dstdomain entries would
# not unblock them anyway. The hostname pattern requires at least one dot,
# which also drops single-label internal names (dind-daemon, ...) — those
# are compose service names, never something to put on the allowlist.
denied=""
if [ -r "$LOG" ]; then
    denied="$(awk '$4 ~ /^TCP_DENIED/ {print $7}' "$LOG" \
        | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#/.*$##; s#:[0-9]+$##' \
        | grep -E '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
        | grep -vE '^[0-9]+(\.[0-9]+){3}$')"
else
    echo "blocked-domains: note: $LOG is not readable — is the egress-logs volume mounted?" >&2
fi

# --- live-probe extra domains through the proxy ---------------------------
for d in "$@"; do
    out="$(curl -sS -o /dev/null -m 10 --proxy "$PROXY" "https://$d/" 2>&1)"
    rc=$?
    if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q '403'; then
        denied="$(printf '%s\n%s' "$denied" "$d")"
    fi
done

denied="$(printf '%s\n' "$denied" | sed '/^$/d' | sort -u)"

if [ -z "$denied" ]; then
    echo "blocked-domains: no blocked requests recorded since the last proxy restart."
    exit 0
fi

{
    echo
    echo "┌─ HOST ACTION REQUIRED ────────────────────────────────"
    echo "│ The egress proxy denied requests to these domains:"
    while IFS= read -r d; do
        echo "│   $d"
    done <<<"$denied"
    echo "│"
    echo "│ On the HOST, append each domain that is genuinely needed"
    echo "│ to egress/allowlist.txt, then reload the proxy:"
    echo "│"
    echo "│   make reload-egress"
    echo "│"
    echo "│ (Rebuilds and recreates only the proxy — this session and"
    echo "│  any nested containers keep running.)"
    echo "│"
    echo "│ WARNING: every allowlist entry is a potential exfiltration"
    echo "│ channel — add only what the task needs, and NEVER git hosts"
    echo "│ (push/pull are host-only by design)."
    echo "└───────────────────────────────────────────────────────"
} >&2
exit 0
