# Egress allowlist proxy (Squid), digest-pinned, runs as the unprivileged
# "proxy" user with a read-only rootfs (see docker-compose.yml).
FROM debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends squid ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY squid.conf /etc/squid/squid.conf
COPY allowlist.txt /etc/squid/allowlist-base.txt
COPY allowlist.d/ /etc/squid/allowlist.d/
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# Merge the machine-local base allowlist with the fragment matching the
# sandbox build target, so enabling/disabling dev-php/dev-python in .env
# automatically enables/disables the toolchain's domains. Comments and
# blank lines are stripped, duplicates deduplicated (squid warns on exact
# duplicates; domain-plus-parent-wildcard remains a fatal config error).
ARG SANDBOX_TARGET=runtime
RUN { cat /etc/squid/allowlist-base.txt; \
      case "$SANDBOX_TARGET" in \
        dev-php)    cat /etc/squid/allowlist.d/php.txt ;; \
        dev-python) cat /etc/squid/allowlist.d/python.txt ;; \
      esac; } \
    | grep -v '^[[:space:]]*#' | sed '/^[[:space:]]*$/d' | sort -u \
    > /etc/squid/allowlist.txt

EXPOSE 3128

USER proxy

# Entrypoint pre-creates the shared access log, then runs squid with
# -N: no daemonize (PID 1), config validated at startup.
CMD ["/usr/local/bin/entrypoint.sh"]
