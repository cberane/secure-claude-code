#!/usr/bin/env bash
# renew-certs.sh — HOST-side: re-mint every dev-CA-issued project cert
# found under PROJECTS_DIR with a fresh CERT_DAYS (default 3 days) validity
# (docs/https.md).
#
# The certs themselves are the inventory: any */certs/*.crt whose issuer is
# our dev CA is renewed in place (same file names, current SAN policy,
# domain taken from the subject CN). Foreign certs are left alone.
#
#   --auto : hook form used by `make build/up/shell/claude/yolo` — silent
#            no-op when no dev CA is provisioned ("serves HTTPS" is simply
#            'make certificates' has been run).
set -euo pipefail

auto=0
[ "${1:-}" = "--auto" ] && auto=1

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
DEV_CA_DIR="${DEV_CA_DIR:-$repo_root/secrets/dev-ca}"

if [ ! -f "$DEV_CA_DIR/ca.key" ]; then
    [ "$auto" -eq 1 ] && exit 0
    echo "renew-certs: no dev CA yet — run 'make certificates' first." >&2
    exit 1
fi
command -v openssl >/dev/null 2>&1 || {
    echo "renew-certs: 'openssl' is required on the host." >&2; exit 1; }

# PROJECTS_DIR: environment first, then .env (quote-stripped like doctor).
if [ -z "${PROJECTS_DIR:-}" ] && [ -f "$repo_root/.env" ]; then
    PROJECTS_DIR="$(sed -n 's/^PROJECTS_DIR=//p' "$repo_root/.env" | tail -1 \
        | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")"
fi
if [ -z "${PROJECTS_DIR:-}" ] || [ ! -d "$PROJECTS_DIR" ]; then
    [ "$auto" -eq 1 ] && exit 0
    echo "renew-certs: PROJECTS_DIR is not set or not a directory (.env)." >&2
    exit 1
fi

renewed=0
skipped=0
while IFS= read -r crt; do
    # The CA copy mint-cert drops next to each leaf is not a leaf.
    [ "$(basename "$crt")" = "ca.crt" ] && continue
    issuer="$(openssl x509 -in "$crt" -noout -issuer 2>/dev/null || true)"
    case "$issuer" in
        *"claude-sandbox dev CA"*) ;;
        *) skipped=$((skipped + 1)); continue ;;
    esac
    domain="$(openssl x509 -in "$crt" -noout -subject -nameopt multiline 2>/dev/null \
        | sed -n 's/^ *commonName *= *//p')"
    if [ -z "$domain" ]; then
        echo "renew-certs: skipping $crt — no subject CN to re-mint from." >&2
        skipped=$((skipped + 1))
        continue
    fi
    stem="$(basename "$crt" .crt)"
    DEV_CA_DIR="$DEV_CA_DIR" "$script_dir/mint-cert.sh" \
        "$domain" "$(dirname "$crt")" "$stem" >/dev/null
    echo "renewed: $crt ($domain, ${CERT_DAYS:-3} days)"
    renewed=$((renewed + 1))
done < <(find "$PROJECTS_DIR" -maxdepth 3 -type f -path '*/certs/*.crt' 2>/dev/null | sort)

if [ "$renewed" -gt 0 ]; then
    echo "renew-certs: $renewed cert(s) renewed — running TLS servers keep the"
    echo "             old cert in memory; reload them (e.g. restart nginx)."
elif [ "$auto" -eq 0 ]; then
    echo "renew-certs: no dev-CA certs found under $PROJECTS_DIR (mint one with 'make cert DOMAIN=myapp.test')."
fi
