# syntax=docker/dockerfile:1
#
# Hardened container image for running Claude Code in YOLO mode.
# Multi-stage, digest-pinned, non-root. See README.md for the threat model.
#
# Stages:
#   builder  — installs Claude Code into an isolated npm prefix (npm cache never
#              reaches the runtime image)
#   runtime  — final target: slim toolchain + Claude Code, non-root user.
#              The TOOLCHAINS build arg (comma list, e.g. "php,python")
#              conditionally adds language toolchains; python needs no
#              install (python3/pip/venv are base tooling) but is still a
#              valid entry — it switches the PyPI egress domains on.

# trixie (not bookworm): Debian 13 ships PHP 8.4 natively, keeping the
# php toolchain on Debian-signed packages without third-party repos.
ARG NODE_IMAGE=node:24-trixie-slim@sha256:0711b541c1c33a8a530ac4f0d391baa9a15b3d804695b1b24a47daa5fb60e74d

########################################################################
# builder — Claude Code npm install, isolated from the runtime image
########################################################################
FROM ${NODE_IMAGE} AS builder

# Version-pinned Claude Code. Bump deliberately; never use "latest".
ARG CLAUDE_CODE_VERSION=2.1.224

RUN mkdir -p /npm-global \
    && npm config set prefix /npm-global \
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force

########################################################################
# runtime — default target
########################################################################
FROM ${NODE_IMAGE} AS runtime

ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive

# Toolchain. No curl|bash installs anywhere: everything comes from the
# digest-pinned Debian repositories of the base image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bat \
        build-essential \
        ca-certificates \
        curl \
        fd-find \
        git \
        git-lfs \
        gnupg \
        jq \
        less \
        openssh-client \
        procps \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        tini \
    && rm -rf /var/lib/apt/lists/* \
    # Debian renames these binaries; provide the canonical names.
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && ln -s /usr/bin/batcat /usr/local/bin/bat

# Replace the base image's "node" user (uid 1000) with our "dev" user so the
# bind-mounted /workspace is owned by the host user (UID/GID build args).
RUN userdel -r node \
    && groupadd -g "${GID}" dev \
    && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash dev \
    && mkdir -p /workspace /home/dev/.claude /home/dev/.npm-global \
    && chown -R dev:dev /workspace /home/dev

# Claude Code from the builder stage — installed under the non-root user's
# npm prefix, never as root.
COPY --from=builder --chown=dev:dev /npm-global /home/dev/.npm-global

# Git wrapper shadows /usr/bin/git and blocks network subcommands
# (push/pull/fetch/clone/...). /usr/local/bin precedes /usr/bin in PATH.
COPY --chmod=0755 scripts/git-wrapper.sh /usr/local/bin/git

# Container-side git hooks (core.hooksPath) — enforce commit-message policy
# and signing-key age without polluting the mounted project repo.
COPY --chmod=0755 git-hooks/commit-msg git-hooks/pre-commit /opt/git-hooks/
COPY --chmod=0755 scripts/check-key-age.sh /usr/local/bin/check-key-age
COPY --chmod=0755 scripts/blocked-domains.sh /usr/local/bin/blocked-domains
COPY --chmod=0755 scripts/learned-domains.sh /usr/local/bin/learned-domains
COPY --chmod=0755 scripts/doctor.sh /usr/local/bin/doctor
COPY --chmod=0755 tests/make-fixtures.sh /usr/local/bin/make-fixtures
COPY --chmod=0755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

# Agent rules, copied into the persistent Claude config volume by the
# entrypoint so they apply to every mounted project.
COPY sandbox/CLAUDE.md /etc/claude/CLAUDE.md

# --- Optional language toolchains (TOOLCHAINS="php,python", see .env) ----
# php: php-cli + extensions and a version-pinned, checksum-verified
#      composer (no installer script).
# python: nothing to install — python3/pip/venv are base tooling above;
#      the entry only drives the egress allowlist and doctor check.
#      Virtualenvs belong in /workspace: /tmp is noexec, so native wheel
#      builds executing from $TMPDIR fail (accepted friction, DECISIONS.md).
ARG TOOLCHAINS=""
ARG COMPOSER_VERSION=2.10.2
ARG COMPOSER_SHA256=5ee7125f8a30a34d246cefdc0bc85b8a783b28f2aec968994118512350d28027

RUN case ",${TOOLCHAINS}," in \
    *,php,*) \
        apt-get update && apt-get install -y --no-install-recommends \
            php-cli \
            php-bcmath \
            php-curl \
            php-gd \
            php-intl \
            php-mbstring \
            php-mysql \
            php-sqlite3 \
            php-xml \
            php-zip \
            unzip \
        && rm -rf /var/lib/apt/lists/* \
        && curl -fsSLo /usr/local/bin/composer \
            "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar" \
        && echo "${COMPOSER_SHA256}  /usr/local/bin/composer" | sha256sum -c - \
        && chmod 0755 /usr/local/bin/composer \
        ;; \
    esac

# docker: static CLI + compose plugin talking to the rootless dind sidecar
# (DOCKER_HOST is set by compose). No daemon in this image. The CLI tgz has
# no vendor-published checksum — the sha256 below was computed at pin time
# (trust on first download, verified on every build thereafter). The client
# config injects the egress proxy into `docker build` runs inside dind so
# apt/composer/npm in nested builds obey the allowlist.
ARG DOCKER_CLI_VERSION=29.7.2
ARG DOCKER_CLI_SHA256=803d433f226db4776e1768fd319fc6c6e4935a456acf84fcc0080818b854bc8f
ARG COMPOSE_PLUGIN_VERSION=v5.4.0
ARG COMPOSE_PLUGIN_SHA256=837fd1d35bf6a494f41b5b5988269a7be79de337cf1a1a6ff0e45ab51bb4e9be
# Egress proxy's static IP on dind-net (docker-compose.yml) — by IP because
# containers nested inside dind cannot resolve outer compose names. The
# proxies config is injected by the docker client into nested builds and
# runs, so apt/composer/npm inside them obey the allowlist without DNS.
ARG EGRESS_PROXY_DIND_IP=172.30.0.3

RUN case ",${TOOLCHAINS}," in \
    *,docker,*) \
        curl -fsSLo /tmp/docker.tgz \
            "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz" \
        && echo "${DOCKER_CLI_SHA256}  /tmp/docker.tgz" | sha256sum -c - \
        && tar -xzf /tmp/docker.tgz -C /tmp docker/docker \
        && install -m 0755 /tmp/docker/docker /usr/local/bin/docker \
        && rm -rf /tmp/docker /tmp/docker.tgz \
        && mkdir -p /usr/local/lib/docker/cli-plugins \
        && curl -fsSLo /usr/local/lib/docker/cli-plugins/docker-compose \
            "https://github.com/docker/compose/releases/download/${COMPOSE_PLUGIN_VERSION}/docker-compose-linux-x86_64" \
        && echo "${COMPOSE_PLUGIN_SHA256}  /usr/local/lib/docker/cli-plugins/docker-compose" | sha256sum -c - \
        && chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose \
        && mkdir -p /etc/docker-client \
        && printf '%s\n' \
            '{"proxies":{"default":{' \
            "  \"httpProxy\":\"http://${EGRESS_PROXY_DIND_IP}:3128\"," \
            "  \"httpsProxy\":\"http://${EGRESS_PROXY_DIND_IP}:3128\"," \
            '  "noProxy":"localhost,127.0.0.1,dind"}}}' \
            > /etc/docker-client/config.json \
        ;; \
    esac

ENV PATH=/home/dev/.npm-global/bin:/usr/local/bin:/usr/bin:/bin \
    # All Claude Code state lives in the persistent named volume.
    CLAUDE_CONFIG_DIR=/home/dev/.claude \
    # Root filesystem is read-only; the npm prefix must never be written to.
    DISABLE_AUTOUPDATER=1 \
    # Caches go to tmpfs, not the read-only rootfs.
    npm_config_cache=/tmp/.npm \
    XDG_CACHE_HOME=/tmp/.cache \
    TMPDIR=/tmp \
    # Global git config lives on tmpfs — written by the entrypoint on every
    # start (rootfs and $HOME are read-only at runtime).
    GIT_CONFIG_GLOBAL=/tmp/.gitconfig \
    # Docker client config (proxy injection for nested builds); the path
    # only exists when the docker toolchain is enabled, harmless otherwise.
    DOCKER_CONFIG=/etc/docker-client

WORKDIR /workspace
USER dev

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["claude"]

