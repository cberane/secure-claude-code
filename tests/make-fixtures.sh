#!/usr/bin/env bash
# make-fixtures.sh — generate key.meta test fixtures for doctor.sh checks
# 16 and 17. Dates are computed at runtime relative to "now" so the fixtures
# never go stale. The real key.meta is NEVER touched.
#
# Usage: make-fixtures <target-dir>
#   creates <target-dir>/warn/key.meta    (created_at 31 days ago)
#           <target-dir>/expired/key.meta (created_at 46 days ago)
set -euo pipefail

target="${1:?usage: make-fixtures <target-dir>}"

write_meta() {
    local dir="$1" days_ago="$2"
    mkdir -p "$dir"
    jq -n \
        --arg created_at "$(date -Is -d "$days_ago days ago")" \
        --arg fingerprint "SHA256:doctorfixturefingerprint0000000000000000000" \
        '{created_at: $created_at, fingerprint: $fingerprint,
          registered_at: $created_at, rotated_from: null}' \
        > "$dir/key.meta"
}

write_meta "$target/warn" 31
write_meta "$target/expired" 46
