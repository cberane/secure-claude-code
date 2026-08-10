# Hardened Claude Code Sandbox

Run Claude Code in YOLO mode (`--dangerously-skip-permissions`) inside a
container where the **maximum possible damage is the loss of the mounted
project directory** — nothing beyond that.¹ Projects live in git and are
pushed from the host, so even that damage is recoverable.

The container has no credentials, no host network, no docker socket, a
read-only rootfs, and exactly one way out: an allowlist egress proxy. Git
pushes/pulls happen only on the host; commits inside are signed with a
dedicated signing-only key. Every claimed property is asserted by
`make doctor`.

¹ With the optional docker-in-docker toolchain enabled, its sidecar runs
`privileged` inside a user namespace — escaping it to the host additionally
requires a kernel/userns vulnerability. Details:
[docs/architecture.md](docs/architecture.md).

## Prerequisites

- **Linux host or Windows + WSL2** (macOS is not supported — host scripts
  are GNU-only).
- Docker Engine with compose plugin **≥ 2.24**, or rootless podman.
- `make`, `bash`, `jq`, `ssh-keygen`, `git`.

`make preflight` verifies all of this with actionable messages.

## Getting started

```sh
cp .env.example .env      # set PROJECTS_DIR, UID/GID, git identity
make build
make claude               # or: make yolo  (--dangerously-skip-permissions)
```

First run walks you through two one-time steps:

1. A **signing-only** SSH key is generated on the host; register it at
   your forge as a *Signing Key* (not authentication).
2. Authenticate Claude Code: `ANTHROPIC_API_KEY` in `.env`, or run
   `/login` once inside (open the printed URL in your host browser).

Then verify the hardening:

```sh
make doctor               # 19 hardening checks + toolchain function checks
```

## Daily use in one table

| Where | What |
|---|---|
| Container (`make claude` / `make yolo`) | edit, build, test, `git add`, `git commit` (auto-signed) |
| Host | `git push` / `pull` / `fetch`, allowlist edits, key rotation |

When the agent needs anything host-only (a push, a new egress domain, a
new dind image), it stops and prints a `HOST ACTION REQUIRED` box with the
exact command. Run it, tell the agent to continue.
[docs/workflow.md](docs/workflow.md) has the full protocol.

## Documentation

| Doc | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Threat model, trust boundaries, what doctor proves |
| [docs/setup.md](docs/setup.md) | Prerequisites, `.env` reference, authentication, local overrides |
| [docs/workflow.md](docs/workflow.md) | Daily workflow, HOST ACTION REQUIRED protocol, reload targets, visibility |
| [docs/signing.md](docs/signing.md) | Commit signing, key rotation, the exfiltration trade-off |
| [docs/toolchains.md](docs/toolchains.md) | php/python/docker toolchains, dind, image-pull control, host ingress |
| [docs/podman.md](docs/podman.md) | Rootless podman differences |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Recovery, disk management, common first-run errors |
| [DECISIONS.md](DECISIONS.md) | Why it is built this way (ADR-style rationale) |

Contributing: [CONTRIBUTING.md](CONTRIBUTING.md) · Vulnerabilities:
[SECURITY.md](SECURITY.md)

## Status & license

Unofficial project, not affiliated with or endorsed by Anthropic.
"Claude Code" is an Anthropic product; this repo only packages a hardened
environment around it.

[MIT](LICENSE)
