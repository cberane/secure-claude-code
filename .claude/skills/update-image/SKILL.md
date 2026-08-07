---
name: update-image
description: Update all pinned program/image versions in Dockerfile and egress/Dockerfile (base-image digests, Claude Code, Composer), rebuild, verify end-to-end with doctor, and roll back automatically on any failure.
---

# Update pinned image and tool versions

Refresh every version pin in `Dockerfile` and `egress/Dockerfile`, prove the
sandbox still works end-to-end, and keep the changes only if everything is
green. Run all commands on the HOST (this repo's root), never inside the
sandbox.

## What is pinned where

| Pin | File | Location |
|---|---|---|
| `node:24-bookworm-slim@sha256:…` | `Dockerfile` | `ARG NODE_IMAGE=` |
| `@anthropic-ai/claude-code` version | `Dockerfile` | `ARG CLAUDE_CODE_VERSION=` |
| Composer version + sha256 | `Dockerfile` | `ARG COMPOSER_VERSION=` / `ARG COMPOSER_SHA256=` |
| `debian:trixie-slim@sha256:…` | `egress/Dockerfile` | `FROM` line |

## Step 1 — Preconditions

- `git status --porcelain -- Dockerfile egress/Dockerfile` must be empty.
  If not, STOP and tell the user — rollback relies on `git restore`.
- `.env` must exist (doctor needs `PROJECTS_DIR`).

## Step 2 — Discover latest versions WITH hashes

```sh
# Base image digests (index digest — works regardless of ENGINE, needs docker;
# fallback: skopeo inspect --format '{{.Digest}}' docker://docker.io/library/<image>):
docker buildx imagetools inspect node:24-bookworm-slim   | awk '/^Digest:/{print $2}'
docker buildx imagetools inspect debian:trixie-slim      | awk '/^Digest:/{print $2}'

# Claude Code (npm dist-tag latest):
npm view @anthropic-ai/claude-code version

# Composer: latest stable + official checksum:
V=$(curl -fsS https://getcomposer.org/versions | jq -r '.stable[0].version')
curl -fsS "https://getcomposer.org/download/${V}/composer.phar.sha256sum" | cut -d' ' -f1
```

Rules:
- Stay on the same base-image *tags* (`24-bookworm-slim`, `trixie-slim`) —
  only refresh digests. A major/tag bump (Node 26, next Debian release) is a
  human decision: never apply it unasked in this skill, but DO detect and
  report it (see below).
- Staleness detection for the egress base: compare the digest of
  `debian:stable-slim` with the digest of `debian:trixie-slim`. If they
  differ, Debian stable has moved past trixie — tell the user a newer
  Debian release is available for `egress/Dockerfile` and offer to bump the
  tag as a separate, explicitly confirmed change (new tag + its digest, then
  the same build/verify/rollback cycle). Same idea for Node: check whether
  `node:lts-bookworm-slim` still matches major 24 (`docker run --rm
  node:lts-bookworm-slim node --version` or the npm dist metadata).
- Never write a Composer version without its matching checksum from the
  `.sha256sum` URL. If the checksum fetch fails, keep the old Composer pin.
- Compare against the current pins (grep the two files). If nothing changed,
  report "everything up to date" and STOP here.

## Step 3 — Prepare rollback

Tag the currently working images before touching anything (ignore errors if
an image doesn't exist yet):

```sh
docker tag claude-sandbox-claude-code:latest  claude-sandbox-claude-code:rollback  || true
docker tag claude-sandbox-egress-proxy:latest claude-sandbox-egress-proxy:rollback || true
```

(With `ENGINE=podman` in `.env`, use `podman tag` on the same names.)

## Step 4 — Apply the new pins

Edit only the version/digest strings listed in the table above. Touch
nothing else in either file.

## Step 5 — Build

```sh
make build
```

If the user's `.env` sets `BUILD_TARGET=dev-php`, this already covers the
composer stage; otherwise additionally verify the optional stage builds:
`docker build --target dev-php .` (respect `ENGINE`).

## Step 6 — End-to-end verification

Both must succeed:

```sh
make doctor    # all 18 checks green, exit code 0
```

```sh
$(ENGINE from .env) compose run --rm -T claude-code claude --version
# must print exactly the new CLAUDE_CODE_VERSION
```

## Step 7a — Success: keep

1. Remove the rollback tags (`docker rmi claude-sandbox-claude-code:rollback
   claude-sandbox-egress-proxy:rollback`).
2. Commit (signed, conventional, no attribution):
   `build: bump pinned image and tool versions`
   with a body listing each pin old → new.
3. Report the version table to the user. Do NOT push.

## Step 7b — Any failure: roll back

On failure of ANY step after 4 (build error, red doctor check, wrong
`claude --version`):

1. `git restore Dockerfile egress/Dockerfile`
2. Restore images:
   `docker tag claude-sandbox-claude-code:rollback claude-sandbox-claude-code:latest`
   (same for `egress-proxy`), then `make build` to be safe.
3. Re-run `make doctor` and confirm it is green again — the sandbox must be
   left in its previous working state.
4. Report: which pin caused the failure, the exact error output, and that
   everything was rolled back. Suggest retrying with the failing component
   excluded (e.g. keep old Claude Code, update only digests) if the user
   wants a partial update.

Never leave the repo with new pins and a red doctor.
