# Rules for Claude Code inside this sandbox

You are running inside a hardened container. These rules are enforced by
tooling (git wrapper, hooks, egress proxy) — do not try to work around them.

## Git: commits are local, remotes are host-only

- You MAY: `git add`, `commit`, `status`, `log`, `diff`, `branch`, `merge`,
  local `rebase`, `stash`, `tag`.
- You MUST NOT: `push`, `pull`, `fetch`, `clone`, `remote add`,
  `remote set-url`, `submodule update --remote`, `request-pull`. These are
  blocked by a git wrapper and the egress proxy.
- When a push/pull/fetch is needed: **STOP**. Print the exact command the
  user must run on the host, e.g.

  ```
  ┌─ HOST ACTION REQUIRED ────────────────────────────────
  │ Run this on the HOST, then confirm here:
  │
  │   cd <project> && git push origin feature/xyz
  │
  └───────────────────────────────────────────────────────
  ```

  Then **wait for the user to confirm** before continuing. Do not guess the
  result, do not retry inside the container, do not look for workarounds.

## Commit messages

- NEVER add `Co-Authored-By:` trailers.
- NEVER add "Generated with Claude Code", tool attribution, advertising
  footers, or emojis (including 🤖).
- Use Conventional Commits: `type(scope): subject` with types
  feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert.
- Subject line: imperative mood, at most 72 characters.
- Commits are signed automatically (SSH signing key, preconfigured). Never
  change `user.signingkey`, `gpg.*` or `core.hooksPath` settings.

## Dependencies: use original packages, never rewrite them

- ALWAYS prefer loading code from the real registries (npm, packagist,
  PyPI, release archives) over hand-writing it. When a package is requested or
  needed, install the original via the package manager — never re-create
  a library, or parts of one, from model memory.
- If a package download is blocked by the egress proxy, that is NOT a
  reason to fall back to writing your own version: run `blocked-domains`,
  print the HOST ACTION REQUIRED box, and wait for the user (see below).

## Environment constraints (informational)

- Network egress is restricted to an allowlist (Anthropic API, npm).
  Unreachable hosts are blocked by policy, not broken. If a request fails
  with a proxy 403 or "CONNECT tunnel failed": do NOT debug or retry.
  Run `blocked-domains` (pass additional needed domains as arguments) —
  it lists every domain the proxy denied since its last restart. Print its
  HOST ACTION REQUIRED box verbatim, then **STOP and wait for the user to
  confirm** the allowlist change and proxy restart — the same protocol as
  git remote operations.
- Only `/workspace`, `/tmp` and `~/.claude` are writable.
- When docker is available (`docker` CLI + dind sidecar): image pulls are
  restricted to an allowlist. If a pull fails with a 403/Forbidden, do NOT
  retry or work around it — print a HOST ACTION REQUIRED box asking the
  user to add the image to `dind/images-allowlist.txt` on the host and run
  `make restart`, then **STOP and wait for confirmation**.
- To let the user open a dev server in their host browser: bind it to
  `0.0.0.0:8080` (in this container, or published on 8080 inside dind,
  e.g. Sail with `APP_PORT=8080`) — the host may reach it at
  `http://localhost:8080` if the ingress override is enabled. Containers
  nested inside dind have no DNS; they reach the egress proxy by the IP
  the docker client injects automatically — do not debug nested DNS.
- If the pre-commit hook reports the signing key as too old, stop and ask
  the user to run `make rotate-signing-key` on the host.
