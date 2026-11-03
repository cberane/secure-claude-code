#!/usr/bin/env bash
# rotate-signing-key.sh — HOST-side, interactive rotation of the signing key.
#
# Guarantees that HISTORICAL COMMITS REMAIN VERIFIABLE: the old public key is
# never removed from allowed_signers; instead its entry is bounded with a
# valid-before timestamp and the new key is appended with valid-after.
# Git verifies signatures against the commit timestamp, so old commits keep
# matching the old key's validity window.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
SIGNING_DIR="${SIGNING_DIR:-$repo_root/secrets/git-signing}"
KEY="$SIGNING_DIR/signing_key"
META="$SIGNING_DIR/key.meta"
SIGNERS="$SIGNING_DIR/allowed_signers"

[ -f "$KEY" ] || { echo "No signing key at $SIGNING_DIR — nothing to rotate. Run 'make keygen' first." >&2; exit 1; }
[ -f "$META" ] || { echo "key.meta missing — cannot rotate safely." >&2; exit 1; }

old_fingerprint="$(jq -r '.fingerprint' "$META")"
old_created="$(jq -r '.created_at' "$META")"
old_registered="$(jq -r '.registered_at // "never"' "$META")"
old_pub_material="$(cut -d' ' -f1-2 "$KEY.pub")"

cat <<EOF
┌─ SIGNING KEY ROTATION ────────────────────────────────
│ Current key:
│   Fingerprint: $old_fingerprint
│   Created:     $old_created
│   Registered:  $old_registered
│
│ This will: archive the current key, generate a new one,
│ extend allowed_signers with validity windows, and guide
│ you through registering the new key at your forge.
└───────────────────────────────────────────────────────
EOF
printf 'Proceed? [y/N] '
read -r answer
[ "$answer" = "y" ] || [ "$answer" = "Y" ] || { echo "Aborted."; exit 1; }

# Rotation timestamp — used for BOTH the old key's valid-before and the new
# key's valid-after, at second precision so same-day commits verify correctly.
rotation_ts="$(date -u +%Y%m%d%H%M%SZ)"

# --- 1. archive the old key (never delete) --------------------------------
archive_dir="$SIGNING_DIR/archive/$(echo "$old_fingerprint" | tr ':/+' '___')"
mkdir -p "$archive_dir"
cp "$META" "$archive_dir/key.meta"
chmod 0600 "$KEY"  # make movable
mv "$KEY" "$KEY.pub" "$archive_dir/"
chmod 0400 "$archive_dir/signing_key"
echo "Archived old key to $archive_dir"

# --- 2. bound the old key's validity window in allowed_signers ------------
# Find the line carrying the old public key; add valid-before (and a
# valid-after of its creation date if it had no options yet).
old_created_ts="$(date -u -d "$old_created" +%Y%m%d%H%M%SZ)"
tmp="$(mktemp)"
while IFS= read -r line; do
    case "$line" in
        *"${old_pub_material#* }"*)
            if [[ "$line" == *valid-before=* ]]; then
                printf '%s\n' "$line"
            elif [[ "$line" == *valid-after=* ]]; then
                printf '%s\n' "${line/valid-after=/valid-before=\"$rotation_ts\",valid-after=}"
            else
                # "principal keytype key comment" -> insert options after principal
                printf '%s\n' "$(printf '%s' "$line" | sed "s/ / valid-after=\"$old_created_ts\",valid-before=\"$rotation_ts\" /")"
            fi
            ;;
        *) printf '%s\n' "$line" ;;
    esac
done < "$SIGNERS" > "$tmp"
chmod 0644 "$SIGNERS" 2>/dev/null || true
cat "$tmp" > "$SIGNERS"
rm -f "$tmp"

# --- 3. generate the new key ----------------------------------------------
principal="${GIT_AUTHOR_EMAIL:-}"
if [ -z "$principal" ] && [ -f "$repo_root/.env" ]; then
    principal="$(sed -n 's/^GIT_AUTHOR_EMAIL=//p' "$repo_root/.env" | tail -1)"
fi
principal="${principal:-${USER:-dev}@$(hostname)}"

ssh-keygen -t ed25519 -N "" -C "claude-code-signing $(date -I)" -f "$KEY" -q
chmod 0400 "$KEY"
chmod 0444 "$KEY.pub"

new_pub_material="$(cut -d' ' -f1-2 "$KEY.pub")"
printf '%s valid-after="%s" %s claude-code-signing\n' \
    "$principal" "$rotation_ts" "$new_pub_material" >> "$SIGNERS"
chmod 0444 "$SIGNERS"

new_fingerprint="$(ssh-keygen -lf "$KEY.pub" | awk '{print $2}')"
jq -n \
    --arg created_at "$(date -Is)" \
    --arg fingerprint "$new_fingerprint" \
    --arg rotated_from "$old_fingerprint" \
    '{created_at: $created_at, fingerprint: $fingerprint, registered_at: null, rotated_from: $rotated_from}' \
    > "$META"
chmod 0644 "$META"

# --- 4. guide the forge update --------------------------------------------
cat <<EOF

┌─ NEW SIGNING KEY — REGISTER AT YOUR FORGE ────────────
│ New fingerprint: $new_fingerprint
│
│ GitHub:  Settings -> SSH and GPG keys -> New SSH key
│          Key type: "Signing Key" -> paste the key below.
│ GitLab:  Preferences -> SSH Keys -> Usage type: "Signing"
│
│ Add the NEW key FIRST. Then KEEP the old key ($old_fingerprint)
│ registered as a Signing Key — the forge verifies commits at PUSH
│ time, so commits pushed while the old key is unregistered arrive
│ as "unverified" and can only be repaired by re-registering it.
│
│ Keep the old key online until every commit signed with it is
│ pushed AND shows Verified (recommendation: about 1 week grace),
│ then delete it — already-verified commits stay Verified.
│ No "Valid until" exists for SSH keys: track removal manually.
│
$(sed 's/^/│   /' "$KEY.pub")
│
└───────────────────────────────────────────────────────

EOF
printf 'New key registered at the forge? [y/N] '
read -r answer
if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    tmp="$(mktemp)"
    jq --arg ts "$(date -Is)" '.registered_at = $ts' "$META" > "$tmp"
    cat "$tmp" > "$META"
    rm -f "$tmp"
    echo "Recorded registered_at in key.meta."
else
    echo "Not confirmed — you will be reminded on the next make invocation."
fi

echo
echo "Rotation complete. Restart the sandbox to pick up the new key:"
echo
echo "  make restart"
