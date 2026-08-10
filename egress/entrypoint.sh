#!/bin/sh
# Pre-create the shared access log WORLD-READABLE (0644): the sandbox reads
# it across a different uid (and under podman keep-id a different userns
# mapping), so only the "other" read bit is reliable. install(1) also
# truncates on every start -> blocked-domains reports denials since the
# last proxy restart only.
set -eu
install -m 0644 /dev/null /var/log/squid/access.log

# Expose the baked-in allowlist (non-secret) on the shared volume so
# `learned-domains` in the sandbox can subtract already-covered domains.
install -m 0644 /etc/squid/allowlist.txt /var/log/squid/allowlist-base.txt

case "${EGRESS_MODE:-allowlist}" in
    learning)
        echo "############################################################" >&2
        echo "# EGRESS LEARNING MODE — allowlist NOT enforced.           #" >&2
        echo "# Everything except LAN + git hosts is reachable & logged. #" >&2
        echo "# Distill with 'make learned'; leave with 'make learn-off'.#" >&2
        echo "############################################################" >&2
        exec squid -N -f /etc/squid/squid.conf.learning
        ;;
    allowlist)
        exec squid -N -f /etc/squid/squid.conf
        ;;
    *)
        echo "egress entrypoint: unknown EGRESS_MODE '${EGRESS_MODE}' (allowlist|learning)" >&2
        exit 1
        ;;
esac
