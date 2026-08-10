# Egress allowlist proxy (Squid), digest-pinned, runs as the unprivileged
# "proxy" user with a read-only rootfs (see docker-compose.yml).
FROM debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends squid ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY squid.conf /etc/squid/squid.conf
COPY squid.conf.learning /etc/squid/squid.conf.learning
COPY git-hosts-deny.txt /etc/squid/git-hosts-deny.txt
COPY allowlist.txt /etc/squid/allowlist-base.txt
COPY allowlist.d/ /etc/squid/allowlist.d/
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# Merge the machine-local base allowlist with one fragment per enabled
# toolchain (TOOLCHAINS is a comma list, e.g. "php,python"), so enabling/
# disabling toolchains in .env automatically enables/disables their
# domains. An unknown toolchain name fails the build (missing fragment
# file). Comments and blank lines are stripped, duplicates deduplicated
# (squid warns on exact duplicates; domain-plus-parent-wildcard remains a
# fatal config error).
ARG TOOLCHAINS=""
# The existence guard must be a separate step: inside the merge pipeline a
# failing cat would be masked by the pipeline's exit status.
RUN for t in $(printf '%s' "$TOOLCHAINS" | tr ',' ' '); do \
        [ -f "/etc/squid/allowlist.d/${t}.txt" ] \
            || { echo "unknown toolchain '${t}' (no allowlist fragment)" >&2; exit 1; }; \
    done \
    && { cat /etc/squid/allowlist-base.txt; \
         for t in $(printf '%s' "$TOOLCHAINS" | tr ',' ' '); do \
           cat "/etc/squid/allowlist.d/${t}.txt"; \
         done; } \
       | grep -v '^[[:space:]]*#' | sed '/^[[:space:]]*$/d' | sort -u \
       > /etc/squid/allowlist.txt

EXPOSE 3128

USER proxy

# Entrypoint pre-creates the shared access log, then runs squid with
# -N: no daemonize (PID 1), config validated at startup.
CMD ["/usr/local/bin/entrypoint.sh"]
