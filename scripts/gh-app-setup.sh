#!/usr/bin/env bash
# gh-app-setup.sh — create + wire the per-project GitHub App via the App
# Manifest flow (docs/github.md, "Setup"). GitHub has no REST endpoint for
# creating Apps or generating keys — the manifest flow is the documented
# scripted equivalent: a tiny local page auto-submits the manifest, the
# user presses "Create GitHub App" (one browser click) and "Install → only
# this repo" (second click), and the local /cb callback captures the
# one-time code that POST /app-manifests/{code}/conversions converts into
# the app ID and the PEM.
#
#   scripts/gh-app-setup.sh <repo-path> [name]
#
# Requires an existing .secure-container/ (make add-workspace PROJECT=…).
# Writes:
#   ~/.config/secure-container/github-apps/<slug>.pem   (mode 600, host-only)
#   <repo>/.secure-container/workspace.env   GITHUB_APP_ID / _INSTALLATION_ID /
#                                            GITHUB_REPO (committed, not secret)
#   workspaces/secrets.env                   GITHUB_APP_KEY_PATH (machine-local)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

die() { printf 'gh-app-setup: %s\n' "$*" >&2; exit 1; }
info() { printf 'gh-app-setup: %s\n' "$*"; }

# Minimal quoted-value reader + setter (same reader semantics as workspace.sh).
env_get() {
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | tail -1 \
        | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}
env_set() { # env_set <file> <key> <value> — replace, or append past templates
    local file="$1" key="$2" value="$3"
    [ -f "$file" ] || : > "$file"
    sed -i "/^#*$key=/d" "$file"
    printf '%s=%s\n' "$key" "$value" >> "$file"
}

# Shared wiring: with app id + PEM known (either flow), finish the job —
# probe the installation id, write profile + secrets, print the summary.
wire_install() { # wire_install <app_id> <slug> <owner_repo> <pem_path> <sc-dir>
    local app_id="$1" slug="$2" owner_repo="$3" pem_path="$4" sc="$5"
    local inst_id="" install_url="https://github.com/apps/$slug/installations/new"

    for _ in 1 2 3 4 5 6; do
        local jwt
        jwt="$(scripts/mint-github-token.sh jwt "$pem_path" "$app_id" 2>/dev/null || true)"
        if [ -n "$jwt" ] && [ "$(printf '%s' "$jwt" | awk -F. '{print NF}')" = 3 ]; then
            inst_id="$(curl -sS -m 30 \
                -H "Authorization: Bearer $jwt" \
                -H "Accept: application/vnd.github+json" \
                "https://api.github.com/app/installations" \
                | jq -r '.[0].id // empty' 2>/dev/null || true)"
            [ -n "$inst_id" ] && { info "installation found: $inst_id"; break; }
        fi
        info "installation not visible yet — finish the browser step (install: $install_url); re-probing in 30 s…"
        sleep 30
    done

    env_set "$sc/workspace.env" GITHUB_APP_ID "$app_id"
    env_set "$sc/workspace.env" GITHUB_REPO "$owner_repo"
    if [ -n "$inst_id" ]; then
        env_set "$sc/workspace.env" GITHUB_INSTALLATION_ID "$inst_id"
    else
        printf '\n# gh-app-setup: finish the install at %s, then set:\n#GITHUB_INSTALLATION_ID=<numeric id>\n' \
            "$install_url" >> "$sc/workspace.env"
        info "no installation yet — set GITHUB_INSTALLATION_ID in $sc/workspace.env (or rerun)"
    fi
    env_set workspaces/secrets.env GITHUB_APP_KEY_PATH "$pem_path"

    cat >&2 <<EOF

✔ App wired:
    app:           $slug ($app_id)
    key:           $pem_path (0600, host-only, never committed)
    profile:       $sc/workspace.env (GITHUB_APP_ID, GITHUB_REPO${inst_id:+, GITHUB_INSTALLATION_ID})
    secrets.env:   GITHUB_APP_KEY_PATH

Next:
    make workspace NAME=<name>
    make gh-token        # or: make gh-renew (long session)
EOF
}

# --- rescue mode: a PEM was manually generated/downloaded for an app whose
# --- manifest creation SUCCEEDED but whose exchange failed (or a key created
# --- later via the app's settings page, the official fallback).
#   gh-app-setup.sh --wire <pem-path> <repo-path>
if [ "${1:-}" = "--wire" ]; then
    app_id_in="${APP_ID:-}"
    pem_in="${2:-}"
    repo="${3:-}"
    [ -n "$pem_in" ] && [ -n "$repo" ] \
        || die "usage: make gh-app-wire PROJECT=~/projects/<repo> KEY=<path-to-app.pem> [APP_ID=<numeric app id>]"
    pem_in="${pem_in/#\~/$HOME}"
    repo="${repo/#\~/$HOME}"
    [ -f "$pem_in" ] || die "PEM not found at '$pem_in'"
    head -1 "$pem_in" | grep -q 'PRIVATE KEY' || die "'$pem_in' is not a private key (.pem)"
    [ -d "$repo" ] || die "repo path '$repo' does not exist"
    repo="$(cd "$repo" && pwd)"
    sc="$repo/.secure-container"
    [ -f "$sc/workspace.env" ] || die "$sc missing — run 'make add-workspace PROJECT=$repo' first"
    owner_repo="$(printf '%s' "$(git -C "$repo" remote get-url origin 2>/dev/null || true)" \
        | sed -E 's#^(https?|ssh)://[^/@]+@?github\.com[:/]##; s#^git@github\.com:##; s#\.git$##' \
        | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || true)"
    [ -n "$owner_repo" ] || die "no github origin in $repo"

    for tool in curl jq; do
        command -v "$tool" >/dev/null || die "$tool is required"
    done

    # Adopt the key: copy into the managed key dir from wherever it came.
    key_dir="$HOME/.config/secure-container/github-apps"
    mkdir -p "$key_dir"
    pem_path="$key_dir/$(basename "$pem_in" .pem).pem"
    cp -a "$pem_in" "$pem_path"
    chmod 600 "$pem_path"

    # Identify the app: JWT auth needs the REAL app id as iss — there is no
    # lookup-by-key endpoint on GitHub. The id is shown on the app's info
    # page ("App ID" in the About box).
    if [ -z "$app_id_in" ]; then
        cat >&2 <<EOF
gh-app-setup: the App ID is needed to authenticate as the app (JWT 'iss').
Open https://github.com/settings/apps/ and your app's page — the About
box lists 'App ID' as a number. Then rerun with APP_ID=that number:
    make gh-app-wire PROJECT=$repo KEY=$pem_in APP_ID=<id>
EOF
        exit 1
    fi
    jwt="$(scripts/mint-github-token.sh jwt "$pem_path" "$app_id_in" 2>/dev/null)" \
        || die "could not sign a JWT with $pem_path (bad key?)"
    [ -n "$jwt" ] && [ "$(printf '%s' "$jwt" | awk -F. '{print NF}')" = 3 ] \
        || die "JWT signing failed"
    app_json="$(curl -sS -m 30 -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app")" \
        || die "GET /app failed (network?)"
    printf '%s' "$app_json" | jq -e --argjson want "$app_id_in" '.id == $want and .slug' >/dev/null 2>&1 \
        || die "GET /app with App ID $app_id_in did not match (check the ID/key pair): $(printf '%s' "$app_json" | head -c 300)"
    app_id="$(printf '%s' "$app_json" | jq -r .id)"
    slug="$(printf '%s' "$app_json" | jq -r .slug)"
    info "identified app by key: $slug (id $app_id)"
    wire_install "$app_id" "$slug" "$owner_repo" "$pem_path" "$sc"
    exit 0
fi

path="${1:-}"
[ -n "$path" ] || die "usage: make gh-app PROJECT=~/projects/<repo> [WS=<app-name>] | make gh-app-wire PROJECT=<repo> KEY=<pem>"
path="${path/#\~/$HOME}"
[ -d "$path" ] || die "project path '$path' does not exist"
path="$(cd "$path" && pwd)"
sc="$path/.secure-container"
[ -f "$sc/workspace.env" ] || die "$sc missing — run 'make add-workspace PROJECT=$path' first"

# --- 1. identity from the origin remote --------------------------------------
app_name="${2:-}"
origin="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
[ -n "$origin" ] || die "no 'origin' remote in $path"
owner_repo="$(printf '%s' "$origin" \
    | sed -E 's#^(https?|ssh)://[^/@]+@?github\.com[:/]##; s#^git@github\.com:##' \
    | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || true)"
printf '%s' "$owner_repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
    || die "could not parse owner/repo from origin '$origin'"
owner="${owner_repo%%/*}"
repo_name="${owner_repo##*/}"
# App names are unique across ALL of GitHub — suffix a short random tag.
[ -n "$app_name" ] \
    || app_name="$(printf '%s-%04x' \
        "$(printf '%s' "$repo_name" | cut -c1-24)" \
        "$(( ($$ % 409) + 40302 ))" | sed 's/[^A-Za-z0-9-]/-/g')"

for tool in python3 curl jq; do
    command -v "$tool" >/dev/null || die "$tool is required (local listener, API call, JSON parsing)"
done

# --- 2. build the manifest ------------------------------------------------------
homepage="https://github.com/$owner_repo"
port="$(( ( $$ % 3000 ) * 2 + 5000 ))"
redirect="http://127.0.0.1:$port/cb"
key_dir="$HOME/.config/secure-container/github-apps"
manifest="$(jq -cn \
    --arg name "$app_name" --arg url "$homepage" --arg redirect "$redirect" \
    --arg desc "Secure-sandbox automation for $owner_repo — per-project app, 1h tokens (docs in repo)" \
    '{name: $name, url: $url, description: $desc,
      hook_attributes: {url: $url, active: false},
      redirect_url: $redirect, public: false,
      default_permissions: {contents: "write", pull_requests: "write",
                            issues: "write", administration: "write"}}')"
printf '%s' "$manifest" | jq -e '.default_permissions.contents == "write"' >/dev/null \
    || die "manifest build failed"

# --- 3. local listener: /start = auto-submit page, /cb = capture the code -------
tmpd="$(mktemp -d /tmp/gh-app-setup.XXXXXX)"
srv=""
trap 'rm -rf "$tmpd"; [ -n "$srv" ] && kill "$srv" 2>/dev/null || true' EXIT
mkdir -p "$tmpd"
printf '%s' "$manifest" > "$tmpd/manifest.json"
: > "$tmpd/code.txt"

cat > "$tmpd/server.py" <<'PYEOF'
import http.server, sys, os, pathlib, urllib.parse
tmpd = pathlib.Path(sys.argv[1])
port = int(sys.argv[2])
manifest = (tmpd / "manifest.json").read_text().replace("'", "&#39;")
autostart = (
    "<!doctype html><meta charset='utf-8'>"
    "<title>Create the sandbox GitHub App</title>"
    "<p>Opening GitHub's <em>Create GitHub App</em> form.</p>"
    "<form id=f method='post' action='https://github.com/settings/apps/new'>"
    "<input type='hidden' name='manifest' value='" + manifest + "'>"
    "<noscript><button type='submit' form='f'>Continue</button></noscript>"
    "</form><script>document.getElementById('f').submit()</script>"
    "<p>If the redirect does not happen, enable JavaScript or submit the form.</p>"
)
ok = ("<!doctype html><meta charset='utf-8'><title>OK</title>"
      "<p>Thank you — return to the terminal.</p>").encode()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path in ("/", "/start"):
            b = autostart.encode()
        elif u.path == "/cb":
            q = urllib.parse.parse_qs(u.query)
            (tmpd / "code.txt").write_text(q.get("code", [""])[0])
            b = ok
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF
python3 "$tmpd/server.py" "$tmpd" "$port" &
srv=$!
sleep 1
if ! kill -0 "$srv" 2>/dev/null; then
    die "local listener failed to start — port $port busy? rerun (the port shifts per run)"
fi

cat >&2 <<EOF

┌─ CREATE THE PER-PROJECT GITHUB APP ───────────────────
│ Open this URL in a browser:
│
│   http://127.0.0.1:$port/start
│
│ It auto-submits the manifest (name: $app_name,
│ permissions contents/pull_requests/issues/administration
│ = write, webhooks off) to GitHub's app-creation form.
│
│   1. click "Create GitHub App"
│   2. click "Install", "Only select repositories",
│      pick $owner_repo, then "Install"
│
│ The tab ends on a local confirmation page; this script
│ continues on its own afterwards (up to 15 min).
└───────────────────────────────────────────────────────
EOF

# --- 4. wait for the callback code ----------------------------------------------
code=""
for _ in $(seq 1 180); do
    if [ -s "$tmpd/code.txt" ]; then
        code="$(cat "$tmpd/code.txt")"
        break
    fi
    sleep 5
done
[ -n "$code" ] || die "no callback within 15 min — rerun the command"
kill "$srv" 2>/dev/null || true
srv=""

# --- 5. exchange the code: app id + pem ------------------------------------------
# Schema (docs.github.com, App manifest conversions): the response is a
# full GitHub App object + pem/client_secret/webhook_secret — the app id is
# "id", NOT "app_id"; slug is optional.
resp="$(curl -sS -m 30 -X POST \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app-manifests/$code/conversions")" \
    || die "manifest conversion call failed (network?)"
if ! printf '%s' "$resp" | jq -e '.id and .pem' >/dev/null 2>&1; then
    printf 'gh-app-setup: manifest conversion failed, full response:\n%s\n' \
        "$(printf '%s' "$resp" | head -c 600)" >&2
    die "if the app WAS created (HTML flow finished), rescue it with: make gh-app-wire PROJECT=<repo> KEY=<pem>"
fi
app_id="$(printf '%s' "$resp" | jq -r .id)"
slug="$(printf '%s' "$resp" | jq -r '.slug // empty')"
pem_path="$key_dir/${slug:-app-$app_id}.pem"
mkdir -p "$key_dir"
printf '%s\n' "$(printf '%s' "$resp" | jq -r .pem)" > "$pem_path"
chmod 600 "$pem_path"
if ! head -1 "$pem_path" | grep -q 'PRIVATE KEY'; then
    die "downloaded PEM does not look like a private key — not saved; rerun the command"
fi

# --- 6. wire (shared with the rescue mode) ---------------------------------------
wire_install "$app_id" "$slug" "$owner_repo" "$pem_path" "$sc"
