#!/bin/sh
# Pre-create the shared access log WORLD-READABLE (0644): the sandbox reads
# it across a different uid (and under podman keep-id a different userns
# mapping), so only the "other" read bit is reliable. install(1) also
# truncates on every start -> blocked-domains reports denials since the
# last proxy restart only.
set -eu
install -m 0644 /dev/null /var/log/squid/access.log
exec squid -N -f /etc/squid/squid.conf
