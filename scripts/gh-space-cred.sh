#!/usr/bin/env bash
# git credential helper for the mounted GitHub space token (docs/github.md).
#
# Baked into the image and wired by the entrypoint ONLY when the workspace
# declares a GITHUB scope, as:
#   credential.https://github.com.helper /usr/local/bin/gh-space-cred
# (plus the LFS content hosts, which authenticate separately).
#
# Reads the token FRESH on every invocation — so a host-side `make gh-renew`
# (user-facing: `scc renew`) rotation (1 h installation tokens) is picked up
# by the next git call with no session restart.
#
# Security property: git delivers credentials only to URLs matching the
# configured `credential.<url>.*` section, so a `push https://evil/x.git`
# can never receive this token. It is still only a UX layer: the hard
# boundary is the token's mint-time `repositories` scope.
set -u

TOKEN_FILE=/run/secrets/github-space/token

# Only the "get" stage supplies credentials; store/erase are no-ops (the
# token file is minted host-side, never written from inside).
case "${1:-get}" in
    get) ;;
    *) exit 0 ;;
esac

if [ ! -s "$TOKEN_FILE" ]; then
    cat >&2 <<'EOF'
GitHub token missing or expired. On the HOST, run:
    scc token        # one-shot mint (human break-glass), or
    scc renew        # keep a running session supplied (24-48h shape)
EOF
    exit 1
fi

# GitHub accepts any username with a token over HTTPS; x-access-token is the
# documented convention for app installation tokens.
printf 'username=x-access-token\npassword=%s\n' "$(cat "$TOKEN_FILE")"
