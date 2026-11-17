#!/usr/bin/env bash
# git wrapper — shadows /usr/bin/git inside the container and blocks every
# subcommand that talks to a remote. Committing stays local; pushing and
# pulling are, by default, host-only operations (see docs/workflow.md).
#
# Exception — the GITHUB scope (docs/github.md): when the workspace's merged
# config declares one (GITHUB_APP_ID/GITHUB_REPO in the container env), the
# network subcommands are allowed for the scope's own repos over HTTPS.
# This wrapper is a STOP SIGNAL, not a security boundary (absolute-path
# /usr/bin/git, `git config remote.*.url` rewrites and -c aliases bypass
# it) — the hard boundary is the minted token's repositories scope, and the
# credential helper only ever talks to github.com hosts.

set -u

REAL_GIT=/usr/bin/git

# --- find the subcommand, skipping git's global options -------------------
args=("$@")
subcommand=""
subcommand_idx=-1
i=0
while [ $i -lt ${#args[@]} ]; do
    a="${args[$i]}"
    case "$a" in
        # global options that consume a following value
        -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env|--attr-source)
            i=$((i + 2)); continue ;;
        # global options with inline value or none
        --*=*|-*)
            i=$((i + 1)); continue ;;
        *)
            subcommand="$a"
            subcommand_idx=$i
            break ;;
    esac
done

block() {
    local host_cmd="$1"
    local project
    project="$(basename "$(pwd)")"
    local scope_note=""
    if gh_scope_active; then
        scope_note="│ GITHUB scope is active for: ${GITHUB_REPO}
│ (push/pull/fetch/ls-remote over HTTPS to those repos works,
│  token auth is automatic; expired → ask the host:
│  make gh-renew / make gh-token — docs/github.md)
│"
    fi
    cat >&2 <<EOF

┌─ HOST ACTION REQUIRED ────────────────────────────────
│ 'git ${subcommand}' is blocked inside this sandbox.
│ Remote operations outside the workspace GITHUB scope are
│ host-only.
${scope_note}
│ Run this on the HOST, then confirm here:
│
│   cd ${project} && ${host_cmd}
│
└───────────────────────────────────────────────────────
EOF
    exit 1
}

# True when the workspace declares a GITHUB scope via the container env.
gh_scope_active() {
    [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_REPO:-}" ]
}

# Resolve a push/pull/fetch argument (remote name or URL) to a URL.
remote_url() {
    case "$1" in
        https://*|ssh://*|git@*|http://*) printf '%s\n' "$1" ;;
        *) "$REAL_GIT" remote get-url "$1" 2>/dev/null || printf '%s\n' "$1" ;;
    esac
}

# Is this URL within the declared scope's HTTPS transport? Repo list comes
# from GITHUB_REPO (comma list) in the container env. Authority must be
# exactly github.com (optionally user@github.com) — a foreign host that
# merely embeds "github.com" in its path is rejected.
url_in_scope() {
    printf '%s' "$1" | grep -Eq '^https?://([^@/]+@)?github\.com/' || return 1
    local path="${1#*github.com/}"
    path="${path%%\?*}"
    path="${path%.git}"
    path="${path%/}"
    local r
    for r in ${GITHUB_REPO//,/ }; do
        [ "$path" = "$r" ] && return 0
    done
    return 1
}

# First positional argument of push/pull/fetch/ls-remote — a remote name or
# a URL; defaults to origin.
first_remote_arg() {
    local a
    for a in ${rest[@]+"${rest[@]}"}; do
        case "$a" in -*) continue ;; *) printf '%s\n' "$a"; return 0 ;; esac
    done
    printf '%s\n' origin
}

# push/pull/fetch/ls-remote for a scoped repo on HTTPS: allow (the token
# and the egress scope file do the real gating); anything else: block.
network_ok() { # network_ok <remote-or-url>
    gh_scope_active || return 1
    local url
    url="$(remote_url "$1")"
    url_in_scope "$url"
}

if [ -n "$subcommand" ]; then
    rest=("${args[@]:$((subcommand_idx + 1))}")
    case "$subcommand" in
        push)
            branch="$("$REAL_GIT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '<branch>')"
            if ! network_ok "$(first_remote_arg)"; then
                block "git push origin ${branch}"
            fi
            ;;
        pull)
            if ! network_ok "$(first_remote_arg)"; then
                block "git pull"
            fi
            ;;
        fetch)
            if ! network_ok "$(first_remote_arg)"; then
                block "git fetch --all --prune"
            fi
            ;;
        clone)
            block "git clone <url>"
            ;;
        ls-remote)
            if ! network_ok "$(first_remote_arg)"; then
                block "git ls-remote <remote>"
            fi
            ;;
        request-pull)
            block "git request-pull <start> <url>"
            ;;
        remote)
            for r in ${rest[@]+"${rest[@]}"}; do
                case "$r" in
                    add|set-url|update|prune)
                        block "git remote $r ..."
                        ;;
                    -*) continue ;;
                    *) break ;;
                esac
            done
            ;;
        submodule)
            saw_update=0
            for r in ${rest[@]+"${rest[@]}"}; do
                case "$r" in
                    add) block "git submodule add <url>" ;;
                    update) saw_update=1 ;;
                    --remote|--init)
                        if [ "$saw_update" = 1 ]; then
                            block "git submodule update $r"
                        fi
                        ;;
                esac
            done
            ;;
    esac
fi

exec "$REAL_GIT" "$@"
