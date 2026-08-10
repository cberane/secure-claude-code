# Contributing

Thanks for considering a contribution. This project is small and
security-focused; the bar for merging is correspondingly explicit.

## Ground rules

This repo builds a security boundary. Every change is judged first by its
effect on that boundary, second by everything else. If your change touches
anything security-relevant (mounts, networks, allowlists, capabilities,
the git wrapper, signing), the PR description must say what the change does
to the threat model — even if the answer is "nothing".

Be respectful and assume good faith; disagreements are settled with
reasoning about the threat model, not volume. That is the whole code of
conduct.

## Development setup

You need a Linux (or WSL2) host — the host-side scripts use GNU coreutils
and do not run on macOS. See [docs/setup.md](docs/setup.md) for the full
prerequisite list.

```sh
cp .env.example .env        # set PROJECTS_DIR to any test project
make install-hooks          # REQUIRED for contributors: commit hooks
make build
make doctor                 # must be fully green before AND after your change
```

`make doctor` is the test suite: 19 hardening checks plus one function
check per enabled toolchain. There is no change small enough to skip it —
several checks assert behavior that docs and scripts merely describe.
To test toolchain-dependent behavior, set `TOOLCHAINS=php,python,docker`
in `.env` and rebuild; checks 20–23 activate accordingly.

## What goes where

- Machine-local policy (your egress domains, your dind images) belongs in
  the gitignored local files (`egress/allowlist.txt`,
  `dind/images-allowlist.txt`, `docker-compose.override.yml`) — never in a
  PR. The tracked templates only take entries that every user needs, and
  the egress template's warning applies: every domain is a potential
  exfiltration channel, and git hosts are never added.
- Security/architecture decisions live in [DECISIONS.md](DECISIONS.md).
  If your PR changes a decision, update the entry in the same PR.
- Rules for the agent inside the sandbox belong in `sandbox/CLAUDE.md`;
  rules for developing this repo belong in `CLAUDE.md`. Never merge them.

## Commit messages

Enforced by the commit-msg hook (`make install-hooks`):

- Conventional Commits: `type(scope): subject` with types
  feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert.
- Imperative mood, subject ≤ 72 characters.
- NO `Co-Authored-By:` trailers, NO "Generated with ..." attribution
  lines, NO emojis. The hook rejects trailers outright.

## Pull requests

- One logical change per PR.
- `make doctor` green, output pasted or summarized in the PR.
- Docs updated in the same PR (`docs/`, README, DECISIONS.md as applicable).
- New pinned versions (images, downloads) must be digest- or
  checksum-pinned like the existing ones — no floating tags, no
  `curl | bash`.

## Reporting security issues

Not in the issue tracker — see [SECURITY.md](SECURITY.md).
