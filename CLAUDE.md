# Development environment (HOST)

This repo builds and maintains a hardened Claude Code sandbox. Sessions in
this directory run on the **host**, not inside the sandbox: Docker, full
network access, and git remotes (`push`, `pull`, `fetch`) are all
available and fine to use here.

Do not confuse this file with `sandbox/CLAUDE.md` — that is the hardened
rule set baked into the container image (`/etc/claude/CLAUDE.md`, copied to
the agent's config dir on every start). Its restrictions (git wrapper,
egress allowlist, read-only rootfs, "HOST ACTION REQUIRED" prompts) apply
only *inside* the sandbox, never to this development environment.

## Editing the sandbox rules

- Rules for the agent inside the container belong in `sandbox/CLAUDE.md`.
- After changing it, rebuild (`make build`) and run `make doctor` — several
  doctor checks assert behavior those rules describe (git blocking, commit
  trailer rejection, egress policy).

## Commit messages (this repo)

- Conventional Commits: `type(scope): subject`, imperative, ≤72 chars.
- NEVER add `Co-Authored-By:` trailers, "Generated with Claude Code" lines,
  attribution footers, or emojis. The commit-msg hook rejects trailers.
- Commits are signed automatically; don't change `user.signingkey`, `gpg.*`
  or `core.hooksPath`.

## Useful entry points

- `make build` / `make doctor` — rebuild images, run the end-to-end checks.
- `make certificates` / `make cert DOMAIN=x.test` / `make renew-certs` —
  local dev CA (host-only, name-constrained) and short-lived project HTTPS
  certs (docs/https.md).
- `make reload-egress` / `reload-images` / `reload-ingress` — apply an
  allowlist or ingress change by rebuilding only that one service. Prefer
  these over `make restart`, which drops the dind sidecar and with it every
  nested container (Sail databases, mailpit, ...).
- `make ps` / `make df` / `make denied` — state, disk usage (host *and* the
  nested dind daemon) and the proxy's denied domains, from the host.
- `.claude/skills/update-image` — refresh all version pins (digests, Claude
  Code, Composer) with automatic rollback.
- `.claude/skills/setup-https-in-project` — wire a .test domain, cert and
  nginx TLS terminator into the mounted project (docs/https.md).
- `DECISIONS.md` — records the security/architecture decisions; update it
  when a decision changes.
- User docs live in `docs/` (one file per topic, indexed from README.md);
  keep them in sync with behavior changes. Contribution/security policy:
  `CONTRIBUTING.md`, `SECURITY.md`.
