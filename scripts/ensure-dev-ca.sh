#!/usr/bin/env bash
# ensure-dev-ca.sh — HOST-side, idempotent provisioning of the local dev CA
# behind `make certificates` / `make cert` (docs/https.md).
#
# Same containment model as the signing key: the CA private key NEVER
# enters the sandbox — only public/ca.crt is mounted (read-only), and all
# leaf minting happens host-side (mint-cert.sh). Additionally the CA
# certificate carries CRITICAL X.509 name constraints (.test, dind,
# localhost, 127.0.0.1), which browsers enforce: even a stolen CA key
# cannot mint a working certificate for a real-world domain.
#
#   --show-trust : also print the one-time browser trust-install steps
#                  (used by `make certificates`; creation prints them anyway)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
DEV_CA_DIR="${DEV_CA_DIR:-$repo_root/secrets/dev-ca}"
CA_KEY="$DEV_CA_DIR/ca.key"
CA_CRT="$DEV_CA_DIR/public/ca.crt"
CA_META="$DEV_CA_DIR/ca.meta"
# ~4 years. Leaf certs are 3 days (mint-cert.sh); the CA itself rotates
# rarely — delete the folder and rerun `make certificates` to rotate
# (then re-install trust and `make renew-certs`).
CA_DAYS="${CA_DAYS:-1460}"

command -v openssl >/dev/null 2>&1 || {
    echo "ensure-dev-ca: 'openssl' is required on the host — install it, then rerun." >&2
    exit 1
}

show_trust() {
    local crt="$1"
    cat <<EOF

┌─ TRUST THE DEV CA (one-time, on the HOST) ────────────────────────────
│ Browsers must trust this CA once; its name constraints limit it to
│ .test domains, so the trust cannot be abused for real sites.
│
EOF
    if grep -qi microsoft /proc/version 2>/dev/null; then
        local winpath
        winpath="$(wslpath -w "$crt" 2>/dev/null || echo '<copy ca.crt to a Windows path>')"
        cat <<EOF
│ Windows (browsers run there under WSL2) — regular PowerShell/cmd:
│
│   certutil.exe -user -addstore Root "$winpath"
│
│ Remove later with:
│   certutil.exe -user -delstore Root "$(openssl x509 -in "$crt" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p')"
│
EOF
    fi
    cat <<EOF
│ Linux tools/browsers on this machine:
│
│   sudo cp $crt /usr/local/share/ca-certificates/claude-sandbox-dev-ca.crt
│   sudo update-ca-certificates
│
│ Firefox ignores the OS store by default:
│   about:config -> security.enterprise_roots.enabled -> true
│   (or import $crt under Settings -> Certificates)
└───────────────────────────────────────────────────────────────────────
EOF
}

# --- already provisioned? --------------------------------------------------
if [ -f "$CA_KEY" ] && [ -f "$CA_CRT" ]; then
    if [ "${1:-}" = "--show-trust" ]; then
        echo "Dev CA exists: $CA_CRT"
        show_trust "$CA_CRT"
    fi
    exit 0
fi
if [ -f "$CA_KEY" ] || [ -f "$CA_CRT" ]; then
    cat >&2 <<EOF
ensure-dev-ca: partial CA state in $DEV_CA_DIR (key or cert missing) — an
earlier provisioning run was interrupted. The CA carries no external
registration, so simply recreate it:

    rm -r "$DEV_CA_DIR" && make certificates

(then re-install browser trust and run 'make renew-certs')
EOF
    exit 1
fi

# --- first-time provisioning -----------------------------------------------
echo "Provisioning local dev CA (host-side)..."
mkdir -p "$DEV_CA_DIR/public"
chmod 0700 "$DEV_CA_DIR"

# P-256: small, universally supported. The name constraints are the core
# security property — keep the four subtrees in sync with mint-cert.sh's
# SAN list and doctor check 24/25.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$CA_KEY" -out "$CA_CRT" -days "$CA_DAYS" -sha256 \
    -subj "/CN=claude-sandbox dev CA $(date -I)" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -addext "nameConstraints=critical,permitted;DNS:test,permitted;DNS:dind,permitted;DNS:localhost,permitted;IP:127.0.0.1/255.255.255.255" \
    2>/dev/null
chmod 0400 "$CA_KEY"
chmod 0444 "$CA_CRT"

fingerprint="$(openssl x509 -in "$CA_CRT" -noout -fingerprint -sha256 | cut -d= -f2)"
jq -n \
    --arg created_at "$(date -Is)" \
    --arg fingerprint "$fingerprint" \
    --arg not_after "$(openssl x509 -in "$CA_CRT" -noout -enddate | cut -d= -f2)" \
    '{created_at: $created_at, fingerprint: $fingerprint, not_after: $not_after}' \
    > "$CA_META" 2>/dev/null || true
chmod 0644 "$CA_META" 2>/dev/null || true

cat <<EOF

┌─ NEW DEV CA GENERATED ────────────────────────────────────────────────
│ Fingerprint: sha256 $fingerprint
│ Location:    $DEV_CA_DIR (host-only, gitignored)
│ Constraints: .test, dind, localhost, 127.0.0.1 (critical — enforced
│              by browsers; useless for any real-world domain)
│ Key:         host-only. The sandbox sees ONLY public/ca.crt.
└───────────────────────────────────────────────────────────────────────
EOF
show_trust "$CA_CRT"
