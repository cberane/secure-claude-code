#!/usr/bin/env bash
# confirm-learn.sh — gate `make learn` when language toolchains are active.
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
│     make build
│     make learn
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
