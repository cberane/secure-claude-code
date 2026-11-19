#!/usr/bin/env bash
# status.sh — per-project feedback for the CURRENT folder: what is set up,
# what is missing, what to do next. The read-only counterpart to `scc init`
# (which *creates* this state) — no builds, no dependency chain, no writes.
#
#   scc status [PATH]     (also: make status — then reports the repo itself)
#
# What it reports, top to bottom:
#   * setup         onboarded (repo-anchored profile) vs fresh
#   * workspace     registered in workspaces/*.env? active? .env in sync?
#   * github app    GITHUB_APP_ID wired, installation set, key on this machine
#   * token         mint age of secrets/github-space/token (1h life)
#   * sandbox       core containers (proxy, dind) + a running claude session
#   * egress        the project's posture (allowlist count / learning mode)
# and a single "next" line pointing at the command that closes the gap.
#
# Registration is decided on an exact SECURE_PROJECT_PATH match: the
# machine-local workspaces/<name>.env references <repo>/.secure-container/. A
# workspace whose PROJECTS_DIR merely contains the folder is intentionally NOT
# "registered" — mounting a whole projects dir is a legacy profile, not
# per-repo onboarding (docs/workspaces.md).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

WS_DIR=workspaces
SC_DIR=.secure-container

# --- output helpers ------------------------------------------------------------
if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_BAD=""; C_WARN=""; C_DIM=""; C_OFF=""
fi
ok()   { printf '  %-12s %s✓%s %s\n' "$1" "$C_OK" "$C_OFF" "$2"; }
fail() { printf '  %-12s %s✗%s %s\n' "$1" "$C_BAD" "$C_OFF" "$2"; }
warn() { printf '  %-12s %s△%s %s\n' "$1" "$C_WARN" "$C_OFF" "$2"; }
pln()  { printf '  %-12s %s\n' "$1" "$2"; }
hint() { printf '\n%snext: %s%s\n' "$C_DIM" "$C_OFF" "$1"; }

# Last assignment of a key in an env file (same convention as workspace.sh).
env_get() { # env_get <file> <key>
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | tail -1 \
        | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# --- which folder? ----------------------------------------------------------------
target="${1:-$PWD}"
target="${target/#\~/$HOME}"
[ -d "$target" ] || { echo "status: no such directory: $target" >&2; exit 1; }
target="$(cd "$target" && pwd)"

project="$target"
if [ ! -f "$project/$SC_DIR/workspace.env" ] && command -v git >/dev/null 2>&1; then
    top="$(git -C "$project" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] && project="$top"
fi

profile="$project/$SC_DIR/workspace.env"
allowlist="$project/$SC_DIR/egress/allowlist.txt"

echo "scc status — $project"

# The sandbox repo itself is the tool, not a client project: it never takes
# scc init / gh-app onboarding (it minted its own break-glass token instead).
repo_itself=0
[ "$project" = "$repo_root" ] && repo_itself=1

# --- setup: repo-anchored profile ------------------------------------------------
if [ -f "$profile" ]; then
    ok setup "onboarded — repo-anchored ($SC_DIR/ committed with the repo)"
else
    fail setup "fresh — no $SC_DIR/ (not onboarded)"
fi

# --- workspace: registered / active / in sync --------------------------------------
ws_name=""
if [ -d "$WS_DIR" ]; then
    for f in "$WS_DIR"/*.env; do
        [ -f "$f" ] || continue
        name="$(basename "$f" .env)"
        if [ "$name" != common ] && [ "$name" != secrets ] \
            && [ "$(env_get "$f" SECURE_PROJECT_PATH)" = "$project" ]; then
            ws_name="$name"
            break
        fi
    done
fi

active=""
[ -f .workspace ] && active="$(cat .workspace)"

if [ -n "$ws_name" ]; then
    if [ "$active" = "$ws_name" ]; then
        line="$(scripts/workspace.sh sync "$ws_name" 2>/dev/null || true)"
        case "$line" in
            *"in sync"*) ok workspace "'$ws_name' active — .env in sync with the definition" ;;
            *"stale"*)   warn workspace "'$ws_name' active — $line" ;;
            *)           warn workspace "'$ws_name' active — sync unknown (broken .env?) — scc ws switch $ws_name" ;;
        esac
    else
        warn workspace "'$ws_name' registered but NOT active (active: ${active:-none}) — scc switch $ws_name"
    fi
else
    fail workspace "not registered — scc init (or: scc ws add PROJECT=$project)"
fi

# --- github app --------------------------------------------------------------------
app_id="$(env_get "$profile" GITHUB_APP_ID)"
inst_id="$(env_get "$profile" GITHUB_INSTALLATION_ID)"
gh_repo="$(env_get "$profile" GITHUB_REPO)"
key_path="$(env_get "$WS_DIR/secrets.env" GITHUB_APP_KEY_PATH)"
if [ -n "$app_id" ]; then
    detail="App $app_id${gh_repo:+ → $gh_repo}"
    if [ -z "$inst_id" ]; then
        detail="$detail — NO installation yet (install the app, then rerun: scc gh app PROJECT=$project)"
        warn "github app" "$detail"
    elif [ -n "$key_path" ] && [ -f "$key_path" ]; then
        ok "github app" "$detail — key wired"
    else
        fail "github app" "$detail — key NOT on this machine — scc gh app-rescue KEY=…"
    fi
elif [ -f "$profile" ]; then
    fail "github app" "not wired — scc gh app PROJECT=$project"
else
    pln "github app" "not wired (onboard first) — scc init"
fi

# --- token (1h life; scc token / scc renew) ----------------------------------------
# Reported only against a wired app: secrets/github-space/token is minted per
# app installation, so without one it is the sandbox's own break-glass token —
# not this project's business.
token_file=secrets/github-space/token
if [ -z "$app_id" ]; then
    pln token "no app wired yet — nothing to mint"
elif [ ! -f "$token_file" ]; then
    fail token "not minted — scc token"
else
    age=$(( $(date +%s) - "$(stat -c %Y "$token_file")" ))
    [ "$age" -lt 0 ] && age=0
    left=$(( 60 - age / 60 ))
    if [ "$left" -gt 0 ]; then
        ok token "minted $(( age / 60 ))m ago — expires in ~${left}m"
    else
        fail token "minted $(( age / 60 ))m ago — EXPIRED — scc token"
    fi
fi

# --- sandbox: core containers + session ----------------------------------------------
engine="$(env_get .env ENGINE)"
engine="${engine:-docker}"
compose_files=(-f docker-compose.yml)
[ "$engine" = podman ] && compose_files+=(-f compose.podman.yml)
[ -f .learning-mode ] && compose_files+=(-f compose.learning.yml)
if command -v "$engine" >/dev/null 2>&1; then
    up=0 down=0 missing=""
    for svc in egress-proxy dind-daemon dind-guard; do
        # runs with cwd = repo root, so compose picks up .env (project name, …)
        if [ -n "$("$engine" compose "${compose_files[@]}" ps -q "$svc" 2>/dev/null | head -1)" ]; then
            up=$(( up + 1 ))
        else
            down=$(( down + 1 )); missing="$missing $svc"
        fi
    done
    session="$("$engine" ps -q -f name='^claude-session$$' 2>/dev/null | head -1)"
    if [ "$down" = 0 ]; then
        detail="running (proxy, dind)"
        [ -n "$session" ] && detail="$detail + live session"
        ok sandbox "$detail"
        [ -n "$session" ] && [ "$(env_get .env EGRESS)" != learning ] \
            && pln session "keeps a token fresh beside it with: scc renew"
    else
        fail sandbox "$up/3 core containers up (down:$missing) — scc up"
    fi
else
    fail sandbox "engine '$engine' not found"
fi

# --- egress posture -------------------------------------------------------------------
if [ -f .learning-mode ]; then
    warn egress "LEARNING MODE OPEN (repo-wide) — distill: scc egress learned · leave: scc egress learn-off"
elif [ -f "$profile" ]; then
    eg="$(env_get "$profile" EGRESS)"
    n_dom=0
    [ -f "$allowlist" ] && n_dom="$(grep -c -e '^[[:space:]]*[^#[:space:]]' "$allowlist" || true)"
    ok egress "posture: ${eg:-unset} — $n_dom project allowlist domains"
else
    pln egress "no project posture yet (created at onboarding)"
fi

# --- sync verdict for the next-step line ----------------------------------------------
sync_state="unknown"
if [ -n "$ws_name" ] && [ "$active" = "$ws_name" ]; then
    line="$(scripts/workspace.sh sync "$ws_name" 2>/dev/null || true)"
    case "$line" in
        *"in sync"*) sync_state="in-sync" ;;
        *"stale"*)   sync_state="stale" ;;
    esac
fi

# --- next step ------------------------------------------------------------------------
if [ "$repo_itself" = 1 ]; then
    hint "scc claude   (or: scc up — this is the sandbox repo: the tool, never an scc init target)"
elif [ -z "$ws_name" ] || [ ! -f "$profile" ]; then
    hint "scc init $project"
elif [ "$active" != "$ws_name" ]; then
    hint "scc switch $ws_name"
elif [ "$sync_state" != "in-sync" ]; then
    hint "scc ws switch $ws_name  (apply the changed definition)"
else
    hint "scc claude   (this folder's setup is good to go)"
fi
