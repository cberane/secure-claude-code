#!/bin/sh
# Compose plugin wrapper — injects the egress proxy into nested builds.
#
# The sandbox docker CLI ships WITHOUT the buildx component, so nested
# `docker compose build` (and everything invoking it, e.g. Laravel Sail)
# runs through the LEGACY builder. There, compose resolves the docker
# client config's proxy values (config.json, camelCase keys) into
# UPPERCASE-only build args — and apt (noble) honors lowercase
# http_proxy/https_proxy only. Nested builds consequently fail with
# "Temporary failure resolving <domain>" (docs/toolchains.md,
# "Nested networking"; verified there with isolated probe builds).
#
# This file is installed as the docker CLI's compose plugin (the CLI reads
# $DOCKER_CONFIG/cli-plugins FIRST, shadowing the real plugin — which the
# shim itself execs — at /usr/local/lib/docker/cli-plugins/docker-compose).
#
# NOTE: exec'ing the real plugin must keep a basename ending in
# "docker-compose": compose branches on argv[0] (invoking it as
# "...-docker-compose-real" breaks the plugin handshake).
#
# Behavior:
#   * build — the lowercase proxy build args are inserted directly after
#     the subcommand, i.e. BEFORE any user args: an explicit user
#     `--build-arg http_proxy=...` therefore still wins (the last
#     occurrence of an arg is the effective one).
#   * up/run/create — these auto-build missing images but accept no
#     per-invocation build-arg; the wrapper prebuilds ALL build-capable
#     services of the project first (a no-op against the build cache when
#     everything is current). A failed prebuild only prints a warning;
#     the wrapper must NOT make any invocation worse than compose itself.
#   * everything else is a transparent passthrough (incl. `docker compose
#     bake`, unreachable here — its fallback takes the covered legacy path).
#
# The plugin is invoked with argv = [ "compose", <subcommand>, ...] and
# global flags may precede the subcommand ("docker compose -f x build"),
# so the subcommand is found by scanning: flags are skipped; the flags
# known to take a value also skip their value. The invocation is then
# reassembled as <pre> <sub> [args] <post>; newline-joined variables +
# IFS splitting preserve args containing spaces (paths).

REAL=/usr/local/lib/docker/cli-plugins/docker-compose
PROXY="http://@EGRESS_PROXY_DIND_IP@:3128"
NL='
'

# The docker CLI dispatches commands to the plugin as
#   argv = [ "compose", <subcommand>, <args...> ]     (marker-verified)
# while the plugin-metadata handshake arrives WITHOUT that prefix
# (argv = [ "docker-cli-plugin-metadata" ]) and must pass through untouched.
sub=""
subpos=0
value_flag=0
skip_compose=1
pos=0
for arg in "$@"; do
    pos=$((pos + 1))
    if [ "$skip_compose" -eq 1 ] && [ "$arg" = "compose" ]; then
        skip_compose=0
        continue
    fi
    if [ "$value_flag" -eq 1 ]; then
        value_flag=0
        continue
    fi
    case "$arg" in
        -f|--file|--profile|--project-name|-p|--project-directory|--env-file)
            value_flag=1 ;;
        -*)
            ;;
        *)
            sub=$arg
            subpos=$pos
            break ;;
    esac
done
[ -n "$sub" ] || exec "$REAL" "$@"

pre=""
post=""
pos=0
for arg in "$@"; do
    pos=$((pos + 1))
    if [ "$pos" -lt "$subpos" ]; then
        pre="$pre$arg$NL"
    elif [ "$pos" -gt "$subpos" ]; then
        post="$post$arg$NL"
    fi
done

oldIFS=$IFS
IFS=$NL

case "$sub" in
    build)
        set --
        for arg in $pre; do
            set -- "$@" "$arg"
        done
        set -- "$@" "$sub" \
            --build-arg "http_proxy=$PROXY" \
            --build-arg "https_proxy=$PROXY" \
            --build-arg "no_proxy=localhost,127.0.0.1,dind"
        for arg in $post; do
            set -- "$@" "$arg"
        done
        IFS=$oldIFS
        exec "$REAL" "$@"
        ;;
    up|run|create)
        # Prebuild every build-capable service (WITHOUT the up/run flags —
        # build does not accept them; services without build: are simply
        # not built). Proxy arg values are constants, so the build cache
        # stays stable and the prebuild is instant when up to date.
        set --
        for arg in $pre; do
            set -- "$@" "$arg"
        done
        set -- "$@" build \
            --build-arg "http_proxy=$PROXY" \
            --build-arg "https_proxy=$PROXY" \
            --build-arg "no_proxy=localhost,127.0.0.1,dind"
        prelog="$(mktemp)"
        if ! "$REAL" "$@" >"$prelog" 2>&1; then
            echo "compose shim: proxied prebuild failed — continuing with" \
                 "compose's own behavior" >&2
            cat "$prelog" >&2
        fi
        rm -f "$prelog"
        # Delegate with the original invocation (pre + sub + post).
        set --
        for arg in $pre; do
            set -- "$@" "$arg"
        done
        set -- "$@" "$sub"
        for arg in $post; do
            set -- "$@" "$arg"
        done
        IFS=$oldIFS
        exec "$REAL" "$@"
        ;;
    *)
        # Transparent passthrough with the ORIGINAL argv untouched
        # (this is also what answers the CLI's plugin-metadata handshake).
        IFS=$oldIFS
        exec "$REAL" "$@" ;;
esac