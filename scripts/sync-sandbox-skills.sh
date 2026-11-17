#!/usr/bin/env bash
# sync-sandbox-skills.sh — fetch/refresh REMOTE skill-sets for the sandbox
# container (docs/skills.md).
#
# Sources are declared in the tracked sandbox/remote-skills.txt (one GitHub
# repo per line, optional @ref, '#' comments with the reason). Each run
# shallow-clones every source FRESH into the machine-local
# skills-remote/<owner>.<repo>/ — "latest available version" by construction,
# no incremental state to drift. The directory is mounted read-only into the
# sandbox at /run/remote-skills/ (docker-compose.yml: build/up prerequisites
# include the skills-remote mkdir rule), and the entrypoint links each
# skills/<name>/SKILL.md into ~/.claude/skills/<name> at session start.
#
#   scripts/sync-sandbox-skills.sh
#
# Whole checkouts are kept (not per-skill) so repo-relative references
# (e.g. agent-skills' shared references/) keep resolving inside the sandbox.
# Locally developed skills in the container are never clobbered — the
# entrypoint links only where ~/.claude/skills/<name> is absent or already a
# managed symlink.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

SOURCES=sandbox/remote-skills.txt
CACHE_ROOT="$repo_root/skills-remote"

die() { printf 'sync-sandbox-skills: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is required"
[ -f "$SOURCES" ] || die "missing $SOURCES — declare remote skill sources there"

mkdir -p "$CACHE_ROOT"

synced=""
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"                      # strip per-line comments
    line="$(printf '%s' "$line" | xargs 2>/dev/null || true)"  # trim
    [ -n "$line" ] || continue

    ref="HEAD"
    case "$line" in
        *@*) ref="${line##*@}"; line="${line%%@*}" ;;
    esac
    printf '%s' "$line" | grep -Eq '^(https://github\.com/)?[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
        || die "unsupported source line '$line' (expected [https://github.com/]owner/repo[@ref])"
    line="${line#https://github.com/}"
    owner="${line%%/*}"
    name="${line##*/}"
    slug="$owner.$name"
    url="https://github.com/$owner/$name.git"

    echo "--- $slug ($ref)"
    # Validated slug + required non-empty prefix: the rm target can never
    # collapse to / , and the refresh target can never escape the cache.
    rm -rf "${CACHE_ROOT:?}/$slug"
    # --branch rejects "HEAD" (not a name) — clone the default branch then.
    if [ "$ref" = HEAD ]; then
        if ! git clone --depth 1 "$url" "$CACHE_ROOT/$slug" >/dev/null 2>&1; then
            die "clone failed: $url @ default branch"
        fi
    else
        if ! git clone --depth 1 --branch "$ref" "$url" "$CACHE_ROOT/$slug" >/dev/null 2>&1; then
            die "clone failed: $url @ $ref"
        fi
    fi
    count="$(find "$CACHE_ROOT/$slug/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
    echo "    $count skills → $CACHE_ROOT/$slug"
    synced="$synced $slug"
done < "$SOURCES"
[ -n "$synced" ] || die "no sources declared in $SOURCES"

echo "synced:$synced"
echo "New sessions pick the skills up on start (make claude / scc claude)."
echo "A RUNNING session can be re-linked by restarting it."
