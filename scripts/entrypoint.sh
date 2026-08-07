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
[ -d "$SIGNING_DIR" ] \
    || die "$SIGNING_DIR is missing. Run 'make keygen' on the HOST, then restart."
[ -f "$SIGNING_DIR/signing_key" ] \
    || die "$SIGNING_DIR/signing_key is missing. Run 'make keygen' on the HOST, then restart."
[ -f "$SIGNING_DIR/allowed_signers" ] \
    || die "$SIGNING_DIR/allowed_signers is missing. Run 'make keygen' on the HOST, then restart."

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

# --- 4. git configuration (global config lives on tmpfs) ------------------
: "${GIT_CONFIG_GLOBAL:=/tmp/.gitconfig}"
export GIT_CONFIG_GLOBAL
rm -f "$GIT_CONFIG_GLOBAL"

git config --global user.name  "${GIT_AUTHOR_NAME:-dev}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-dev@sandbox.invalid}"
git config --global gpg.format ssh
git config --global user.signingkey "$SIGNING_DIR/signing_key"
git config --global commit.gpgsign true
git config --global tag.gpgsign true
git config --global gpg.ssh.allowedSignersFile "$SIGNING_DIR/allowed_signers"
git config --global core.hooksPath /opt/git-hooks
git config --global init.defaultBranch main
git config --global safe.directory /workspace
git config --global --add safe.directory '/workspace/*'
git config --global credential.helper ""
git config --global core.fsmonitor false

# --- 5. agent rules into the persistent Claude config volume --------------
if [ -d "${CLAUDE_CONFIG_DIR:-/home/dev/.claude}" ]; then
    cp -f /etc/claude/CLAUDE.md "${CLAUDE_CONFIG_DIR:-/home/dev/.claude}/CLAUDE.md" 2>/dev/null || true
fi

# --- 6. signing key age (warn only at session start) ----------------------
check-key-age --context session || true

exec "$@"
