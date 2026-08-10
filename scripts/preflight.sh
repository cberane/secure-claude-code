#!/usr/bin/env bash
# preflight.sh — fast host-environment sanity check, run automatically
# before every build/start target. Every failure names the exact fix; the
# whole run stays well under a second so it never gets in the way.
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

fail=0
err()  { echo "preflight: $*" >&2; fail=1; }
warn() { echo "preflight: warning: $*" >&2; }

# --- host type -------------------------------------------------------------
# The host-side scripts are GNU-only (stat -c, date -d). Fail early with a
# clear statement instead of BSD-tool gibberish later.
if [ "$(uname -s)" = "Darwin" ]; then
    err "macOS host detected — unsupported. The host scripts need GNU coreutils; use a Linux host or WSL2 (see docs/troubleshooting.md)."
fi

# --- required tools --------------------------------------------------------
for tool in jq ssh-keygen git; do
    command -v "$tool" >/dev/null 2>&1 \
        || err "'$tool' is not installed — required on the host (see docs/setup.md, Prerequisites)."
done

# --- engine + compose ------------------------------------------------------
ENGINE="${ENGINE:-$(sed -n 's/^ENGINE=//p' .env 2>/dev/null | tail -1)}"
ENGINE="${ENGINE:-docker}"
if ! command -v "$ENGINE" >/dev/null 2>&1; then
    err "container engine '$ENGINE' not found (set ENGINE in .env: docker | podman)."
elif ! "$ENGINE" compose version >/dev/null 2>&1; then
    err "'$ENGINE compose' does not work — install the compose plugin (docker-compose-plugin / podman-compose provider)."
else
    # The compose files use the long env_file syntax (needs >= 2.24); older
    # plugins fail with an opaque schema error. Best-effort version parse —
    # skip silently if the format is unexpected.
    ver="$("$ENGINE" compose version --short 2>/dev/null | sed 's/^v//')"
    if [ -n "$ver" ]; then
        major="${ver%%.*}"; rest="${ver#*.}"; minor="${rest%%.*}"
        case "$major$minor" in *[!0-9]*) ;; *)
            if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 24 ]; }; then
                err "compose plugin $ver is too old — need >= 2.24 for the env_file syntax used here."
            fi ;;
        esac
    fi
fi

# --- .env ------------------------------------------------------------------
if [ ! -f .env ]; then
    err ".env is missing — cp .env.example .env, then set PROJECTS_DIR (see docs/setup.md)."
else
    strip_quotes() { sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"; }
    raw_projects="$(sed -n 's/^PROJECTS_DIR=//p' .env | tail -1)"
    projects="$(printf '%s' "$raw_projects" | strip_quotes)"
    if [ -z "$projects" ] || [ "$projects" = "/home/you/projects/my-project" ]; then
        err "PROJECTS_DIR is not set in .env — point it at the project to mount at /workspace."
    elif [ ! -d "$projects" ]; then
        err "PROJECTS_DIR=$projects does not exist or is not a directory."
    elif [ "$raw_projects" != "$projects" ]; then
        warn "PROJECTS_DIR is quoted in .env — make reads the value literally; remove the quotes."
    fi

    # UID/GID mismatch only fails LATE (entrypoint owner check, after a full
    # build) — warn now instead. Values are baked in at image build time.
    env_uid="$(sed -n 's/^UID=//p' .env | tail -1 | strip_quotes)"
    env_gid="$(sed -n 's/^GID=//p' .env | tail -1 | strip_quotes)"
    [ -n "$env_uid" ] && [ "$env_uid" != "$(id -u)" ] \
        && warn "UID=$env_uid in .env but your user is $(id -u) — workspace files will not belong to you; fix .env and rebuild."
    [ -n "$env_gid" ] && [ "$env_gid" != "$(id -g)" ] \
        && warn "GID=$env_gid in .env but your group is $(id -g) — fix .env and rebuild."

    # Make's `-include .env` truncates values at '#' and expands '$'.
    if grep -qE '^[A-Z_]+=[^#]*[#$]' .env; then
        warn ".env contains '#' or '\$' inside a value — Make will mangle it on the host side (see docs/setup.md)."
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "preflight: fix the above, then rerun. (Checks live in scripts/preflight.sh.)" >&2
    exit 1
fi
exit 0
