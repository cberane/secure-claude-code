# Decisions & Assumptions

ADR-style log of the trade-offs behind this setup: what was chosen, what
was rejected, and which risks are accepted with what compensating
controls. If a change to the repo invalidates an entry here, the entry is
updated in the same PR.

## Base image & toolchain

- **`node:24-trixie-slim` (digest-pinned) instead of `debian:trixie-slim`
  for the main image.** Claude Code needs Node LTS anyway; the official node
  image ships a maintained Node 24 + npm on the same Debian base. Trixie
  (not bookworm) because Debian 13 ships PHP 8.4 natively — a newer PHP
  without third-party apt repos. The egress proxy uses `debian:trixie-slim`
  (digest-pinned) since it needs no Node.
- **apt packages are not individually version-pinned.** The base image digest
  pins the package universe at build time reproducibly enough for this use
  case; pinning every deb version would break on every point release without
  a security gain (packages come signed from Debian's repos). External
  downloads (Claude Code npm package, composer.phar) ARE version-pinned, and
  composer is checksum-verified. No `curl | bash` anywhere.
- **Multi-stage:** Claude Code is npm-installed in a builder stage and copied
  into the runtime image, keeping npm cache/layers out of the final image.
  Optional language toolchains are a conditional install in the runtime
  stage driven by the `TOOLCHAINS` build arg (comma list, `php,python`) —
  a list, not extra stages, because combinations must compose and stages
  cannot; the default image stays slim with the list empty.
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
  `make reload-egress` recovers.
- **`allowlist.txt` is local, `allowlist.template.txt` is tracked.** The
  live allowlist diverges per machine/developer; make copies the template
  once (file target, never overwritten afterwards) so local additions don't
  create git noise. Same pattern as `.env` / `.env.example`.
- **Toolchain domains are appended at proxy build time, not hand-edited.**
  `TOOLCHAINS` is passed to both image builds; the egress build merges one
  tracked fragment per enabled toolchain (`egress/allowlist.d/<name>.txt`)
  with the local base list (deduplicated; unknown names fail the build).
  Editing the list in `.env` therefore enables AND disables toolchain
  domains on the next build — no stale registry access lingers after a
  toolchain is dropped. Doctor checks 20-23 are keyed on the same variable
  and assert each enabled toolchain + its registry actually work.
- **Docker-in-docker is a rootless sidecar, never the host socket.**
  Mounting `/var/run/docker.sock` is root-equivalent on the host and would
  void the entire sandbox (check 5 asserts its absence). The `docker`
  toolchain instead starts a digest-pinned `docker:dind-rootless` sidecar
  behind a compose profile: `privileged` is unavoidable even rootless, but
  the daemon runs in a user namespace, so the agent controlling its API is
  root only inside that userns — a host escape additionally requires a
  kernel/userns vulnerability. The sidecar sits on the internal network
  only; registry traffic exits via the egress proxy, and the sandbox
  client config injects the proxy into nested `docker build` runs so apt/
  composer/npm inside builds obey the allowlist too. API is plaintext TCP
  on the internal network (no TLS) — acceptable: same trust domain as the
  claude-code container itself. Off by default; dropping `docker` from
  `TOOLCHAINS` removes CLI, sidecar, and registry domains together.
- **The dind API is only reachable through a filtering guard.** The
  daemon lives on an isolated internal network (`dind-net`: daemon,
  guard, egress proxy — never claude-code), so the sandbox has no route
  to the raw API; bypass is topological, not policy. `dind-guard`
  (digest-pinned haproxy, hardened) bridges the networks under the
  sandbox-side alias `dind`: :2376 is the filtered API (image pull
  allowlist `dind/images-allowlist.txt`, local-from-template like the
  egress list, plus a hard deny on `docker load`/import sideloading) and
  common dev ports are TCP-forwarded 1:1 so published services stay
  reachable at `dind:<port>`. Network isolation instead of a shared
  network namespace because the rootless dind entrypoint force-adds its
  own tcp listener — a loopback-only daemon bind is not achievable
  without forking the entrypoint. Known gap, accepted and documented:
  buildkit pulls base images daemon-internally, so `docker build` FROM
  images bypass the pull filter — the egress allowlist still bounds
  which registries are reachable at all. Doctor check 23 proves deny +
  no-bypass end-to-end.
- **Local compose override via `docker-compose.override.yml`** (gitignored,
  tracked example file): the native compose idiom for per-machine tweaks.
  Docker auto-loads the name; the podman path appends it to its explicit
  `-f` list (auto-loading is disabled once `-f` is used). Risk accepted:
  overrides can weaken hardening — mitigated by the "run `make doctor`
  after override changes" rule (docs/setup.md), not by tooling.
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

- **SSH signing over GPG:** no keyring, no agent, one file, and
  `allowed_signers` gives explicit validity windows.
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
  as `verify-time`** to `ssh-keygen -Y verify` (git ≥ 2.38; trixie ships
  2.47). Doctor check 18 proves it end-to-end.

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
placed in `docs/signing.md` and `egress/allowlist.txt`.

## Scope

- **No `.devcontainer/`** — deliberately omitted: Makefile + compose
  already cover the workflow, and a devcontainer would duplicate the
  security-relevant runtime flags in a second place that could silently
  drift.
- **`make doctor` requires a configured `.env`** (needs `PROJECTS_DIR`); it
  exits with instructions otherwise.
- **Doctor's check 15 runs against a temp directory** so the production
  `secrets/git-signing/` and the real `key.meta` are never touched by tests
  (same for the age fixtures, which are generated at runtime relative to
  "now" so they can't go stale).
