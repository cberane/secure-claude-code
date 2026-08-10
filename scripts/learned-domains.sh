#!/usr/bin/env bash
# learned-domains — distill the domains actually USED since the last proxy
# restart into a paste-ready allowlist block. Counterpart of
# blocked-domains: that one reads denials, this one reads successes —
# meant for learning mode (make learn), where everything is allowed and
# logged. Always exits 0 (reporting tool, not a gate).

set -u

LOG="${EGRESS_LOG:-/var/log/egress/access.log}"
BASE="${EGRESS_BASE:-/var/log/egress/allowlist-base.txt}"

if [ ! -r "$LOG" ]; then
    echo "learned-domains: $LOG is not readable — is the egress-logs volume mounted?" >&2
    exit 0
fi

# Successful transactions only (TCP_TUNNEL = CONNECT, TCP_MISS/HIT = plain
# HTTP); extract the host, drop ports/paths/IP literals/single labels.
# Then subtract everything the baked-in allowlist already covers (exact
# entries and ".parent" wildcards) and aggregate hit counts.
report="$(awk -v base="$BASE" '
    BEGIN {
        nbase = 0
        while ((getline line < base) > 0) {
            sub(/#.*/, "", line); gsub(/[[:space:]]/, "", line)
            if (line != "") baselist[nbase++] = line
        }
        close(base)
    }
    function covered(h,   i, p) {
        for (i = 0; i < nbase; i++) {
            p = baselist[i]
            if (p == h) return 1
            if (substr(p, 1, 1) == ".") {
                if (h == substr(p, 2)) return 1
                if (length(h) > length(p) && substr(h, length(h) - length(p) + 1) == p) return 1
            }
        }
        return 0
    }
    $4 ~ /^TCP_(TUNNEL|MISS|HIT|REFRESH)/ {
        h = $7
        sub(/^[A-Za-z][A-Za-z0-9+.-]*:\/\//, "", h)
        sub(/\/.*$/, "", h); sub(/:[0-9]+$/, "", h)
        if (h !~ /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$/) next
        if (h ~ /^[0-9]+(\.[0-9]+){3}$/) next
        if (covered(h)) next
        count[h]++
    }
    END { for (h in count) printf "%d %s\n", count[h], h }
' "$LOG" | sort -rn)"

if [ -z "$report" ]; then
    echo "learned-domains: no domains beyond the baked-in allowlist were contacted since the last proxy restart."
    exit 0
fi

# Wildcard suggestions: >=3 distinct subdomains under one parent.
wildcards="$(printf '%s\n' "$report" | awk '
    { h = $2; if (h ~ /\..*\./) { parent = h; sub(/^[^.]+/, "", parent); seen[parent]++ } }
    END { for (p in seen) if (seen[p] >= 3) print p }' | sort)"

total="$(printf '%s\n' "$report" | wc -l)"
{
    echo
    echo "┌─ LEARNED DOMAINS ─────────────────────────────────────"
    echo "│ $total domain(s) used since the last proxy restart that"
    echo "│ the allowlist does not cover yet (hits · domain):"
    echo "│"
    printf '%s\n' "$report" | awk '{ printf "│   %5d   %s\n", $1, $2 }'
    if [ -n "$wildcards" ]; then
        echo "│"
        echo "│ Wildcard candidates (>=3 subdomains seen — verify the"
        echo "│ parent is a single organization before using them):"
        printf '%s\n' "$wildcards" | sed 's/^/│     /'
    fi
    echo "│"
    echo "│ Review, then append ONLY what the task really needs to"
    echo "│ egress/allowlist.txt and leave learning mode (this also"
    echo "│ rebakes the proxy with the new list):"
    echo "│"
    echo "│   make learn-off"
    echo "│"
    echo "│ Then RERUN the task under enforcement — stragglers show"
    echo "│ up via blocked-domains. Single-hit domains are often"
    echo "│ redirects or CDN noise; try omitting them first."
    echo "└───────────────────────────────────────────────────────"
} >&2

# Paste-ready block on stdout (comments carry the hit counts).
echo "# learned $(date -I 2>/dev/null || true) — curate before pasting:"
printf '%s\n' "$report" | awk '{ printf "%s\t# %d hits\n", $2, $1 }'
exit 0
