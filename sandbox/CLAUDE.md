# Rules for Claude Code inside this sandbox

You are running inside a hardened container. These rules are enforced by
tooling (git wrapper, hooks, egress proxy) — do not try to work around them.

## Git: commits are local; remotes are scope-gated

- You MAY: `git add`, `commit`, `status`, `log`, `diff`, `branch`, `merge`,
  local `rebase`, `stash`, `tag`.
- Without a GITHUB scope (no `GITHUB_APP_ID` in the environment) remotes are
  host-only: you MUST NOT `push`, `pull`, `fetch`, `clone`, `remote add`,
  `remote set-url`, `submodule update --remote`, `request-pull`. The git
  wrapper blocks them and the egress proxy denies the hosts.
- WITH a GITHUB scope and its mounted token (the helper does the auth
  automatically): you MAY `push`, `pull`, `fetch`, `ls-remote` over HTTPS to
  the repos named in `$GITHUB_REPO` — for PRs, CI pushes, issue work etc.
  Use the `gh` CLI (token is picked up automatically; `gh pr`, `gh issue`,
  `gh run` all work for the scoped repo(s)). SSH transport is never usable.
- A token lives 1 hour; the host refreshes it via `scc renew`. If a push
  fails for auth, print a HOST ACTION REQUIRED box (below) asking the user
  to run `scc renew` (long session) or `scc token` — then STOP and
  wait. Do not retry in a loop.
- Any other remote target (other repos, hosts, forks) stays blocked: print
  the git wrapper's HOST ACTION REQUIRED box and wait.

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

- Network egress is restricted to an allowlist. Unreachable hosts are
  blocked by policy, not broken. If a request fails with a proxy 403 or
  "CONNECT tunnel failed": do NOT debug or retry. Run `blocked-domains`
  (pass additional needed domains as arguments) — it lists every domain the
  proxy denied since its last restart. To request a new domain, print a
  HOST ACTION REQUIRED box containing the EXACT line to append, WITH A
  REASON (one squid domain per line, e.g.
  `api.acme.dev   # why: the app's API this session tests`) and the host
  path of the file (`<PROJECTS_DIR>/egress/allowlist.txt`), asking the
  user to add it and run `scc egress reload` on the host — then **STOP and
  wait** for confirmation, the same protocol as git remote operations.
  Do NOT edit that file yourself: writes to `egress/` and
  `.secure-container/` are denied by the project's Claude settings (both
  hold committed repo truth — the perimeter belongs to the host).
  Never request git remote hosts.
- In LEARNING mode (`EGRESS_MODE=learning`) egress is OPEN to the public
  internet and goes through TRANSPARENTLY: no allowlist protocol, no
  blocked-domains box, no HOST ACTION for network failures. Evidence you
  already have beats the rule: if other public hosts fetched fine in this
  session, egress is open and a failing host is simply DNS-dead or down —
  report "host unreachable" and move on. (A real policy denial logs as
  TCP_DENIED in the proxy log; a DNS failure shows as 503/HIER_NONE.)
  Domains actually used in this mode are collected by the host with
  `scc egress learned` and curated into the allowlist there — that is the
  ONLY place egress decisions get made in learning mode. Only the two
  permanent denies still apply: LAN and git remote hosts.
- Only `/workspace`, `/tmp` and `~/.claude` are writable.
- When docker is available (`docker` CLI + dind sidecar): image pulls are
  restricted to an allowlist. If a pull fails with a 403/Forbidden, do NOT
  retry or work around it — print a HOST ACTION REQUIRED box asking the
  user to add the image to `dind/images-allowlist.txt` on the host and run
  `scc egress reload-images`, then **STOP and wait for confirmation**.

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
  user to run `scc tls cert DOMAIN=myapp.test` (new) or `scc tls renew`
  (expired), then **STOP and wait** — and remind them to reload nginx
  after a renewal, since it keeps the old cert in memory. Test HTTPS from
  inside the sandbox with `curl https://dind:8443` (the dev CA is already
  trusted via SSL_CERT_FILE/CURL_CA_BUNDLE/NODE_EXTRA_CA_CERTS); the
  user's browser uses `https://myapp.test:8443`.
- If the pre-commit hook reports the signing key as too old, stop and ask
  the user to run `scc tls rotate-key` on the host.
