# Language toolchains & docker-in-docker

Set `TOOLCHAINS` in `.env` as a comma list — `TOOLCHAINS=php`,
`TOOLCHAINS=python,docker`, any combination — then
`make build && make restart`.

Each enabled toolchain automatically enables its registry domains at the
proxy (`egress/allowlist.d/<toolchain>.txt`) — and drops them again when
removed from the list — plus a doctor function check (20–23) asserting the
toolchain runs and its registry is reachable.

## `php`

Adds `php-cli` + a pinned, checksum-verified composer. Enables
packagist and the GitHub read-only dist endpoints (`api.github.com`,
`codeload.github.com` — deliberately not `github.com` itself, which would
open the git smart-HTTP protocol).

## `python`

Installs nothing extra (`python3`/`pip`/`venv` are base tooling); the
entry switches on PyPI access. Create virtualenvs inside `/workspace` —
`/tmp` is `noexec`, so native wheel builds fail there.

## `docker` (dind sidecar)

Installs a pinned static docker CLI + compose plugin and starts a
**rootless docker-in-docker sidecar** (compose profile, off otherwise) so
nested stacks like Laravel Sail (databases, mailpit, ...) run *inside* the
sandbox boundary. The host Docker socket stays absent (doctor check 5).

Key facts:

- The sidecar is `privileged` but userns-confined (see
  [DECISIONS.md](../DECISIONS.md)) — a host escape additionally requires a
  kernel/userns vulnerability.
- Registry pulls go through the egress allowlist (Docker Hub pull
  endpoints auto-enabled).
- Rootless dind cannot bind ports below 1024 (Sail: set `APP_PORT=8080`).
- Services published inside dind are reachable from the sandbox at the
  `dind` hostname (e.g. `curl dind:8080`).
- Nested image builds needing further domains (Ubuntu archives, PPAs,
  font CDNs) surface them via `blocked-domains`; the egress template
  documents the known Laravel Sail set, commented out.

### Image pull control

The sandbox talks to dind only through a filtering guard (`dind-guard`):

- Pulls are limited to images matching `dind/images-allowlist.txt`
  (local, from the tracked template; `make reload-images` applies edits
  without touching the daemon).
- `docker load` / import sideloading is denied outright.
- The daemon itself lives on an isolated network the sandbox cannot
  reach; the guard bridges it under the alias `dind` (filtered API on
  :2376, common dev ports TCP-forwarded). Bypass is topological, not
  policy.
- Known gap, accepted and documented: base images of nested
  `docker build`s are pulled daemon-internally by buildkit and are not
  filtered — the egress allowlist still bounds which registries are
  reachable at all.

### Nested networking

Containers inside dind have no DNS for outer compose names — they reach
the egress proxy via its static dind-net IP (172.30.0.3), which the
sandbox's docker client injects into nested builds and runs automatically.
Sail's app-image build works through this without any resolver.

### Host browser access (ingress)

Enable the ingress override (`docker-compose.override.example.yml`) to
reach a sandbox dev server at `http://localhost:8080` — inbound-only; it
forwards to the interactive session (`claude-session:8080`) or, as backup,
to an app published inside dind (`dind:8080`).

Selected service ports of the nested stack come along, all bound to
`127.0.0.1` on the host:

| Host port | Service |
|---|---|
| 8080 | app (session or dind) |
| 8025 | mailpit UI |
| 5432 | postgres (attach a host DB client) |
| 5173 | vite |

Never publish on `0.0.0.0` — that would put the sandbox's services on
your LAN. Note that a host process can reach the nested database with
whatever credentials the stack uses; that is the same exposure class as
the 8080 publication, limited to loopback.

To add a further port: bind it in `ingress/haproxy.cfg`, list it under the
override's `ports:`, and make sure `dind/haproxy.cfg` (`listen app_ports`)
forwards it too. Apply with `make reload-ingress`.

## Custom seccomp

`security/seccomp.json` documents the syscalls that matter; read its
`_comment` before enabling — the runtime default profile is the better
choice unless you have a concrete reason.
