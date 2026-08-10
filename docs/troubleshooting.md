# Troubleshooting & recovery

## Rollback / recovery

- **Agent wrecked the project:** on the host, `git status` /
  `git restore` / `git reset --hard origin/<branch>` in `$PROJECTS_DIR`.
  That is the whole accepted blast radius.
- **Broken sandbox state:** `make clean` (removes containers + local
  images), then `make build`.
- **Logged-out / corrupt Claude state:** `make distclean` also removes the
  `claude-config` volume (you'll need to `/login` again).
- **Key trouble:** keys live only under `secrets/git-signing/` on the
  host. Archived keys are in `secrets/git-signing/archive/<fingerprint>/`.

## Disk filling up

`make df` shows host usage *and* the nested dind daemon's, which lives
inside the `dind-storage` volume and is invisible to a plain
`docker system df`. Reclaim with:

| Target | Removes |
|---|---|
| `make prune` | dangling images (host) |
| `make prune-build` | host build cache — often the largest item |
| `make prune-dind` | stopped containers + dangling images inside dind |
| `make clean-dind` | the whole nested image store (keeps your Claude login, unlike `distclean`) |

## Common first-run errors

- **`make preflight` fails** — it names the missing piece (engine, compose
  version, jq, `.env`, PROJECTS_DIR). Fix exactly that; every later
  target runs the same checks.
- **"signing_key exists but key.meta is missing"** — an earlier
  provisioning run was interrupted. Delete `secrets/git-signing/` (the key
  was never registered anywhere) and rerun `make keygen`.
- **Entrypoint aborts: "signing_key is owned by uid X, expected Y"** —
  `UID`/`GID` in `.env` don't match your host user. Fix them and
  `make build` again (they are baked in at build time; `make preflight`
  warns about the mismatch before it costs you a rebuild).
- **Compose rejects the files with a schema error** — your compose plugin
  is older than 2.24 (the `env_file: {path:, required:}` long syntax).
  Upgrade the plugin.
- **Check 11 fails / workspace owned by wrong user, PROJECTS_DIR looks
  right** — remove quotes around the value in `.env`; both make and the
  scripts read it literally.
- **`https://…` fails with 403 / "CONNECT tunnel failed" inside the
  sandbox** — not broken, blocked by egress policy. Run `blocked-domains`
  in the container (or `make denied` on the host) and follow
  [egress.md](egress.md).
- **`docker pull` inside the sandbox fails with 403** — the image is not
  in `dind/images-allowlist.txt`. Add it, then `make reload-images`.
- **Native npm module build fails in `/tmp`** — `/tmp` is `noexec` by
  design; build inside `/workspace`.
- **squid exits fatally (egress log full)** — needs ~100k denial lines;
  `make reload-egress` recovers.

## macOS

Not supported as a host. The host-side scripts use GNU coreutils
(`stat -c`, `date -d`) and fail with BSD tool errors on macOS. Linux and
WSL2 are the supported hosts; contributions welcome.
