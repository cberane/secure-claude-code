# Egress allowlist proxy (Squid), digest-pinned, runs as the unprivileged
# "proxy" user with a read-only rootfs (see docker-compose.yml).
FROM debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends squid ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY squid.conf /etc/squid/squid.conf
COPY allowlist.txt /etc/squid/allowlist.txt
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

EXPOSE 3128

USER proxy

# Entrypoint pre-creates the shared access log, then runs squid with
# -N: no daemonize (PID 1), config validated at startup.
CMD ["/usr/local/bin/entrypoint.sh"]
