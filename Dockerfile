# syntax=docker/dockerfile:1
#
# Hardened container image for running Claude Code in YOLO mode.
# Multi-stage, digest-pinned, non-root. See README.md for the threat model.
#
# Stages:
#   builder  — installs Claude Code into an isolated npm prefix (npm cache never
#              reaches the runtime image)
#   runtime  — default target: slim toolchain + Claude Code, non-root user
#   dev-php  — optional target (--target dev-php): adds php-cli + composer

ARG NODE_IMAGE=node:24-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03

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
COPY --chmod=0755 scripts/doctor.sh /usr/local/bin/doctor
COPY --chmod=0755 tests/make-fixtures.sh /usr/local/bin/make-fixtures
COPY --chmod=0755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

# Agent rules, copied into the persistent Claude config volume by the
# entrypoint so they apply to every mounted project.
COPY sandbox/CLAUDE.md /etc/claude/CLAUDE.md

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
    GIT_CONFIG_GLOBAL=/tmp/.gitconfig

WORKDIR /workspace
USER dev

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["claude"]

########################################################################
# dev-php — optional target: PHP toolchain + composer
########################################################################
FROM runtime AS dev-php

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
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
    && rm -rf /var/lib/apt/lists/*

# Composer: version-pinned download, checksum-verified. No installer script.
ARG COMPOSER_VERSION=2.10.2
ARG COMPOSER_SHA256=5ee7125f8a30a34d246cefdc0bc85b8a783b28f2aec968994118512350d28027

RUN curl -fsSLo /usr/local/bin/composer \
        "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar" \
    && echo "${COMPOSER_SHA256}  /usr/local/bin/composer" | sha256sum -c - \
    && chmod 0755 /usr/local/bin/composer

USER dev

########################################################################
# dev-python — optional target: Python toolchain
########################################################################
FROM runtime AS dev-python

USER root

# Debian-packaged interpreter and tooling — nothing fetched from PyPI at
# build time, so there is no version pin to maintain here. Virtualenvs
# belong in /workspace: /tmp is noexec, so native wheel builds executing
# from $TMPDIR fail (same accepted friction as npm, see DECISIONS.md).
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

USER dev
