# Architecture & threat model

What the sandbox promises, how the pieces enforce it, and where the honest
limits are. The reasoning behind each decision lives in
[DECISIONS.md](../DECISIONS.md).

## The promise

An agent running inside with full permissions (`--dangerously-skip-permissions`)
can, at worst, destroy the **one mounted project directory**. Projects live
in git and are pushed from the host, so even that damage is recoverable.

Two qualifications, stated up front:

- With the optional `docker` toolchain, the dind sidecar runs `privileged`
  (unavoidable even rootless). It is confined to a user namespace, so
  escaping to the host *additionally* requires a kernel/userns
  vulnerability — a real but materially higher bar. Without that toolchain
  the sidecar does not exist.
- The promise assumes a correctly configured setup: local overrides can
  weaken the hardening, which is why `make doctor` exists and should run
  after every override change.

## Threat model

| Threat | Mitigation |
|---|---|
| Credential theft / exfiltration | No SSH keys, cloud tokens or keychains exist in the container; entrypoint aborts if `~/.ssh` contains key material; egress allowlist leaves no exfiltration channel |
| Container escape / privilege escalation | Non-root user, `cap_drop: ALL`, `no-new-privileges`, read-only rootfs, no docker socket, no host network, default seccomp profile |
| Uncontrolled egress | Internal-only network; the sole way out is an allowlist proxy that also denies all private/LAN address ranges |
| Unwanted remote mutations | git wrapper blocks `push/pull/fetch/clone/remote add\|set-url/...`; git hosts are deliberately absent from the egress allowlist (second line of defense) |
| Blast radius beyond the project | Exactly one writable bind mount (`/workspace`); everything else read-only or tmpfs |

**Accepted residual risk:** the agent can destroy files in the mounted
project directory. That is the deal — commit early, push from the host.

Further accepted, documented gaps (with compensating controls) are listed
in [SECURITY.md](../SECURITY.md) and reasoned through in
[DECISIONS.md](../DECISIONS.md).

## Trust boundaries

```
 HOST ──────────────────────────────────────────────────────────────────
 │  ~/.ssh, cloud creds, browser sessions   <- never cross the boundary
 │  secrets/git-signing/   (created & rotated ONLY here)
 │  git push / pull / fetch                 (ONLY here)
 │
 │  docker/podman compose
 │  ┌─ sandbox network (internal: true — no gateway, no LAN) ─────────┐
 │  │                                                                 │
 │  │  ┌─ claude-code ─────────────────────┐   ┌─ egress-proxy ────┐  │
 │  │  │ uid=dev, caps=∅, rootfs ro        │   │ squid, allowlist  │──┼──> api.anthropic.com
 │  │  │                                   │──>│ deny RFC1918      │  │    claude.ai
 │  │  │ rw: /workspace   (bind, THE risk) │   │ deny !allowlist   │  │    .npmjs.org
 │  │  │ rw: /tmp         (tmpfs, noexec)  │   └───────────────────┘  │    (nothing else)
 │  │  │ rw: ~/.claude    (named volume)   │                          │
 │  │  │ ro: /run/secrets/git-signing      │       X github.com       │
 │  │  └───────────────────────────────────┘       X gitlab.com       │
 │  └──────────────────────────────────────────────X host LAN ────────┘
 └──────────────────────────────────────────────────────────────────────
```

With the `docker` toolchain enabled, two more containers join (not shown
above): a rootless dind daemon on its own isolated network, and a filtering
guard that is the sandbox's only path to it. See
[toolchains.md](toolchains.md) for that topology.

## Verifying the posture

```sh
make doctor
```

runs 19 hardening checks (non-root, empty capability set, read-only rootfs,
no docker socket, egress deny/allow, git blocking, commit-signing
lifecycle, mount surface, ...) plus one function check per enabled
toolchain (checks 20–23). Every property this page claims is asserted by
one of them.
