# Development environment (HOST)

This repo builds and maintains a hardened Claude Code sandbox. Sessions in
this directory run on the **host** (WSL2), not inside the sandbox: Docker,
full network access, and git remotes (`push`, `pull`, `fetch`) are all
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

- `make build` / `make doctor` — rebuild images, run the 19 end-to-end checks.
- `.claude/skills/update-image` — refresh all version pins (digests, Claude
  Code, Composer) with automatic rollback.
- `DECISIONS.md` — records the security/architecture decisions; update it
  when a decision changes.
