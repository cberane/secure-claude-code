# Decisions & Assumptions

All trade-offs and assumptions made while building this setup, in lieu of
asking questions (auto mode).

## Base image & toolchain

- **`node:22-bookworm-slim` (digest-pinned) instead of `debian:bookworm-slim`
  for the main image.** Claude Code needs Node LTS anyway; the official node
  image ships a maintained Node 22 + npm on the same Debian base. The egress
  proxy uses `debian:bookworm-slim` (digest-pinned) since it needs no Node.
- **apt packages are not individually version-pinned.** The base image digest
  pins the package universe at build time reproducibly enough for this use
  case; pinning every deb version would break on every point release without
  a security gain (packages come signed from Debian's repos). External
  downloads (Claude Code npm package, composer.phar) ARE version-pinned, and
  composer is checksum-verified. No `curl | bash` anywhere.
- **Multi-stage:** Claude Code is npm-installed in a builder stage and copied
  into the runtime image, keeping npm cache/layers out of the final image.
  `dev-php` is an optional final stage (`BUILD_TARGET=dev-php`) so the
  default image stays slim.
- **The base image's `node` user (uid 1000) is removed** and replaced by
  `dev` with build-arg UID/GID, so `/workspace` files are host-owned.

## Runtime

- **tini as PID 1 via image ENTRYPOINT** instead of compose `init: true`:
  identical behavior under Docker and Podman, no double-init.
- **`GIT_CONFIG_GLOBAL=/tmp/.gitconfig` (tmpfs).** The rootfs and `$HOME` are
  read-only, so the entrypoint writes the global git config to tmpfs on every
  start. Deliberate side effect: the config is always freshly enforced and
  cannot drift.
- **`CLAUDE_CONFIG_DIR=/home/dev/.claude`** keeps *all* Claude Code state
  (including `.claude.json` and OAuth tokens) inside the single named volume;
  nothing else under `$HOME` needs to be writable. `DISABLE_AUTOUPDATER=1`
  because the npm prefix is read-only at runtime — updates happen by bumping
  `CLAUDE_CODE_VERSION` and rebuilding.
- **`sandbox/CLAUDE.md` is baked into the image and copied into the config
  volume on every start.** The agent works in arbitrary mounted projects;
  placing the rules in `CLAUDE_CONFIG_DIR` makes them global for every
  project without polluting the mounted repo. The repo-root `CLAUDE.md` is a
  separate file for the host-side development environment — the two must not
  be merged, or host sessions inherit sandbox restrictions.
- **`/tmp` is `noexec`.** Known friction: native npm module builds that
  execute from `$TMPDIR` may fail; workaround is building inside
  `/workspace`. Accepted for the hardening win.
- **Resource limits** default to 4g/2cpu/512pids/4096 nofile — adjustable in
  `.env`; they bound runaway processes, not normal builds.

## Egress

- **Squid over tinyproxy.** Squid supports file-based `dstdomain` ACLs
  (clean, extendable `allowlist.txt`), destination-IP ACLs (RFC1918 deny =
  LAN protection at the proxy even for allowlisted-domain DNS tricks),
  CONNECT port restrictions, and useful denial logging. Tinyproxy's filter
  is regex-per-line and weaker on IP-literal handling. Squid's footprint
  cost is acceptable.
- **Proxy container is hardened like the sandbox** (non-root `proxy` user,
  read-only rootfs, cap_drop ALL, tmpfs only). `pinger_enable off` because
  ICMP needs CAP_NET_RAW, which is dropped.
- **`registry.npmjs.org` is not listed separately** — squid 5 treats a
  domain plus its parent wildcard (`.npmjs.org`) as a fatal config error;
  the wildcard covers it.
- **statsig/sentry telemetry domains are allowlisted** so Claude Code doesn't
  log connection errors; they can be removed freely (documented in the file).
- **The squid access log is duplicated onto a shared volume** (`egress-logs`,
  tmpfs-backed, 16m cap) mounted read-only into the sandbox so the
  `blocked-domains` helper can report proxy-denied domains. Exposure is nil:
  the sandbox is the proxy's only client, so it sees exclusively its own
  traffic. The proxy entrypoint truncates the log world-readable on every
  start (uid-mapping-proof under podman keep-id), and the tmpfs volume
  evaporates when the stack stops. Accepted risk: squid exits fatally if the
  log becomes unwritable (a full 16m tmpfs needs ~100k denial lines);
  `make restart` recovers.
- **`allowlist.txt` is local, `allowlist.template.txt` is tracked.** The
  live allowlist diverges per machine/developer; make copies the template
  once (file target, never overwritten afterwards) so local additions don't
  create git noise. Same pattern as `.env` / `.env.example`.
- **Local compose override via `docker-compose.override.yml`** (gitignored,
  tracked example file): the native compose idiom for per-machine tweaks.
  Docker auto-loads the name; the podman path appends it to its explicit
  `-f` list (auto-loading is disabled once `-f` is used). Risk accepted:
  overrides can weaken hardening — mitigated by the README's "run
  `make doctor` after override changes" rule, not by tooling.
- **DNS-rebinding note:** the RFC1918 `dst` deny in squid protects the LAN
  even if an allowlisted domain resolves to a private address.

## Git containment

- **Wrapper at `/usr/local/bin/git`** (PATH-shadowing). Anything invoking
  `/usr/bin/git` by absolute path bypasses it — accepted, because the egress
  proxy (no git hosts allowlisted, plus `credential.helper=` empty) is the
  second, independent line of defense. The wrapper's job is a clear,
  actionable stop signal for the agent, not cryptographic containment.
- **Blocked beyond the spec:** `ls-remote`, `remote update`, `remote prune`,
  `submodule add` — all network operations of the same class.
- **Hooks via global `core.hooksPath=/opt/git-hooks`** so mounted project
  repos stay unpolluted. Trade-off: project-local hooks are not executed
  inside the container (they still run on the host).

## Signing

- **SSH signing over GPG** (mandated, and the right call): no keyring, no
  agent, one file, `allowed_signers` gives explicit validity windows.
- **Principal in `allowed_signers`** is `GIT_AUTHOR_EMAIL` from `.env`
  (fallback `$USER@hostname`). Git matches the signing key, not the
  principal string, for "Good signature" — the principal mainly aids
  auditing.
- **Initial key entry carries no validity window**; windows are added at
  rotation time with **second precision** (`YYYYMMDDHHMMSSZ`), so commits
  made on rotation day still verify correctly (a date-only boundary would
  invalidate same-day commits before the cutover).
- **`key.meta` is mode 0644** — it contains no secret (fingerprint,
  timestamps) and must be updatable host-side for `registered_at`.
- **Deviation from "exists → stay silent":** if the key exists but
  `registered_at` is still null, `ensure-signing-key.sh` re-shows the public
  key and re-prompts (interactive runs only, skippable with Enter).
  Otherwise a skipped confirmation could never be completed.
- **Verification of rotated keys relies on git passing the commit timestamp
  as `verify-time`** to `ssh-keygen -Y verify` (git ≥ 2.38; bookworm ships
  2.39). Doctor check 18 proves it end-to-end.

### ssh-agent variant (documented, not implemented)

Alternative to the read-only file mount: a **dedicated** second agent on the
host — `ssh-agent -a $XDG_RUNTIME_DIR/cc-sign-agent.sock`, only the signing
key loaded with `ssh-add -t 8h` — with the socket mounted into the
container. Advantage: key material never enters the container namespace,
only signatures cross the socket. Disadvantage: host-side session state that
must be re-established after every reboot, plus another moving part in the
Makefile. **Assessment:** under the current egress allowlist a *read* key
has no exfiltration channel, so the simpler file mount wins. This trade-off
**inverts** the moment the allowlist is widened to arbitrary hosts — warning
placed in `README.md` and `egress/allowlist.txt`.

## Scope

- **No `.devcontainer/`** — allowed as optional by the brief, omitted:
  Makefile + compose already cover the workflow, and a devcontainer would
  duplicate the security-relevant runtime flags in a second place that could
  silently drift.
- **`make doctor` requires a configured `.env`** (needs `PROJECTS_DIR`); it
  exits with instructions otherwise.
- **Doctor's check 15 runs against a temp directory** so the production
  `secrets/git-signing/` and the real `key.meta` are never touched by tests
  (same for the age fixtures, which are generated at runtime relative to
  "now" so they can't go stale).
