#!/usr/bin/env bash
# Signing-key age check — single source of truth for the rotation policy.
#
# Called from three places:
#   1. make claude / make shell (host, --context session)
#   2. scripts/doctor.sh          (--context doctor)
#   3. git-hooks/pre-commit       (container, --context precommit)
#
# Age is ALWAYS computed from key.meta -> created_at, never from file mtime
# (mtime is unreliable across mounts and copies).
#
# Exit codes: 0 = ok, 1 = warn threshold reached, 2 = max threshold reached
# (callers decide what to do; only the pre-commit hook turns 2 into an abort).
set -u

CONTEXT=ok
case "${1:-}" in
    --context) CONTEXT="${2:-session}" ;;
esac

WARN_DAYS="${SIGNING_KEY_WARN_DAYS:-30}"
MAX_DAYS="${SIGNING_KEY_MAX_DAYS:-45}"
ENFORCE="${SIGNING_KEY_ENFORCE:-true}"
MARKER="${KEY_AGE_MARKER:-/tmp/.signing-key-age-warned}"

# Locate key.meta: explicit override > container mount > host repo layout.
if [ -n "${KEY_META_PATH:-}" ]; then
    META="$KEY_META_PATH"
elif [ -f /run/secrets/git-signing/key.meta ]; then
    META=/run/secrets/git-signing/key.meta
else
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    META="$script_dir/../secrets/git-signing/key.meta"
fi

if [ ! -f "$META" ]; then
    echo "check-key-age: $META not found — run 'make keygen' on the HOST first." >&2
    exit 0
fi

created_at="$(jq -r '.created_at // empty' "$META" 2>/dev/null)"
fingerprint="$(jq -r '.fingerprint // "unknown"' "$META" 2>/dev/null)"
registered_at="$(jq -r '.registered_at // "not yet registered"' "$META" 2>/dev/null)"

if [ -z "$created_at" ]; then
    echo "check-key-age: $META has no created_at field — regenerate with 'make keygen'." >&2
    exit 0
fi

now_s="$(date +%s)"
created_s="$(date -d "$created_at" +%s 2>/dev/null || echo "$now_s")"
age_days=$(( (now_s - created_s) / 86400 ))

print_block() {
    local color="$1" title="$2" tail="$3"
    printf '%b' "$color" >&2
    cat >&2 <<EOF
┌─ ${title} ────────────────────────────
│ Key age: ${age_days} days (fingerprint ${fingerprint})
│ Registered: ${registered_at}
│
│ Run on the HOST, then confirm here:
│
│   make rotate-signing-key
│
${tail}└───────────────────────────────────────────────────────
EOF
    printf '%b' '\033[0m' >&2
}

if [ "$age_days" -ge "$MAX_DAYS" ]; then
    if [ "$ENFORCE" = "false" ]; then
        print_block '\033[31m' 'SIGNING KEY ROTATION OVERDUE (enforcement disabled)' \
"│ SIGNING_KEY_ENFORCE=false — commits are still allowed.
│ Re-enable enforcement as soon as the key is rotated.
"
        exit 1
    fi
    print_block '\033[31m' 'SIGNING KEY ROTATION OVERDUE' \
"│ Key is older than ${MAX_DAYS} days — commits are blocked.
│ (Emergency override: SIGNING_KEY_ENFORCE=false in .env — do not
│  make that permanent.)
"
    exit 2
fi

if [ "$age_days" -ge "$WARN_DAYS" ]; then
    # In pre-commit context, warn only once per session (marker on tmpfs) so
    # YOLO runs are not spammed on every commit.
    if [ "$CONTEXT" = "precommit" ] && [ -e "$MARKER" ]; then
        exit 1
    fi
    print_block '\033[33m' 'SIGNING KEY ROTATION DUE' ''
    [ "$CONTEXT" = "precommit" ] && touch "$MARKER" 2>/dev/null
    exit 1
fi

exit 0
