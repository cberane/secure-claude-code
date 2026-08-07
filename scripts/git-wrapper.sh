#!/usr/bin/env bash
# git wrapper — shadows /usr/bin/git inside the container and blocks every
# subcommand that talks to a remote. Committing stays local; pushing and
# pulling are host-only operations by design (see README.md).
#
# This is the first line of defense; the egress proxy (which allowlists no
# git hosts) is the second.

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
    cat >&2 <<EOF

┌─ HOST ACTION REQUIRED ────────────────────────────────
│ 'git ${subcommand}' is blocked inside this sandbox.
│ Remote operations are host-only by design.
│
│ Run this on the HOST, then confirm here:
│
│   cd ${project} && ${host_cmd}
│
└───────────────────────────────────────────────────────
EOF
    exit 1
}

if [ -n "$subcommand" ]; then
    rest=("${args[@]:$((subcommand_idx + 1))}")
    case "$subcommand" in
        push)
            branch="$("$REAL_GIT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '<branch>')"
            block "git push origin ${branch}"
            ;;
        pull)
            block "git pull"
            ;;
        fetch)
            block "git fetch --all --prune"
            ;;
        clone)
            block "git clone <url>"
            ;;
        ls-remote)
            block "git ls-remote <remote>"
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
