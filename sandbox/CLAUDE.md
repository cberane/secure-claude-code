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
  `make reload-images`, then **STOP and wait for confirmation**.

### Nested compose builds: the egress proxy is automatic

- Nested `docker build`, `docker compose build`, and compose's auto-builds
  (`up`, `run`, `create`) all get the egress proxy automatically: the
  compose plugin in this image is a wrapper (`/etc/docker-client/
  cli-plugins/docker-compose` exec'ing the real one beside it) that adds
  the lowercase proxy build args compose's legacy path would otherwise
  forward UPPERCASE-only (apt honors lowercase only; see
  docs/toolchains.md, "Nested networking").
- A nested build failing with "Temporary failure resolving <domain>" is
  therefore NOT a blocked domain: do not run `blocked-domains` for it, and
  do not debug nested DNS. If it still happens (e.g. the wrapper did not
  reach a build), prebuild the affected service explicitly (e.g.
  `laravel.test` for Sail) and rerun the project's normal commands:

      docker compose build --build-arg http_proxy=http://172.30.0.3:3128 \
          --build-arg https_proxy=http://172.30.0.3:3128 \
          --build-arg no_proxy=localhost,127.0.0.1,dind <service>

- NEVER write proxy values into project files — Dockerfile, `.env`, and
  in particular NOT `compose.override.yaml`: compose auto-loads that file
  on every machine, so it would also break the project's host/WSL builds
  (unreachable proxy). If you find such a file, point it out and delete it.
- Actual egress blocks (403 / "CONNECT tunnel failed") → the normal
  `blocked-domains` protocol applies.
- To let the user open a dev server in their host browser: bind it to
  `0.0.0.0:8080` (in this container, or published on 8080 inside dind,
  e.g. Sail with `APP_PORT=8080`) — the host may reach it at
  `http://localhost:8080` if the ingress override is enabled. Services
  published inside dind on 8025 (mailpit), 5432 (postgres) and 5173
  (vite) are reachable the same way, so point the user at
  `http://localhost:8025` for mail instead of inspecting mailboxes
  yourself. Containers
  nested inside dind have no DNS; they reach the egress proxy by the IP
  the docker client injects automatically — do not debug nested DNS.
- HTTPS for a project (e.g. nginx terminating TLS inside dind): all
  certificates are minted on the HOST — NEVER create CAs, self-signed
  certificates, or key material yourself. A project's pair lives in
  `<project>/certs/` (`myapp.test.crt`/`.key`, valid 3 days, SANs include
  `dind` and `localhost`; `ca.crt` alongside is the public CA cert). If a
  cert is missing or expired, print a HOST ACTION REQUIRED box asking the
  user to run `make cert DOMAIN=myapp.test` (new) or `make renew-certs`
  (expired), then **STOP and wait** — and remind them to reload nginx
  after a renewal, since it keeps the old cert in memory. Test HTTPS from
  inside the sandbox with `curl https://dind:8443` (the dev CA is already
  trusted via SSL_CERT_FILE/CURL_CA_BUNDLE/NODE_EXTRA_CA_CERTS); the
  user's browser uses `https://myapp.test:8443`.
- If the pre-commit hook reports the signing key as too old, stop and ask
  the user to run `make rotate-signing-key` on the host.
