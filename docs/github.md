# GitHub automation — project-scoped, short-lived tokens

Push/pull/PR/merge return to agentic workflows without re-creating a
golden key: each workspace gets a **GitHub App installation token** that
covers exactly that project's repositories and lives **1 hour** — the
lifetime GitHub fixes (not configurable). A leaked credential costs one
repo for one hour, never "everything". Bitwarden and repo-spanning SSH
keys stay out of WSL entirely.

If you read only one thing: **the hard boundary is the mint step.** The
in-sandbox git wrapper is a stop signal, not a fence (`/usr/bin/git` by
absolute path, `git config remote.*.url` rewrites and `-c` aliases bypass
it) — so the minted token itself is always narrowed to the workspace's
repositories and permission set. Never widen the scope on GitHub to
"make it work".

## Model

```
per-project GitHub App ── mint ──> 1h installation token ──> secrets/github-space/token
        (private .pem, host-side)                     │ mounted :ro into the sandbox
                                                      │ read fresh on every git/gh call
.workspaces registry ──> merge chain ──> generated .env (GITHUB_* scope fields)
```

- The App is installed **only on the project's repositories** (bounded by
  installation, the mint can narrow but never widen).
- `repositories` and `permissions` are **always sent** by the mint script —
  an installation-default token (every repo the app can reach) is refused.
- The App private key never leaves WSL, is never committed, never mounted.

## Setup (once per project)

1. Create a GitHub **App** (user → Settings → Developer settings → GitHub
   Apps → New GitHub App), or reuse a per-project one:
   - Repository permissions: **Contents: R/W, Pull requests: R/W,
     Issues: R/W, Administration: R/W** (merge needs Administration).
   - Webhook: deactivate. Anywhere settings fine.
2. Install it **on the project's repositories only**; note the
   installation ID (from the install URL or `GET /user/installations`).
3. Generate a private key (.pem), and put its HOST path into
   `workspaces/secrets.env`:

   ```
   GITHUB_APP_KEY_PATH=/home/cb/.config/gh-apps/myapp.pem
   ```

   (mode 600; unencrypted — GitHub App keys export without passphrases).

4. Register the workspace — the repo carries its own config:

   ```sh
   scc ws add PROJECT=~/projects/<repo>   # WS=<custom-name> optional
   ```

   This seeds `.secure-container/` (README.md, workspace.env with the
   GITHUB_* fields commented, and `<repo>/egress/allowlist.txt`) — review,
   adjust and **commit** it in the project repo. Fill:

   ```
   GITHUB_APP_ID=<numeric app id>
   GITHUB_INSTALLATION_ID=<numeric installation id>
   GITHUB_REPO=org/name            # comma list for more repos
   GITHUB_PERMISSIONS=contents,pull_requests,issues,administration
   ```

5. Activate and mint:

   ```sh
   scc ws switch NAME=<name>
   scc token            # one-shot; pipes into the local `gh` when installed
   scc yolo             # or scc claude / scc shell
   ```

## Daily flow

```sh
scc renew            # keeps the token fresh every ~50 min while the
                     # session runs — the shape for 24-48h agent runs,
                     # daily CI pushes; stops itself when the session ends
scc token            # one-shot human break-glass (also installs into gh)
scc denied           # egress review, as usual
```

Inside the session (scope active): `git push/pull/fetch` to the scoped
repos over HTTPS works (credential helper reads the mounted token);
`gh pr`/`gh issue`/`gh run` work through the same token; PR merge uses the
App identity (merge commits are GitHub-side signed). Nothing else is
allowed: other repos/hosts print the HOST ACTION REQUIRED box; SSH
transport never authenticates; `ssh.github.com` stays proxy-denied in
every mode.

Token expired and no refresher? Pushes fail with the helper's hint — run
`scc renew` / `scc token` on the host.

### origin/HEAD bookkeeping

`git fetch` never creates `refs/remotes/origin/HEAD` — only `git clone`
and `git remote set-head` do. A workspace whose checkout wasn't born from
a fresh clone therefore boots without it, and anything diffing
`origin/HEAD...` (e.g. the /security-review preamble) errors on it. The
container entrypoint closes this once per session, only when a scope and
token are active, only when the ref is MISSING (an existing one — even
deliberately re-pointed — is never touched), with a 15 s budget; a remote
that can't be reached just prints the recovery line
(`git remote set-head origin --auto`) and the session starts normally.

## Egress scope

`scc ws switch` writes `egress/allowlist.git-scope.txt` — exactly
`github.com api.github.com uploads.github.com .githubusercontent.com` —
which `squid.conf` consults BEFORE the allowlist. Without a scope file git
hosts are proxy-denied in every posture (stronger than the old
documentation-only rule: previously the enforcing config had no git-host
deny at all, so a listed git host would have passed silently). Learning
mode refuses scoped workspaces and strips the token mount (`!override`
volume list).

## Scope and secrets inventory

| Artifact | Location | TTL | Where it may never go |
|---|---|---|---|
| App private key (.pem) | host path in `workspaces/secrets.env` | until revoked | container mounts, repos, git |
| Installation token | `secrets/github-space/token` | 1 h | inside the app .pem's directory, git |
| Scope config | `.secure-container/workspace.env` | — | secrets (it is committed) |

## Doctor coverage

- host **29** project-egress merge honored; **30** scope file ↔ `.env` ↔
  no apex git hosts in any source; **31** mint key hygiene (exists, 0600,
  actually a PEM, outside the sandbox repo; token file never contains key
  material).
- container **32** (no scope) git hosts proxy-denied; **33** the token
  reaches the scoped repo via `gh api`; **34** the git credential helper
  serves `github.com`.

## Threat model (accepted residuals)

- A hostile container session can push/PR/merge in the scoped repos while
  a minted token is live (≤1 h). CI-protected branches are the practical
  cap on damage; the scope list is meant to stay small.
- `api.github.com` was already reachable via the php toolchain fragment
  (read endpoints); with a token present, authenticated writes against the
  SCOPED repo(s) become possible (gists excluded by permissions).
- The consenting human gates every mint (`typed yes`, `GITHUB_ACK=yes` for
  automation); `scc renew` keeps minting while a session lives — if the
  host agent runs unattended, it could mint silently, bounded by scope
  and TTL. This is accepted: after the transition, no AI agents run on
  the host at all.
- git delivers credentials only to URLs matching the configured
  `credential.<url>.*` sections — a `push https://evil/x.git` cannot
  receive the github.com token (verified against git's config matching).
