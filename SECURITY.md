# Security Policy

This project's entire purpose is a security boundary, so reports are taken
seriously and triaged quickly.

## What counts as a vulnerability here

The sandbox promises: an agent running inside with full permissions can, at
worst, destroy the one mounted project directory. A vulnerability is
anything that breaks that promise on a correctly configured setup:

- **Sandbox escape** — writing outside `/workspace`, `/tmp` and
  `~/.claude`; reaching the host filesystem, host network, or LAN.
- **Egress bypass** — network traffic that does not traverse the squid
  allowlist, or reaches a non-allowlisted destination through it.
- **Git containment bypass** — a `push`/`fetch`/`clone` that actually
  reaches a remote from inside the container (note: bypassing only the
  *wrapper* is not enough; see accepted risks below).
- **Signing-key misuse** — using the mounted signing key for anything but
  signing, or exfiltrating it despite the egress allowlist.
- **dind guard bypass** — pulling a non-allowlisted image or reaching the
  raw daemon API from the sandbox (excluding the documented buildkit gap).

## Accepted, documented risks — please don't re-report

These are known trade-offs, documented in [DECISIONS.md](DECISIONS.md) with
their compensating controls:

- `/usr/bin/git` invoked by absolute path bypasses the git *wrapper*. The
  egress allowlist (no git hosts) is the enforcement layer; the wrapper is
  a stop signal for the agent.
- Base images of nested `docker build`s are pulled daemon-internally by
  buildkit and bypass the dind image-pull filter. The egress allowlist
  still bounds which registries are reachable at all.
- `api.github.com` (when the php toolchain enables it for composer dists)
  accepts authenticated writes such as gists — an issue only if a valid
  token is smuggled into the sandbox, which the setup never provides.
- The dind sidecar runs `privileged`, confined to a user namespace; a host
  escape from it additionally requires a kernel/userns vulnerability.
- The agent can destroy the mounted project directory. That is the
  accepted blast radius, not a bug.

A report that widens one of these into something worse (e.g. the buildkit
gap reaching a non-allowlisted registry) IS in scope.

## How to report

Use **GitHub's private vulnerability reporting** on this repository
(Security tab → "Report a vulnerability"). Please include your host OS,
container engine (docker/podman + version), relevant `.env` settings
(TOOLCHAINS, ENGINE — never tokens), and ideally the `make doctor` output.

Please do not open public issues for suspected vulnerabilities.

## Supported versions

Only the latest commit on `main` is supported. There are no backported
fixes.
