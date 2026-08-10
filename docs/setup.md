# Setup

## Prerequisites

A **Linux host, or Windows with WSL2**. The host-side scripts use GNU
coreutils (`stat -c`, `date -d`) and do not run on macOS.

Required on the host:

- **Docker Engine** with the **compose plugin ≥ 2.24** (the compose files
  use the long `env_file` syntax) — or rootless **podman**, see
  [podman.md](podman.md).
- **GNU make**, **bash**, **jq**, **ssh-keygen** (openssh-client), **git**.

`make preflight` checks all of this and is run automatically before every
build/start target — but you can run it alone first.

## First run

```sh
cp .env.example .env      # then edit — see the reference below
make build
make claude               # agent with permission prompts
# make yolo               # agent with full autonomy (--dangerously-skip-permissions)
# make shell              # plain bash inside the sandbox, no agent
```

Contributors to this repo also run `make install-hooks` once (commit-msg
policy hook); for merely *using* the sandbox it is not needed.

On the first `make` run, two local policy files are created from their
tracked templates (and never overwritten afterwards):

- `egress/allowlist.txt` — which domains the sandbox may reach.
- `dind/images-allowlist.txt` — which images the dind sidecar may pull
  (only relevant with the `docker` toolchain).

Both are gitignored: extend them freely per machine, then apply with
`make reload-egress` / `make reload-images`. Only entries every user needs
belong in the templates.

## Signing key

On first start, `make` provisions a dedicated **signing-only** SSH key
under `secrets/git-signing/` (host-side, gitignored) and prints the public
key. Register it at your forge as a **Signing Key** — *not* an
authentication key — then confirm the prompt. Details and rotation policy:
[signing.md](signing.md).

## Authentication

Pick one:

- **OAuth (no key on disk):** leave `ANTHROPIC_API_KEY` empty and run
  `/login` once inside `make claude`. The flow prints a URL — open it in
  your **host** browser (the container has none), authorize, and paste the
  code back into the container prompt. The token persists in the
  `claude-config` volume across restarts.
- **API key:** set `ANTHROPIC_API_KEY` in `.env`.

## `.env` reference

| Variable | Default | Meaning |
|---|---|---|
| `ENGINE` | `docker` | `docker` or `podman`. On the make command line it must be passed explicitly (`make ENGINE=podman …`) — as a plain environment variable it loses against `.env`. |
| `PROJECTS_DIR` | — (required) | Absolute host path mounted at `/workspace` — the **only** writable bind mount. |
| `UID` / `GID` | `1000` | Your host IDs (`id -u` / `id -g`), so workspace files belong to you. Baked in at build time. |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | — | Identity for commits made inside the container. |
| `ANTHROPIC_API_KEY` | empty | See Authentication above. |
| `ANTHROPIC_MODEL` | empty | Optional model override. |
| `TOOLCHAINS` | empty | Comma list: `php`, `python`, `docker` — see [toolchains.md](toolchains.md). Apply with `make build && make restart`. |
| `MEM_LIMIT`, `CPUS`, `PIDS_LIMIT`, `NOFILE`, `TMP_SIZE` | 4g/2/512/4096/512m | Sandbox resource limits. |
| `DIND_MEM_LIMIT` | 4g | Memory limit of the dind sidecar (docker toolchain only). |
| `SIGNING_KEY_WARN_DAYS` / `SIGNING_KEY_MAX_DAYS` | 30 / 45 | Key-rotation policy, see [signing.md](signing.md). |
| `SIGNING_KEY_ENFORCE` | `true` | `false` turns the max-age commit block into a warning. Don't leave it off. |

Note: the Makefile reads `.env` with Make's `include`, so values containing
`#` or `$` will be mangled on the host side — avoid them (in the container
the file is parsed by compose, which handles them differently; simplest is
to use neither).

## Local overrides

Machine-specific compose tweaks go into `docker-compose.override.yml`
(gitignored; copy from `docker-compose.override.example.yml`). Typical
uses: the host-ingress service, more memory, extra **read-only** mounts,
a custom seccomp profile. Docker auto-loads the file; with
`ENGINE=podman` the Makefile appends it explicitly.

An override can silently weaken the hardening — **run `make doctor` after
every override change**.
