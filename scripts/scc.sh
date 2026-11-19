#!/usr/bin/env bash
# scc — the user-facing CLI for the hardened Claude Code sandbox.
#
# A thin dispatcher over the repo's Makefile targets (the Makefile stays the
# single source of truth) plus an init wizard that onboards a project:
# register the workspace, create/adopt the GitHub App, mint a token, start.
#
# Discoverability contract (docs/scc.md, docs/intent/scc-help.md):
#   * bare `scc` lists EVERY spelling, grouped — nothing to guess
#   * any command accepts -h: `scc gh -h` (group view), `scc token -h`
#     (detail); a bare group name equals its -h
#   * `scc completion` prints the tab-completion script to stdout,
#     covering the `scc` command only — the rc wiring is yours
# All three views render from ONE table (scc_table) — no second list to
# keep in sync.
#
# Installed per-user via `make install-scc` (launcher in ~/.local/bin that
# execs this script; the checkout's path is baked in at install time).
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

run_make() { # run_make <make-target> [VAR=value ...]
    ( cd "$REPO_ROOT" && make "$@" )
}

require_ws_name() {
    [ -n "${NAME:-}" ] || { echo "scc: usage: scc ws switch NAME=<name>" >&2; exit 1; }
}

# --- split-start guard ---------------------------------------------------------
# The containers mount ONE project: the active workspace's PROJECTS_DIR —
# no matter where `scc claude` happens to be typed from. Starting a session
# for a different project therefore silently runs the agent against the
# wrong folder. The guard refuses that ("fail loudly beats run wrongly"):
# allowed are the sandbox repo itself, the mounted project, everything
# mounted UNDER it (incl. nested repos), and the not-configured case
# (compose reports its own error). docs/scc.md, DECISIONS.md.

cwd_project_root() { # the project a folder belongs to (.secure-container/ or git toplevel)
    local top
    if [ -f "$PWD/.secure-container/workspace.env" ]; then printf '%s\n' "$PWD"; return; fi
    if command -v git >/dev/null 2>&1; then
        top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
        [ -n "$top" ] && { printf '%s\n' "$top"; return; }
    fi
    printf '%s\n' "$PWD"
}

guard_session() { # guard_session <cmd> — refuse session starts from unmounted folders
    local mounted cwd
    mounted="$(sed -n 's/^PROJECTS_DIR=//p' "$REPO_ROOT/.env" 2>/dev/null | tail -1)"
    [ -n "$mounted" ] || return 0
    mounted="${mounted/#\~/$HOME}"
    cwd="$(cwd_project_root)"
    case "$cwd" in
        "$REPO_ROOT"|"$REPO_ROOT"/*|"$mounted"|"$mounted"/*) return 0 ;;
    esac
    cat >&2 <<EOF

scc $1: refusing — you are probably trying to start an agent for a
different project.

  you are in:         $cwd
  the sandbox mounts: $mounted   (active workspace's PROJECTS_DIR)

One container stack mounts ONE project: starting here would run the agent
against $mounted anyway. Reconfigure first, then start again:

  scc status $cwd        # see exactly where this folder stands
  scc init $cwd          # not onboarded yet: register + activate + token
  scc ws list            # already onboarded — find its workspace name, then
  scc switch NAME        # activate it (regenerates .env) and run 'scc $1' again
EOF
    return 2
}

# --- the command table (single source of truth) ---------------------------------
# view|spelling|summary|note   — spelling is EXACTLY as typed at the top
# level, so every view can render it verbatim; group -h, per-command -h and
# the completion word lists all derive from these rows.
scc_table() {
    cat <<'EOF'
# view|spelling|summary|note
start|claude|start a Claude Code coding session in the sandbox
start|yolo|start Claude Code with permission prompts skipped (--dangerously-skip-permissions)
start|shell|interactive bash inside the sandbox (no agent)
run|run claude|same as scc claude, via the run group
run|run yolo|same as scc yolo, via the run group
run|run shell|same as scc shell, via the run group
run|run build|same as scc build, via the run group
run|run up|same as scc up, via the run group
run|run down|same as scc down, via the run group
run|run stop|same as scc stop, via the run group
run|run restart|same as scc restart — drops the dind sidecar + nested containers
lifecycle|build|build / rebuild the sandbox images
lifecycle|up|start the sandbox in the background (proxy, dind sidecar)
lifecycle|down|stop the sandbox and remove its containers (also nested sidecars)
lifecycle|stop|stop the containers but keep them
lifecycle|restart|down + up — drops the dind sidecar and every nested container
onboarding|init [~/path]|onboard a project: preflight, register workspace, GitHub App, token, activate|docs/scc.md
onboarding|status [~/path]|read-only per-folder setup feedback + the one command that closes the gap|make status PROJECT=…
github|token|mint a fresh 1 h project-scoped GitHub token and hand it to host gh (break-glass)|docs/github.md
github|renew|keep the token fresh (~every 50 min) while a session runs|docs/github.md
github|gh token|mint a fresh token, via the gh group|docs/github.md
github|gh renew|renew loop, via the gh group|docs/github.md
github|gh app|create + wire the per-project GitHub App (manifest flow, 2 browser clicks)|docs/github.md
github|gh app-rescue KEY=… [APP_ID=…]|re-wire an App from an existing PEM key|docs/github.md
egress|egress reload|apply an allowlist edit by rebuilding only the proxy (sessions kept)|docs/egress.md
egress|egress reload-images|recreate only the dind guard after an image-allowlist edit|docs/egress.md
egress|egress reload-ingress|recreate only the ingress after a port/config change
egress|egress learn|open + log ALL egress for one research pass (signing key removed)|docs/egress.md
egress|egress learn-off|leave learning mode and rebake the proxy with the allowlist
egress|egress learned|distill the logged domains into a minimal allowlist
egress|egress denied|show the proxy's denied domains
egress|denied|same as scc egress denied
egress|egress allowlist|where to edit the per-project allowlist (prints instructions)
egress|egress-reload|old spelling of scc egress reload
workspace|ws list|list workspace definitions, active one marked|docs/workspaces.md
workspace|workspaces|same as scc ws list
workspace|ws switch NAME=x|activate a definition (regenerates .env, cheapest sufficient apply)
workspace|switch <name>|same as scc ws switch NAME=<name>
workspace|ws new NAME=|create a machine-local workspace definition
workspace|ws add PROJECT=|register a repo-anchored workspace for a project
workspace|ws prune|remove definitions whose project folder is gone (dry run without tty; FORCE=1 skips the prompt)
workspace|ws rm NAME|remove ONE machine-local definition (asks which when omitted; project repo untouched; FORCE=1 skips the prompt)
tls + signing|tls certs|(re)mint the local dev CA + project certificates|docs/https.md
tls + signing|tls cert DOMAIN=x.test|mint one project certificate (DIR= overrides target)
tls + signing|tls renew|re-mint all project certs with fresh 3-day validity
tls + signing|tls keygen|generate the repo signing key
tls + signing|tls rotate-key|rotate + re-wrap the signing key
tls + signing|tls hooks|install the secret-blocking pre-commit hook into this repo
inspect|doctor|full hardening self-test (host + container)
inspect|ps|show containers — outer AND the ones nested inside dind
inspect|logs|follow proxy/dind/ingress logs
inspect|df|disk usage, host and nested dind daemon
maintenance|maintain prune|remove dangling images on the host (safe)
maintenance|maintain prune-build|clean the host build cache
maintenance|maintain prune-dind|prune dind-internal storage
maintenance|maintain clean|remove containers + local images
maintenance|maintain clean-dind|clean dind image/layer storage
maintenance|maintain distclean|remove EVERYTHING incl. volumes + logins (destructive)
meta|version|print scc's version and repo path
meta|completion <shell>|print the tab-completion script to stdout — wire it into your rc yourself; covers scc only|shell: bash or zsh · auto-detects $SHELL
meta|help|this overview (also: scc -h)
EOF
}

# --- renderers -------------------------------------------------------------------
scc_help() { # bare `scc`, `scc help`, `scc -h` — the full grouped listing
    cat <<'EOF'
scc — hardened Claude Code sandbox, per-project GitHub automation

EOF
    table_render_all
    cat <<'EOF'

  any command accepts -h — groups: scc gh -h · single: scc token -h
EOF
}

table_render_all() { # the top-level listing, wrapped
    scc_table | awk -F'|' '
        /^#/ { next }
        NF < 3 { next }
        {
            if (!($1 in pos)) { n++; pos[$1] = n; ord[n] = $1 }
            it[$1] = it[$1] == "" ? "scc " $2 : it[$1] " | " $2
        }
        END {
            W = 96
            labw = 14
            for (i = 1; i <= n; i++) {
                v = ord[i]; s = it[v]
                p1 = "  " sprintf("%-*s", labw, v) " "
                pl = "  " sprintf("%*s", labw, "") " "
                while (length(p1) + length(s) > W) {
                    cut = W - length(p1)
                    if (cut < 4) break
                    while (cut > 1 && substr(s, cut, 3) != " | ") cut--
                    if (cut <= 1) break
                    print p1 substr(s, 1, cut + 2)      # keeps the " | " at line end
                    s = substr(s, cut + 3)
                    p1 = pl
                }
                print p1 s
            }
        }'
}

table_view() { # table_view <view-label> — only that group's rows
    scc_table | awk -F'|' -v v="$1" '
        /^#/ { next }
        NF < 3 { next }
        $1 == v {
            printf "  %s\n", "scc " $2
            printf "      %s\n", $3
            if (NF >= 4 && $4 != "") printf "      note: %s\n", $4
        }'
}

table_pick() { # table_pick <spelling...> — exact row, else first-token match
    scc_table | awk -F'|' -v k="$*" '
        /^#/ { next }
        NF < 3 { next }
        { rows[++n] = $0 }
        END {
            hit = ""
            split(k, kw, " ")
            for (r = 1; r <= n && hit == ""; r++) {
                split(rows[r], f, "|")
                if (f[2] == k) hit = rows[r]
            }
            for (r = 1; r <= n && hit == ""; r++) {
                split(rows[r], f, "|")
                split(f[2], a, " ")
                if (a[1] == kw[1]) hit = rows[r]
            }
            if (hit != "") print hit
        }'
}

help_detail() { # help_detail <spelling...> — one command, fully
    local row view grp
    row="$(table_pick "$@")"
    if [ -z "$row" ]; then
        echo "scc: no help entry for '$*'" >&2
        return 1
    fi
    # view → the group command that opens this view (only where one exists)
    view="${row%%|*}"
    grp=""
    case "$view" in
        github)         grp="gh" ;;
        workspace)      grp="ws" ;;
        "tls + signing") grp="tls" ;;
        lifecycle)      grp="run" ;;
    esac
    printf '%s\n' "$row" | awk -F'|' '
        {
            printf "scc %s\n\n", $2
            printf "  %s\n", $3
            if (NF >= 4 && $4 != "") printf "\n  note: %s\n", $4
        }'
    [ -n "$grp" ] && printf '\n  group: scc %s -h\n' "$grp"
    return 0
}

ishelp() { case "${1:-}" in -h|--help) return 0 ;; *) return 1 ;; esac; }

export_var_args() { # trailing VAR=value arguments become the environment —
                    # docs/scc.md: "pass them as environment or after the arguments"
    local a k
    for a in "$@"; do
        k="${a%%=*}"
        case "$k" in
            ""|*[!A-Za-z0-9_]*) ;;                        # not a VAR=value token
            PATH|HOME|PWD|SHELL|SCC_REPO) ;;              # never re-map these
            *) export "$a" ;;
        esac
    done
}

# --- groups -------------------------------------------------------------------
# Every group function: bare/-h → group view; per-sub -h → detail; unknown
# sub → error + group view.

cmd_run() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        ""|-h|--help|help) table_view run; return 0 ;;
        claude|yolo|shell|build|up|down|stop|restart)
            ishelp "${1:-}" && { help_detail "run $sub"; return 0; }
            case "$sub" in
                claude|yolo|shell) guard_session "$sub" || { s=$?; return $s; } ;;
            esac
            run_make "$sub"
            ;;
        *)
            table_view run >&2
            echo "scc run: unknown '$sub'" >&2
            return 2
            ;;
    esac
}

cmd_gh() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        ""|-h|--help|help) table_view github; return 0 ;;
        token) run_make gh-token ;;
        renew) run_make gh-renew ;;
        app)
            ishelp "${1:-}" && { help_detail "gh app"; return 0; }
            run_make gh-app "PROJECT=${PROJECT:-$PWD}" "WS=${WS:-}"
            ;;
        app-rescue)
            ishelp "${1:-}" && { help_detail "gh app-rescue KEY=… [APP_ID=…]"; return 0; }
            [ -n "${KEY:-}" ] || { echo "scc gh app-rescue: KEY=<pem> required" >&2; exit 1; }
            run_make gh-app-wire "PROJECT=${PROJECT:-$PWD}" "KEY=$KEY" "APP_ID=${APP_ID:-}"
            ;;
        *)
            table_view github >&2
            echo "scc gh: unknown '$sub' (token|renew|app|app-rescue)" >&2
            return 2
            ;;
    esac
}

cmd_egress() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        ""|-h|--help|help) table_view egress; return 0 ;;
        reload)
            ishelp "${1:-}" && { help_detail "egress reload"; return 0; }
            run_make reload-egress
            ;;
        reload-images|reload-ingress)
            ishelp "${1:-}" && { help_detail "egress $sub"; return 0; }
            run_make "$sub"
            ;;
        learn)
            ishelp "${1:-}" && { help_detail "egress learn"; return 0; }
            run_make learn
            ;;
        learn-off)
            ishelp "${1:-}" && { help_detail "egress learn-off"; return 0; }
            run_make learn-off
            ;;
        learned)
            ishelp "${1:-}" && { help_detail "egress learned"; return 0; }
            run_make learned
            ;;
        denied)
            ishelp "${1:-}" && { help_detail "egress denied"; return 0; }
            run_make denied
            ;;
        allowlist)
            echo "edit <project>/egress/allowlist.txt (with '# why' comments), then: scc egress reload"
            ;;
        *)
            table_view egress >&2
            echo "scc egress: unknown '$sub' (reload|learn|learn-off|learned|denied)" >&2
            return 2
            ;;
    esac
}

cmd_ws() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        ""|-h|--help|help) table_view workspace; return 0 ;;
        list) run_make workspaces ;;
        switch)
            ishelp "${1:-}" && { help_detail "ws switch NAME=x"; return 0; }
            require_ws_name
            run_make workspace "NAME=$NAME"
            ;;
        new)
            ishelp "${1:-}" && { help_detail "ws new NAME="; return 0; }
            require_ws_name
            run_make new-workspace "NAME=$NAME"
            ;;
        add)
            ishelp "${1:-}" && { help_detail "ws add PROJECT="; return 0; }
            run_make add-workspace "PROJECT=${PROJECT:-$PWD}" "WS=${WS:-}"
            ;;
        prune)
            ishelp "${1:-}" && { help_detail "ws prune"; return 0; }
            run_make ws-prune
            ;;
        rm)
            ishelp "${1:-}" && { help_detail "ws rm NAME"; return 0; }
            # the name comes from the argument ONLY: an ambient env NAME
            # (the exact leak the 'workspace' target warns about) must never
            # pick the deletion target.
            run_make ws-rm "NAME=${1:-}"
            ;;
        *)
            table_view workspace >&2
            echo "scc ws: unknown '$sub' (list|switch NAME=|new NAME=|add PROJECT=|prune|rm NAME)" >&2
            return 2
            ;;
    esac
}

cmd_tls() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        ""|-h|--help|help) table_view "tls + signing"; return 0 ;;
        certs)
            ishelp "${1:-}" && { help_detail "tls certs"; return 0; }
            run_make certificates
            ;;
        cert)
            ishelp "${1:-}" && { help_detail "tls cert DOMAIN=x.test"; return 0; }
            run_make cert "DOMAIN=${DOMAIN:?usage: scc tls cert DOMAIN=myapp.test [DIR=]}" "DIR=${DIR:-}"
            ;;
        renew)
            ishelp "${1:-}" && { help_detail "tls renew"; return 0; }
            run_make renew-certs
            ;;
        keygen)
            ishelp "${1:-}" && { help_detail "tls keygen"; return 0; }
            run_make keygen
            ;;
        rotate-key)
            ishelp "${1:-}" && { help_detail "tls rotate-key"; return 0; }
            run_make rotate-signing-key
            ;;
        hooks)
            ishelp "${1:-}" && { help_detail "tls hooks"; return 0; }
            run_make install-hooks
            ;;
        *)
            table_view "tls + signing" >&2
            echo "scc tls: unknown '$sub' (certs|cert DOMAIN=|renew|keygen|rotate-key|hooks)" >&2
            return 2
            ;;
    esac
}

cmd_inspect() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        ""|-h|--help|help) table_view inspect; return 0 ;;
        doctor)
            ishelp "${1:-}" && { help_detail "doctor"; return 0; }
            run_make doctor
            ;;
        ps)
            ishelp "${1:-}" && { help_detail "ps"; return 0; }
            run_make ps
            ;;
        logs)
            ishelp "${1:-}" && { help_detail "logs"; return 0; }
            run_make logs
            ;;
        df)
            ishelp "${1:-}" && { help_detail "df"; return 0; }
            run_make df
            ;;
        *)
            table_view inspect >&2
            echo "scc inspect: unknown '$sub' (doctor|ps|logs|df)" >&2
            return 2
            ;;
    esac
}

cmd_maintain() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        ""|-h|--help|help) table_view maintenance; return 0 ;;
        prune|prune-build|prune-dind|clean|clean-dind|distclean)
            ishelp "${1:-}" && { help_detail "maintain $sub"; return 0; }
            run_make "$sub"
            ;;
        *)
            table_view maintenance >&2
            echo "scc maintain: unknown '$sub'" >&2
            return 2
            ;;
    esac
}

# --- completion -------------------------------------------------------------------
# `scc completion [bash|zsh]` — one command, stdout only, scc only. The word
# lists are derived from scc_table at emit time, so the table stays the
# single source of truth; the emitted script is static from then on.
completion_top_words() {
    scc_table | awk -F'|' '
        /^#/ { next }
        NF < 3 { next }
        { split($2, a, " ")
          if (!(a[1] in seen)) { seen[a[1]] = 1; w = w == "" ? a[1] : w " " a[1] } }
        END { print w }'
}

completion_case_branches() {
    scc_table | awk -F'|' '
        /^#/ { next }
        NF < 3 { next }
        {
            n = split($2, a, " ")
            if (n < 2) next
            w = a[2]
            if (w ~ /[<\[]/) next                       # placeholders: <cmd>, [~/path]
            if (!(a[1] in seen)) { seen[a[1]] = 1; keys[++kn] = a[1] }
            if (index(" " s[a[1]] " ", " " w " ") == 0) s[a[1]] = s[a[1]] == "" ? w : s[a[1]] " " w
        }
        END {
            for (i = 1; i <= kn; i++) printf "    %s) second=\"%s\" ;;\n", keys[i], s[keys[i]]
            printf "    completion) second=\"bash zsh\" ;;\n"
        }'
}

cmd_completion() {
    local sh="${1:-}"
    if ishelp "$sh"; then
        help_detail "completion [bash|zsh]"
        return 0
    fi
    if [ -z "$sh" ]; then
        case "$(basename "${SHELL:-/bin/bash}")" in
            zsh) sh=zsh ;;
            *)   sh=bash ;;
        esac
    fi
    local top branches
    top="$(completion_top_words)"
    branches="$(completion_case_branches)"
    case "$sh" in
        bash)
            printf '%s\n' \
                '# scc — bash tab-completion, generated by `scc completion`.' \
                '# Wire it up: save this output somewhere and source it from ~/.bashrc:' \
                '#   mkdir -p ~/.local/share/scc' \
                '#   scc completion bash > ~/.local/share/scc/completion.bash' \
                "#   echo 'source ~/.local/share/scc/completion.bash' >> ~/.bashrc" \
                '#   source ~/.bashrc        # make completion available immediately' \
                '#   (fast updates: make the wiring self-healing — docs/scc.md)' \
                "_scc_top=\"$top\"" \
                ''
            cat <<'BODY'
_scc() {
    local cur="$2" prev="$3" second=""
    case "$prev" in
BODY
            printf '%s\n' "$branches"
            cat <<'BODY'
    esac
    if [ "$COMP_CWORD" -le 1 ]; then
        COMPREPLY=( $(compgen -W "$_scc_top" -- "$cur") )
    else
        COMPREPLY=( $(compgen -W "$second" -- "$cur") )
    fi
}
complete -F _scc scc
BODY
            ;;
        zsh)
            printf '%s\n' \
                '#compdef scc' \
                '# scc — zsh tab-completion, generated by `scc completion`.' \
                '# Wire it up: put this file on your fpath as _scc, e.g.:' \
                '#   mkdir -p ~/.zsh/completions && scc completion zsh > ~/.zsh/completions/_scc' \
                "#   echo 'fpath=(~/.zsh/completions \$fpath)' >> ~/.zshrc && autoload -Uz compinit && compinit" \
                "_scc_top=($top)" \
                ''
            cat <<'BODY'
_scc() {
    local -a second
    if (( CURRENT == 2 )); then
        compadd -a _scc_top
        return
    fi
    case "$words[2]" in
BODY
            printf '%s\n' "$branches" | sed 's/second="\([^"]*\)"/second=(\1)/'
            cat <<'BODY'
    esac
    if [ -n "$second" ]; then
        compadd -a second
    fi
}
_scc "$@"
BODY
            ;;
        *)
            echo "scc completion: unsupported shell '$sh' (bash|zsh)" >&2
            return 2
            ;;
    esac
    if [ -t 1 ]; then
        echo >&2 "scc completion: printed the $sh script — wire it into your rc as shown in its first lines"
    fi
}

# --- init wizard -------------------------------------------------------------------
cmd_init() {
    if ishelp "${1:-}"; then
        help_detail "init [~/path]"
        return 0
    fi
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
  Auth (one-time): /login in the first session — or ANTHROPIC_API_KEY
                   in .env   (docs/setup.md)
  Commit .secure-container/ + egress/ in the project repo — the setup
  then travels with it (fresh machines onboard with: scc init <path>).
EOF
}

# --- status ---------------------------------------------------------------------
cmd_status() {
    if ishelp "${1:-}"; then
        help_detail "status [~/path]"
        return 0
    fi
    local target="${1:-$PWD}"
    run_make status "PROJECT=$target"
}

# --- dispatch -------------------------------------------------------------------
cmd="${1:-help}"
export_var_args "$@"
if [ "$cmd" = "-h" ] || [ "$cmd" = "--help" ]; then cmd=help; fi
case "$cmd" in
    help) scc_help ;;
    init) shift; cmd_init "$@" ;;
    status) shift; cmd_status "$@" ;;
    claude|yolo|shell|build|up|down|stop|restart)
        shift; ishelp "${1:-}" && { help_detail "$cmd"; exit 0; }
        cmd_run "$cmd" "$@"
        ;;
    run) shift; cmd_run "$@" ;;
    gh) shift; cmd_gh "$@" ;;
    token)
        shift; ishelp "${1:-}" && { help_detail token; exit 0; }
        cmd_gh token
        ;;
    renew) shift; ishelp "${1:-}" && { help_detail renew; exit 0; }; cmd_gh renew ;;
    egress) shift; cmd_egress "$@" ;;
    denied) shift; ishelp "${1:-}" && { help_detail denied; exit 0; }; cmd_egress denied ;;
    egress-reload) shift; ishelp "${1:-}" && { help_detail egress-reload; exit 0; }; run_make reload-egress ;;
    ws|workspaces) shift; cmd_ws "$@" ;;
    switch)
        shift; ishelp "${1:-}" && { help_detail "switch <name>"; exit 0; }
        NAME="${1:-}" cmd_ws switch
        ;;
    tls|certs) shift; cmd_tls "$@" ;;
    inspect) shift; cmd_inspect "$@" ;;
    doctor) shift; ishelp "${1:-}" && { help_detail doctor; exit 0; }; cmd_inspect doctor ;;
    ps|logs|df) shift; cmd_inspect "$cmd" "$@" ;;
    maintain) shift; cmd_maintain "$@" ;;
    completion) shift; cmd_completion "$@" ;;
    version|--version|-v)
        shift; ishelp "${1:-}" && { help_detail version; exit 0; }
        echo "scc (repo: $REPO_ROOT)"
        ;;
    *)
        echo "scc: unknown command '$cmd'" >&2
        scc_help >&2
        echo "  (or: scc <command> -h for that command's details)" >&2
        exit 2
        ;;
esac
