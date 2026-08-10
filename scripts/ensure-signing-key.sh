#!/usr/bin/env bash
# ensure-signing-key.sh — HOST-side, idempotent first-time provisioning of the
# dedicated commit-signing key. Called by `make up|claude|shell|yolo|keygen`.
#
# The container never generates or rotates keys; the signing mount stays
# read-only. All key lifecycle happens here, on the host.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
SIGNING_DIR="${SIGNING_DIR:-$repo_root/secrets/git-signing}"
KEY="$SIGNING_DIR/signing_key"
META="$SIGNING_DIR/key.meta"

# jq writes key.meta AFTER the key is generated — checked up front so a
# missing jq can never leave a key without its metadata behind.
command -v jq >/dev/null 2>&1 || {
    echo "ensure-signing-key: 'jq' is required on the host — install it, then rerun." >&2
    exit 1
}

# Principal for allowed_signers: GIT_AUTHOR_EMAIL from .env, else a fallback.
principal="${GIT_AUTHOR_EMAIL:-}"
if [ -z "$principal" ] && [ -f "$repo_root/.env" ]; then
    principal="$(sed -n 's/^GIT_AUTHOR_EMAIL=//p' "$repo_root/.env" | tail -1)"
fi
principal="${principal:-${USER:-dev}@$(hostname)}"

confirm_registration() {
    # Interactive only: mark the key as registered at the forge.
    if [ "${NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
        echo "Non-interactive run: register the key at your forge, then run 'make keygen' again to confirm."
        return 0
    fi
    printf 'Key registered at the forge as a SIGNING key? [y/N] '
    read -r answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        tmp="$(mktemp)"
        jq --arg ts "$(date -Is)" '.registered_at = $ts' "$META" > "$tmp"
        cat "$tmp" > "$META"
        rm -f "$tmp"
        echo "Recorded registered_at in key.meta."
    else
        echo "Skipped. You will be asked again on the next make invocation."
    fi
}

# --- already provisioned? -------------------------------------------------
if [ -f "$KEY" ]; then
    # Key without metadata = an earlier run died between keygen and meta
    # write. Never silently accept it: age enforcement depends on
    # created_at, and nothing downstream can repair the gap.
    if [ ! -f "$META" ]; then
        cat >&2 <<EOF
ensure-signing-key: $KEY exists but key.meta is missing — an earlier
provisioning run was interrupted (typically: jq was not installed).

If the key was never registered at your forge (the usual case), delete the
folder and rerun:

    rm -r $SIGNING_DIR && make keygen

If it IS registered, recreate the metadata instead:

    jq -n --arg c "\$(date -Is)" --arg f "\$(ssh-keygen -lf $KEY.pub | awk '{print \$2}')" \\
        '{created_at:\$c, fingerprint:\$f, registered_at:null, rotated_from:null}' > $META
EOF
        exit 1
    fi
    # Key exists. Stay silent — unless registration is still pending.
    if [ "$(jq -r '.registered_at' "$META" 2>/dev/null)" = "null" ]; then
        echo "Signing key exists but is not yet registered at your forge."
        echo
        echo "  Public key (add as SIGNING key, NOT authentication key):"
        echo
        sed 's/^/    /' "$KEY.pub"
        echo
        confirm_registration
    fi
    exit 0
fi

# --- first-time provisioning ----------------------------------------------
echo "Provisioning dedicated commit-signing key (host-side)..."
mkdir -p "$SIGNING_DIR"
chmod 0700 "$SIGNING_DIR"

ssh-keygen -t ed25519 -N "" -C "claude-code-signing $(date -I)" -f "$KEY" -q
chmod 0400 "$KEY"
chmod 0444 "$KEY.pub"

# allowed_signers: append (never overwrite — old keys must remain verifiable).
pubkey_line="$(cut -d' ' -f1-2 "$KEY.pub")"
printf '%s %s claude-code-signing\n' "$principal" "$pubkey_line" >> "$SIGNING_DIR/allowed_signers"
chmod 0444 "$SIGNING_DIR/allowed_signers"

fingerprint="$(ssh-keygen -lf "$KEY.pub" | awk '{print $2}')"
rotated_from="null"
if [ -n "${ROTATED_FROM:-}" ]; then
    rotated_from="\"$ROTATED_FROM\""
fi
jq -n \
    --arg created_at "$(date -Is)" \
    --arg fingerprint "$fingerprint" \
    --argjson rotated_from "$rotated_from" \
    '{created_at: $created_at, fingerprint: $fingerprint, registered_at: null, rotated_from: $rotated_from}' \
    > "$META"
chmod 0644 "$META"

cat <<EOF

┌─ NEW SIGNING KEY GENERATED ───────────────────────────
│ Fingerprint: $fingerprint
│ Location:    $SIGNING_DIR (host-only, gitignored)
│
│ Add this public key at your forge as a SIGNING KEY
│ (GitHub: Settings -> SSH and GPG keys -> New SSH key
│  -> Key type: "Signing Key". NOT an authentication key.)
│
$(sed 's/^/│   /' "$KEY.pub")
│
└───────────────────────────────────────────────────────

EOF
confirm_registration
