#!/usr/bin/env bash
# mint-cert.sh — HOST-side: mint a short-lived TLS leaf certificate for a
# .test dev domain, signed by the local dev CA (docs/https.md).
#
#   mint-cert.sh <domain> <out-dir> [basename]
#
# Called by `make cert DOMAIN=... [DIR=...]` and by renew-certs.sh. Leafs
# are deliberately short-lived (CERT_DAYS, default 3 days — long enough to
# survive a weekend YOLO session); renewal is automatic on make
# build/up/session start and manual via `make renew-certs`.
set -euo pipefail

usage="usage: mint-cert.sh <domain> <out-dir> [basename]   (make cert DOMAIN=myapp.test [DIR=subdir])"
domain="${1:?$usage}"
out_dir="${2:?$usage}"
base="${3:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
DEV_CA_DIR="${DEV_CA_DIR:-$repo_root/secrets/dev-ca}"
CA_KEY="$DEV_CA_DIR/ca.key"
CA_CRT="$DEV_CA_DIR/public/ca.crt"
CERT_DAYS="${CERT_DAYS:-3}"

command -v openssl >/dev/null 2>&1 || {
    echo "mint-cert: 'openssl' is required on the host." >&2; exit 1; }
if [ ! -f "$CA_KEY" ] || [ ! -f "$CA_CRT" ]; then
    echo "mint-cert: no dev CA at $DEV_CA_DIR — run 'make certificates' first." >&2
    exit 1
fi

# The CA's name constraints only permit .test — reject anything else here,
# with an explanation, instead of minting a cert every browser will refuse.
case "$domain" in
    test|*.test) ;;
    *)
        echo "mint-cert: '$domain' is outside the dev CA's name constraints." >&2
        echo "           Only .test domains can be minted (browsers enforce the" >&2
        echo "           constraint, so anything else would be rejected anyway)." >&2
        exit 1
        ;;
esac

# SANs: the domain, everything one label below it (so subdomains never need
# a re-mint), plus fixed names for testing: `dind` (in-sandbox curl against
# the dind-published port) and localhost/127.0.0.1 (host browser without a
# hosts-file entry). All four subtrees are permitted by the CA constraints.
if [ "${domain#\*.}" != "$domain" ]; then
    san="DNS:$domain,DNS:${domain#\*.}"
else
    san="DNS:$domain,DNS:*.$domain"
fi
san="$san,DNS:dind,DNS:localhost,IP:127.0.0.1"

base="${base:-${domain//\*/_wildcard}}"
key="$out_dir/$base.key"
crt="$out_dir/$base.crt"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$tmp/key" -out "$tmp/csr" -subj "/CN=$domain" 2>/dev/null

cat > "$tmp/ext" <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = $san
EOF

openssl x509 -req -in "$tmp/csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -days "$CERT_DAYS" -sha256 -set_serial "0x$(openssl rand -hex 16)" \
    -extfile "$tmp/ext" -out "$tmp/crt" 2>/dev/null

mkdir -p "$out_dir"
# Key readable only by the owner; the sandbox/dind run under the same UID.
install -m 0600 "$tmp/key" "$key"
install -m 0644 "$tmp/crt" "$crt"
# Public CA cert alongside, for stacks that want to trust it in-container
# (e.g. an app calling its own https:// URL). Never the key.
install -m 0644 "$CA_CRT" "$out_dir/ca.crt"

not_after="$(openssl x509 -in "$crt" -noout -enddate | cut -d= -f2)"
echo "minted: $crt"
echo "        key: $key  (valid $CERT_DAYS days, until $not_after)"
echo "        SANs: $san"
echo "note: a running TLS server keeps the old cert in memory — reload it"
echo "      after a (re)mint, e.g.: docker compose restart nginx / nginx -s reload"
