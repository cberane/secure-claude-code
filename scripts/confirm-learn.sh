#!/usr/bin/env bash
# confirm-learn.sh — gate `scc egress learn` / `make learn` when language
# toolchains are active.
#
# Learning mode opens egress completely. With php/python/docker enabled, the
# package managers and image pulls that are normally bounded to their
# registries can suddenly reach the whole internet — a malicious or
# typosquatted dependency the agent installs then has both arbitrary-code
# execution AND an open exfiltration channel. The docker toolchain also
# means a privileged dind sidecar is already running. So: refuse to proceed
# silently, spell out the exposure, and require an explicit typed "yes".
#
# Escape hatch for automation (no TTY): set LEARN_ACK=yes.
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

toolchains="$(sed -n 's/^TOOLCHAINS=//p' .env 2>/dev/null | tail -1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")"

# A GITHUB scope and an open proxy are mutually exclusive: the token mount
# would pair live repo-write access with unrestricted egress. Refuse BEFORE
# the toolchains early-exit below — scoped workspaces usually run with
# TOOLCHAINS set, but the minimal env must not bypass this gate either.
# On a terminal, REFUSING becomes an OFFER: scripts/workspace.sh scope-off
# writes a marked, empty GITHUB_* override into the machine-local
# workspaces/<active>.env (the merge chain's last-but-one word) and
# re-applies — the committed repo profile is never touched. `learn-off`
# offers the undo (scope-restore).
# A GITHUB scope and an open proxy are mutually exclusive: the token mount
# would pair live repo-write access with unrestricted egress. Refuse BEFORE
# the toolchains early-exit below — scoped workspaces usually run with
# TOOLCHAINS set, but the minimal env must not bypass this gate either.
# Value-based check: an EMPTY GITHUB_* line (the machine-local scope-off
# override) means no scope, not one.
gh_env_val() { # gh_env_val <KEY>
    sed -n "s/^$1=//p" .env 2>/dev/null | tail -1 \
        | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}
if [ -n "$(gh_env_val GITHUB_APP_ID)" ] \
    && [ -n "$(gh_env_val GITHUB_REPO)" ]; then
    if [ -t 0 ]; then
        cat >&2 <<EOF
┌─ LEARNING MODE + GITHUB SCOPE ────────────────────────
│ The active workspace declares a GITHUB scope; its short-
│ lived token would pair with completely open egress.
│
│ I can switch the scope off temporarily — machine-local
│ override only, the committed profile stays as it is —
│ and continue into learning mode. \`learn-off\` offers to
│ restore it on the way out.
└───────────────────────────────────────────────────────
EOF
        if scripts/workspace.sh scope-off; then
            echo "confirm-learn: scope switched off — continuing into learning mode." >&2
            exit 0
        fi
        cat >&2 <<'EOF'
Manual alternatives instead:
  * scc egress scope-off    (machine-local; rerun learn afterwards)
  * scc switch <name>       (a workspace without a GitHub scope)
  * remove GITHUB_* from .secure-container/workspace.env, then re-switch
    (edits the committed repo profile)
EOF
        exit 1
    fi
    cat >&2 <<EOF
┌─ REFUSED — LEARNING MODE + GITHUB SCOPE ──────────────
│ The active workspace declares a GITHUB scope; its short-
│ lived token would pair with completely open egress.
│ Non-interactively nothing is changed. Options:
│   * confirm on a terminal: rerun 'scc egress learn'
│   * switch the scope off first: scc egress scope-off
│   * switch to an unscoped workspace; or remove GITHUB_* from
│     .secure-container/workspace.env and re-switch.
└───────────────────────────────────────────────────────
EOF
    exit 1
fi

# No toolchains: minimal env, the intended pairing — nothing to confirm.
[ -z "$toolchains" ] && exit 0

cat >&2 <<EOF

┌─ LEARNING MODE + TOOLCHAINS — CONFIRM ────────────────
│ Active toolchains: $toolchains
│
│ Learning mode opens egress to the whole internet. With a
│ toolchain enabled this widens the blast radius sharply:
│   * composer / pip / npm can now fetch from anywhere, so
│     a malicious dependency gets code execution AND an open
│     channel to send data out.
│   * the docker toolchain already runs a privileged dind
│     sidecar.
│
│ RECOMMENDED instead: run learning mode in the minimal
│ environment. On the host:
│     set TOOLCHAINS= in .env
│     scc build
│     scc egress learn
│
│ Proceed with toolchains active only if you understand and
│ accept this. Type 'yes' to continue.
└───────────────────────────────────────────────────────
EOF

if [ ! -t 0 ]; then
    if [ "${LEARN_ACK:-}" = "yes" ]; then
        echo "confirm-learn: LEARN_ACK=yes — proceeding non-interactively." >&2
        exit 0
    fi
    echo "confirm-learn: not a terminal and LEARN_ACK is not 'yes' — aborting." >&2
    exit 1
fi

printf 'Type yes to enter learning mode with toolchains active: ' >&2
read -r answer
if [ "$answer" = "yes" ]; then
    exit 0
fi
echo "Aborted — learning mode not entered." >&2
exit 1
