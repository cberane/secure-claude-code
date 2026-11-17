#!/usr/bin/env bash
# scc — the user-facing CLI for the hardened Claude Code sandbox.
#
# A thin dispatcher over the repo's Makefile targets (the Makefile stays the
# single source of truth) plus an init wizard that onboards a project:
# register the workspace, create/adopt the GitHub App, mint a token, start.
#
# Installed per-user via `make install-scc` (symlink in ~/.local/bin).
# Resolves the repo through this script's own location, so it follows the
# checkout it belongs to without configuration.
set -euo pipefail

# --- resolve the repo ---------------------------------------------------------
script_path="${BASH_SOURCE[0]}"
if [ -L "$script_path" ]; then
    script_path="$(readlink -f "$script_path")"
fi
if [ -n "${SCC_REPO:-}" ]; then
    REPO_ROOT="$SCC_REPO"
else
    REPO_ROOT="$(cd "$(dirname "$script_path")/.." && pwd)"
fi
[ -d "$REPO_ROOT" ] || { echo "scc: repo root '$REPO_ROOT' not found (set SCC_REPO)" >&2; exit 1; }

ask() { # ask <prompt> <default-y|n> <cmd...> — run cmd on yes
    local answer
    if [ ! -t 0 ]; then answer="n"; fi
    printf '%s' "$1" >&2
    if [ -t 0 ]; then read -r answer || return 1; fi
    case "$answer" in y|Y|yes) "$@" ;; *) echo "scc: skipped" >&2 ;; esac
}

group_help() { # group_help <label> <entries...>  (entries: "cmd  description")
    local label="$1"
    shift
    echo
    echo "$label"
    printf '  %s\n' "$@"
}

scc_help() {
    cat <<'EOF'
scc — hardened Claude Code sandbox, per-project GitHub automation

Usage: scc <command> [args]

Commands by group (scc <group> for details):

  scc init [~/path]     onboard a project: register workspace, GitHub App,
                        token, then activate — the full bootstrapping flow
  scc run claude|yolo|shell   start / inspect sessions (also: scc claude)
  scc gh token|renew|app     GitHub: mint 1h token / refresh loop / app setup
  scc egress ...             allowlist proxy operations (reload, learn, denied)
  scc ws ...                 workspace switching and listing
  scc doctor                 full hardening self-test
EOF
}

run_make() { # run_make <make-target> [VAR=value ...]
    ( cd "$REPO_ROOT" && make "$@" )
}

require_ws_name() {
    [ -n "${NAME:-}" ] || { echo "scc: usage: scc ws switch NAME=<name>" >&2; exit 1; }
}

# --- groups -------------------------------------------------------------------
cmd_run() {
    local sub="${1:-help}"
    shift || true
    case "$sub" in
        claude|yolo|shell) run_make "$sub" ;;
        build|up|down|stop|restart) run_make "$sub" ;;
        *) echo "scc run: claude|yolo|shell|build|up|down|stop|restart" >&2; exit 2 ;;
    esac
}

cmd_gh() {
    local sub="${1:-help}"
    shift || true
    case "$sub" in
        token) run_make gh-token ;;
        renew) run_make gh-renew ;;
        app)   run_make gh-app "PROJECT=${PROJECT:-$PWD}" "WS=${WS:-}" ;;
        app-rescue)
            [ -n "${KEY:-}" ] || { echo "scc gh app-rescue: KEY=<pem> required" >&2; exit 1; }
            run_make gh-app-wire "PROJECT=${PROJECT:-$PWD}" "KEY=$KEY" "APP_ID=${APP_ID:-}"
            ;;
        *) echo "scc gh: token|renew|app|app-rescue" >&2; exit 2 ;;
    esac
}

cmd_egress() {
    local sub="${1:-help}"
    shift || true
    case "$sub" in
        reload) run_make reload-egress ;;
        reload-images|reload-ingress) run_make "$sub" ;;
        learn) run_make learn ;;
        learn-off) run_make learn-off ;;
        learned) run_make learned ;;
        denied) run_make denied ;;
        allowlist) echo "edit <project>/egress/allowlist.txt (with '# why' comments), then: scc egress reload" ;;
        *) echo "scc egress: reload|learn|learn-off|learned|denied" >&2; exit 2 ;;
    esac
}

cmd_ws() {
    local sub="${1:-help}"
    shift || true
    case "$sub" in
        list) run_make workspaces ;;
        switch)
            require_ws_name
            run_make workspace "NAME=$NAME"
            ;;
        new) require_ws_name; run_make new-workspace "NAME=$NAME" ;;
        add) run_make add-workspace "PROJECT=${PROJECT:-$PWD}" "WS=${WS:-}" ;;
        *) echo "scc ws: list|switch NAME=|new NAME=|add PROJECT=" >&2; exit 2 ;;
    esac
}

cmd_tls() {
    local sub="${1:-help}"
    shift || true
    case "$sub" in
        certs) run_make certificates ;;
        cert) run_make cert "DOMAIN=${DOMAIN:?usage: scc tls cert DOMAIN=myapp.test [DIR=]}" "DIR=${DIR:-}" ;;
        renew) run_make renew-certs ;;
        keygen) run_make keygen ;;
        rotate-key) run_make rotate-signing-key ;;
        hooks) run_make install-hooks ;;
        *) echo "scc tls: certs|cert DOMAIN=|renew|keygen|rotate-key|hooks" >&2; exit 2 ;;
    esac
}

cmd_inspect() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        doctor) run_make doctor ;;
        ps) run_make ps ;;
        logs) run_make logs ;;
        df) run_make df ;;
        "") group_help "Inspect" \
            "doctor   full hardening self-test (host + container)" \
            "ps       containers (outer + nested dind)" \
            "logs     follow proxy/dind/ingress logs" \
            "df       disk usage host + dind"
        ;;
        *) echo "scc inspect: doctor|ps|logs|df" >&2; exit 2 ;;
    esac
}

cmd_maintain() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        prune|prune-build|prune-dind|clean|clean-dind|distclean) run_make "$sub" ;;
        "") group_help "Maintenance" \
            "prune       dangling images (safe)" \
            "prune-build host build cache" \
            "prune-dind  dind-internal storage" \
            "clean       containers + local images" \
            "clean-dind  dind image/layer storage" \
            "distclean   EVERYTHING (volumes, logins)"
        ;;
        *) echo "scc maintain: prune|prune-build|prune-dind|clean|clean-dind|distclean" >&2; exit 2 ;;
    esac
}

# --- init wizard ---------------------------------------------------------------
cmd_init() {
    local target="${1:-$PWD}"
    target="${target/#\~/$HOME}"
    if [ ! -d "$target" ]; then
        echo "scc init: path '$target' does not exist" >&2
        exit 1
    fi
    target="$(cd "$target" && pwd)"
    echo "scc init: onboarding $target"
    echo "  1/5 preflight"
    run_make preflight

    echo "  2/5 register the repo-anchored workspace"
    ( cd "$REPO_ROOT" && make add-workspace "PROJECT=$target" "WS=${WS:-}" )

    echo "  3/5 GitHub App (per-project, 1h tokens — docs/github.md)"
    if [ -f "$target/.secure-container/workspace.env" ] \
        && grep -q '^GITHUB_APP_ID=' "$target/.secure-container/workspace.env"; then
        echo "  already wired (GITHUB_APP_ID found) — skipping app setup"
    else
        if [ -t 0 ]; then
            printf '     create a NEW app via the manifest flow (2 browser clicks)? [y/N] '
            read -r answer
            case "$answer" in y|Y|yes) ( cd "$REPO_ROOT" && make gh-app "PROJECT=$target" "WS=${WS:-}" ) ;; *) echo "  skipped — later: scc gh app PROJECT=$target" >&2 ;; esac
        else
            echo "  non-interactive: run later with: scc gh app PROJECT=$target"
        fi
    fi

    echo "  4/5 activate the workspace"
    local name
    name="$(basename "$target" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/[^a-z0-9-]\+/-/g' -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
    NAME="${WS:-$name}"
    ( cd "$REPO_ROOT" && make workspace "NAME=${WS:-$name}" )

    echo "  5/5 token"
    ask "     mint a fresh 1h token now? [Y/n] " run_make gh-token

    cat >&2 <<EOF

scc: '$(basename "$target")' onboarded.
  Start working:   scc claude     (or scc yolo)
  Long sessions:   scc renew      (keep running beside the session)
  Commit .secure-container/ + egress/ in the project repo — the setup
  then travels with it (fresh machines onboard with: scc init <path>).
EOF
}

# --- dispatch -------------------------------------------------------------------
cmd="${1:-help}"
case "$cmd" in
    help|-h|--help) scc_help ;;
    init) shift; cmd_init "$@" ;;
    claude|yolo|shell|build|up|down|stop|restart) cmd_run "$cmd" ;;
    run) shift; cmd_run "$@" ;;
    gh) shift; cmd_gh "$@" ;;
    token) cmd_gh token ;;
    renew) run_make gh-renew ;;
    egress) shift; cmd_egress "$@" ;;
    denied) run_make denied ;;
    ws|workspaces) shift; cmd_ws "$@" ;;
    switch) NAME="${2:-}" cmd_ws switch ;;
    tls|certs) shift; cmd_tls "$@" ;;
    inspect) shift; cmd_inspect "$@" ;;
    doctor) run_make doctor ;;
    maintain) shift; cmd_maintain "$@" ;;
    version|--version|-v) echo "scc (repo: $REPO_ROOT)" ;;
    egress-reload) run_make reload-egress ;;
    *)
        echo "scc: unknown command '$cmd'" >&2
        scc_help
        exit 2
        ;;
esac
