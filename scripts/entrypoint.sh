#!/usr/bin/env bash
# Container entrypoint — preflight security checks, git configuration, then
# exec the requested command as the unprivileged 'dev' user.
set -euo pipefail

SIGNING_DIR=/run/secrets/git-signing

die() {
    echo "ENTRYPOINT PREFLIGHT FAILED: $*" >&2
    exit 1
}

# --- 1. never run as root -------------------------------------------------
[ "$(id -u)" -ne 0 ] || die "container is running as root; refusing to start"

# --- 2. no SSH auth key material may exist in this container --------------
if [ -d "$HOME/.ssh" ]; then
    found="$(find "$HOME/.ssh" -type f \( -name 'id_*' -o -name '*.pem' \) 2>/dev/null || true)"
    if [ -z "$found" ]; then
        found="$(grep -rl -- 'PRIVATE KEY' "$HOME/.ssh" 2>/dev/null || true)"
    fi
    [ -z "$found" ] || die "SSH key material found in $HOME/.ssh — this sandbox must never contain auth keys: $found"
fi

# --- 3. signing key mount preflight ---------------------------------------
# Learning mode (open egress) and the signing key are mutually exclusive:
# the readable key is only acceptable while the allowlist leaves no
# exfiltration channel (docs/signing.md). compose.learning.yml removes the
# mount; refuse to start if the two are ever combined anyway.
if [ "${EGRESS_MODE:-allowlist}" = "learning" ]; then
    [ ! -f "$SIGNING_DIR/signing_key" ] \
        || die "EGRESS_MODE=learning but the signing key is mounted — start learning sessions via 'scc egress learn' + scc claude/yolo, never by setting the variable by hand."
    echo "############################################################" >&2
    echo "# EGRESS LEARNING MODE — open egress, everything logged.   #" >&2
    echo "# No signing key in this session; commits are UNSIGNED.    #" >&2
    echo "# Do not work with secret-bearing projects in this mode.   #" >&2
    echo "############################################################" >&2
else
[ -d "$SIGNING_DIR" ] \
    || die "$SIGNING_DIR is missing. Run 'scc tls keygen' on the HOST, then restart."
[ -f "$SIGNING_DIR/signing_key" ] \
    || die "$SIGNING_DIR/signing_key is missing. Run 'scc tls keygen' on the HOST, then restart."
[ -f "$SIGNING_DIR/allowed_signers" ] \
    || die "$SIGNING_DIR/allowed_signers is missing. Run 'scc tls keygen' on the HOST, then restart."

mode="$(stat -c '%a' "$SIGNING_DIR/signing_key")"
[ "$mode" = "400" ] \
    || die "signing_key has mode $mode, expected 0400. Fix on the HOST: chmod 0400 secrets/git-signing/signing_key"

owner="$(stat -c '%u' "$SIGNING_DIR/signing_key")"
[ "$owner" = "$(id -u)" ] \
    || die "signing_key is owned by uid $owner, expected $(id -u). Fix UID/GID in .env and rebuild, or chown on the HOST."

if touch "$SIGNING_DIR/.rwtest" 2>/dev/null; then
    rm -f "$SIGNING_DIR/.rwtest"
    die "$SIGNING_DIR is writable — it must be mounted read-only (:ro)"
fi
fi

# --- 4. local dev CA trust (optional; docs/https.md) ----------------------
# Host-provisioned, name-constrained dev CA for project HTTPS. Only the CA
# CERTIFICATE may ever be present here — the key stays on the host.
DEV_CA_CRT=/run/secrets/dev-ca/ca.crt
if [ -d /run/secrets/dev-ca ]; then
    found="$(grep -rl -- 'PRIVATE KEY' /run/secrets/dev-ca 2>/dev/null || true)"
    [ -z "$found" ] || die "private key material found in /run/secrets/dev-ca — only ca.crt may be mounted there: $found"
fi
if [ -f "$DEV_CA_CRT" ]; then
    # Rootfs is read-only, so no update-ca-certificates: combined bundle on
    # tmpfs, wired up via the env vars the common tools honor.
    cat /etc/ssl/certs/ca-certificates.crt "$DEV_CA_CRT" > /tmp/ca-bundle.crt
    export SSL_CERT_FILE=/tmp/ca-bundle.crt \
           CURL_CA_BUNDLE=/tmp/ca-bundle.crt \
           REQUESTS_CA_BUNDLE=/tmp/ca-bundle.crt \
           NODE_EXTRA_CA_CERTS="$DEV_CA_CRT"
fi

# --- 5. git configuration (global config lives on tmpfs) ------------------
: "${GIT_CONFIG_GLOBAL:=/tmp/.gitconfig}"
export GIT_CONFIG_GLOBAL
rm -f "$GIT_CONFIG_GLOBAL"

git config --global user.name  "${GIT_AUTHOR_NAME:-dev}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-dev@sandbox.invalid}"
if [ "${EGRESS_MODE:-allowlist}" = "learning" ]; then
    git config --global commit.gpgsign false
    git config --global tag.gpgsign false
else
    git config --global gpg.format ssh
    git config --global user.signingkey "$SIGNING_DIR/signing_key"
    git config --global commit.gpgsign true
    git config --global tag.gpgsign true
    git config --global gpg.ssh.allowedSignersFile "$SIGNING_DIR/allowed_signers"
fi
git config --global core.hooksPath /opt/git-hooks
git config --global init.defaultBranch main
git config --global safe.directory /workspace
git config --global --add safe.directory '/workspace/*'
git config --global credential.helper ""
git config --global core.fsmonitor false

# --- 5b. GitHub scope: token-backed credential helper (docs/github.md) ------
# Active only when the workspace's merged config declares one (the GITHUB_*
# keys reach the container via compose env_file — no extra plumbing). The
# mounted token is read fresh on every git call, so host-side rotation
# (make gh-renew, 1 h installation tokens — user-facing `scc renew`) applies
# without a restart. The
# hard boundary is the token's mint-time repositories scope; this helper is
# transport convenience. SSH remote URLs never authenticate (no SSH keys in
# the sandbox, and ssh.github.com stays proxy-denied in every mode).
GITHUB_SPACE=/run/secrets/github-space
if [ "${EGRESS_MODE:-allowlist}" = "learning" ] && [ -n "${GITHUB_APP_ID:-}" ]; then
    die "EGRESS_MODE=learning together with a GITHUB scope is not allowed — switch to a workspace without a scope (docs/github.md)"
fi
if [ -d "$GITHUB_SPACE" ]; then
    found="$(grep -rl -- 'PRIVATE KEY' "$GITHUB_SPACE" 2>/dev/null || true)"
    [ -z "$found" ] || die "key material found in $GITHUB_SPACE — only the 1h token may exist there: $found"
    if [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_REPO:-}" ]; then
        git config --global credential.https://github.com.helper /usr/local/bin/gh-space-cred
        git config --global credential.https://media.githubusercontent.com.helper /usr/local/bin/gh-space-cred
        git config --global credential.https://objects.githubusercontent.com.helper /usr/local/bin/gh-space-cred
        if [ ! -s "$GITHUB_SPACE/token" ]; then
            echo "note: GITHUB scope active, no token mounted yet — mint on the HOST with" >&2
            echo "      'scc token' (human) or 'scc renew' (long session). Pushes fail until then." >&2
        fi
    fi
fi

# --- 5c. origin/HEAD bookkeeping (docs/github.md) ---------------------------
# `git fetch` never creates refs/remotes/origin/HEAD — only git clone and
# 'git remote set-head' do. A workspace whose checkout was not born from a
# fresh clone boots without it, and every 'git diff origin/HEAD...' preamble
# (e.g. /security-review) errors until someone sets it by hand. Fix it once
# at session start, two hard guards: ONLY when the ref is missing (an
# existing — even deliberately re-pointed — origin/HEAD is never touched),
# and ONLY with an active GITHUB scope + mounted token (there is otherwise
# no egress to github.com to ask). Non-fatal: a failed remote query just
# prints the recovery line; session start never aborts.
if [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_REPO:-}" ] \
    && [ -d "$GITHUB_SPACE" ] && [ -s "$GITHUB_SPACE/token" ] \
    && git -C /workspace rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && git -C /workspace remote get-url origin >/dev/null 2>&1 \
    && ! git -C /workspace rev-parse -q --verify refs/remotes/origin/HEAD >/dev/null 2>&1; then
    echo "note: refs/remotes/origin/HEAD missing (checkout not born from a clone) — asking the remote once" >&2
    # 15s budget: session start must never hang on a proxy-denied/unreachable
    # remote (a dropped SYN would otherwise block here for minutes).
    if timeout 15 git -C /workspace remote set-head origin --auto >/dev/null 2>&1; then
        head_branch="$(git -C /workspace rev-parse --abbrev-ref origin/HEAD 2>/dev/null || true)"
        echo "note: origin/HEAD -> ${head_branch:-<remote default>} — 'git diff origin/HEAD...' resolves" >&2
    else
        echo "      remote unreachable — after a successful fetch run in a session:" >&2
        echo "        git remote set-head origin --auto" >&2
    fi
fi

# --- 6. agent rules into the persistent Claude config volume --------------
if [ -d "${CLAUDE_CONFIG_DIR:-/home/dev/.claude}" ]; then
    cp -f /etc/claude/CLAUDE.md "${CLAUDE_CONFIG_DIR:-/home/dev/.claude}/CLAUDE.md" 2>/dev/null || true
fi

# --- 6b. remote skill-sets (docs/skills.md) --------------------------------
# Host-fetched whole checkouts under /run/remote-skills (read-only bind,
# written by `make update-sandbox-skills`). Each /run/remote-skills/<src>/
# skills/<name> holding a SKILL.md gets a managed symlink into the
# persistent config volume — absolute, so repo-relative references inside
# SKILL.md (e.g. agent-skills' shared references/) keep resolving. Skills
# that exist and are NOT symlinks (locally developed) are never touched.
cfg="${CLAUDE_CONFIG_DIR:-/home/dev/.claude}"
if [ -d /run/remote-skills ] && [ -n "$(ls -A /run/remote-skills 2>/dev/null || true)" ]; then
    mkdir -p "$cfg/skills"
    for src in /run/remote-skills/*/skills/*; do
        [ -f "$src/SKILL.md" ] || continue
        name="$(basename "$src")"
        link="$cfg/skills/$name"
        if [ -e "$link" ] && [ ! -L "$link" ]; then
            continue
        fi
        ln -sfn "$src" "$link"
    done
fi

# --- 7. signing key age (warn only at session start) ----------------------
if [ "${EGRESS_MODE:-allowlist}" != "learning" ]; then
    check-key-age --context session || true
fi

exec "$@"
