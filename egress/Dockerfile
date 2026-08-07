# Egress allowlist proxy (Squid), digest-pinned, runs as the unprivileged
# "proxy" user with a read-only rootfs (see docker-compose.yml).
FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends squid ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY squid.conf /etc/squid/squid.conf
COPY allowlist.txt /etc/squid/allowlist.txt

EXPOSE 3128

USER proxy

# -N: no daemonize (PID 1), config validated at startup.
CMD ["squid", "-N", "-f", "/etc/squid/squid.conf"]
