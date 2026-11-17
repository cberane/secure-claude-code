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

path="${1:-}"
[ -n "$path" ] || die "usage: make gh-app PROJECT=~/projects/<repo> [WS=<app-name>]"
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
resp="$(curl -sS -m 30 -X POST \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app-manifests/$code/conversions")" \
    || die "manifest conversion call failed (network?)"
printf '%s' "$resp" | jq -e '.app_id and .pem' >/dev/null 2>&1 \
    || die "manifest conversion rejected: $(printf '%s' "$resp" | head -1 | cut -c1-200)"
app_id="$(printf '%s' "$resp" | jq -r .app_id)"
slug="$(printf '%s' "$resp" | jq -r .slug)"
pem_path="$key_dir/$slug.pem"
mkdir -p "$key_dir"
printf '%s\n' "$(printf '%s' "$resp" | jq -r .pem)" > "$pem_path"
chmod 600 "$pem_path"
if ! head -1 "$pem_path" | grep -q 'PRIVATE KEY'; then
    die "downloaded PEM does not look like a private key — not saved; rerun the command"
fi

# --- 6. wire the installation id (fresh key as JWT → /app/installations) ---------
install_url="https://github.com/apps/$slug/installations/new"
inst_id=""
for _ in 1 2 3 4 5 6; do
    jwt="$(scripts/mint-github-token.sh jwt "$pem_path" "$app_id" 2>/dev/null || true)"
    if [ -n "$jwt" ] && [ "$(printf '%s' "$jwt" | awk -F. '{print NF}')" = 3 ]; then
        inst_id="$(curl -sS -m 30 \
            -H "Authorization: Bearer $jwt" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/app/installations" \
            | jq -r '.[0].id // empty' 2>/dev/null || true)"
        [ -n "$inst_id" ] && { info "installation found: $inst_id"; break; }
    fi
    info "installation not visible yet — finish the browser step; re-probing in 30 s…"
    sleep 30
done

# --- 7. write the wiring ----------------------------------------------------------
env_set "$sc/workspace.env" GITHUB_APP_ID "$app_id"
env_set "$sc/workspace.env" GITHUB_REPO "$owner_repo"
if [ -n "$inst_id" ]; then
    env_set "$sc/workspace.env" GITHUB_INSTALLATION_ID "$inst_id"
else
    printf '\n# gh-app-setup: finish the install at %s, then set:\n#GITHUB_INSTALLATION_ID=<numeric id>\n' \
        "$install_url" >> "$sc/workspace.env"
    info "no installation yet — set GITHUB_INSTALLATION_ID in $sc/workspace.env (or rerun this script)"
fi
env_set workspaces/secrets.env GITHUB_APP_KEY_PATH "$pem_path"

cat >&2 <<EOF

✔ App created and wired:
    app:           $app_name ($slug, id $app_id)
    key:           $pem_path (0600, host-only, never committed)
    profile:       $sc/workspace.env (GITHUB_APP_ID, GITHUB_REPO${inst_id:+, GITHUB_INSTALLATION_ID})
    secrets.env:   GITHUB_APP_KEY_PATH

Next:
    make workspace NAME=<name>
    make gh-token        # or: make gh-renew (long session)
EOF
