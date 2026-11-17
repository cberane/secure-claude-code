#!/usr/bin/env bash
# gh wrapper — shadows /usr/bin/gh (PATH: /usr/local/bin first) and exports
# GH_TOKEN from the mounted, host-refreshed token file on EVERY invocation,
# so short-lived (1 h) installation tokens rotate transparently mid-session
# (docs/github.md). Without the file, the real gh runs unauthenticated and
# fails with its own 401 — the sandbox/CLAUDE.md rules say what to do then.
set -u
TOKEN_FILE=/run/secrets/github-space/token
if [ -s "$TOKEN_FILE" ]; then
    GH_TOKEN="$(cat "$TOKEN_FILE")"
    export GH_TOKEN
fi
exec /usr/bin/gh "$@"
