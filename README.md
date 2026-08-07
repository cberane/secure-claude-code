# Hardened Claude Code Sandbox

Run Claude Code in YOLO mode (`--dangerously-skip-permissions`) inside a
container where the **maximum possible damage is the loss of the mounted
project directory** — nothing beyond that. Projects live in git and are
pushed from the host, so even that damage is recoverable.

## Threat model

| Threat | Mitigation |
|---|---|
| Credential theft / exfiltration | No SSH keys, cloud tokens or keychains exist in the container; entrypoint aborts if `~/.ssh` contains key material; egress allowlist leaves no exfiltration channel |
| Container escape / privilege escalation | Non-root user, `cap_drop: ALL`, `no-new-privileges`, read-only rootfs, no docker socket, no host network, default seccomp profile |
| Uncontrolled egress | Internal-only network; the sole way out is an allowlist proxy that also denies all private/LAN address ranges |
| Unwanted remote mutations | git wrapper blocks `push/pull/fetch/clone/remote add\|set-url/...`; git hosts are deliberately absent from the egress allowlist (second line of defense) |
| Blast radius beyond the project | Exactly one writable bind mount (`/workspace`); everything else read-only or tmpfs |

**Accepted residual risk:** the agent can destroy files in the mounted
project directory. That is the deal — commit early, push from the host.

## Trust boundaries

```
 HOST ──────────────────────────────────────────────────────────────────
 │  ~/.ssh, cloud creds, browser sessions   <- never cross the boundary
 │  secrets/git-signing/   (created & rotated ONLY here)
 │  git push / pull / fetch                 (ONLY here)
 │
 │  docker/podman compose
 │  ┌─ sandbox network (internal: true — no gateway, no LAN) ─────────┐
 │  │                                                                 │
 │  │  ┌─ claude-code ─────────────────────┐   ┌─ egress-proxy ────┐  │
 │  │  │ uid=dev, caps=∅, rootfs ro        │   │ squid, allowlist  │──┼──> api.anthropic.com
 │  │  │                                   │──>│ deny RFC1918      │  │    claude.ai
 │  │  │ rw: /workspace   (bind, THE risk) │   │ deny !allowlist   │  │    .npmjs.org
 │  │  │ rw: /tmp         (tmpfs, noexec)  │   └───────────────────┘  │    (nothing else)
 │  │  │ rw: ~/.claude    (named volume)   │                          │
 │  │  │ ro: /run/secrets/git-signing      │       X github.com       │
 │  │  └───────────────────────────────────┘       X gitlab.com       │
 │  └──────────────────────────────────────────────X host LAN ────────┘
 └──────────────────────────────────────────────────────────────────────
```

## Setup

```sh
cp .env.example .env      # set PROJECTS_DIR, UID/GID, git identity
make install-hooks        # secret-blocking pre-commit hook for THIS repo
make build
make claude               # or: make yolo  (--dangerously-skip-permissions)
```

On first start, `make` provisions a dedicated **signing-only** SSH key under
`secrets/git-signing/` (host-side, gitignored) and prints the public key.
Register it at your forge as a **Signing Key** — *not* an authentication
key — then confirm the prompt. Authenticate Claude Code either via
`ANTHROPIC_API_KEY` in `.env` or by running `/login` once inside
`make claude` (the OAuth token persists in the `claude-config` volume).

Verify the hardening any time:

```sh
make doctor               # 18 red/green acceptance checks
```

## Daily workflow

| Where | What |
|---|---|
| Container (`make claude` / `make yolo`) | edit, build, test, `git add`, `git commit` (auto-signed) |
| Host | `git push`, `git pull`, `git fetch`, remote management, key rotation |

When the agent needs a push/pull it stops and prints a
`HOST ACTION REQUIRED` block with the exact command. Run it on the host,
then tell the agent to continue. The same block appears if you try a
network git command yourself in the container shell.

## Commit signing & key rotation

Commits made inside the container are signed with a **dedicated, signing-only,
passphrase-less** SSH key (`gpg.format = ssh`). The key folder is mounted
read-only at `/run/secrets/git-signing/`; the container can sign but can
never create, modify or rotate keys.

Rotation policy (configurable in `.env`):

- **≥ 30 days** (`SIGNING_KEY_WARN_DAYS`) — yellow warning at session start
  and once per session at commit time; work continues.
- **≥ 45 days** (`SIGNING_KEY_MAX_DAYS`) — commits are blocked until you run
  `make rotate-signing-key` on the host. Emergency override:
  `SIGNING_KEY_ENFORCE=false` (don't leave it set).

Key age is always computed from `key.meta` → `created_at`, never from file
mtime (mtime is unreliable across mounts and copies).

### Why old keys stay in `allowed_signers`

If a rotated public key were removed, **every commit it ever signed would
become unverifiable**. Rotation therefore never deletes: the outgoing key's
entry is bounded with `valid-before=<rotation time>`, and the new key is
appended with `valid-after=<rotation time>`:

```
you@example.com valid-after="20260401000000Z",valid-before="20260501120000Z" ssh-ed25519 AAAA... old
you@example.com valid-after="20260501120000Z"                                ssh-ed25519 AAAA... current
```

Git verifies a signature against the **commit timestamp**, so historical
commits keep matching the old key's validity window while new commits must
be signed by the current key. Old private keys are archived under
`secrets/git-signing/archive/`, never deleted. After rotating: register the
new public key at your forge **before** removing the old one, then
`make restart`.

### Signing key exfiltration trade-off

The private key is readable inside the container (file mount). This is
acceptable **only because the egress allowlist provides no channel to send
it anywhere** — and the forge only trusts it for signing, not
authentication. **If you widen `egress/allowlist.txt` toward
general-purpose hosts (pastebins, storage, arbitrary APIs), this reasoning
collapses.** In that case switch to the ssh-agent variant documented in
`DECISIONS.md`, where only signatures — never key material — enter the
container.

## Podman (rootless)

```sh
make ENGINE=podman build
PODMAN_USERNS=keep-id make ENGINE=podman claude
```

Differences from Docker:

- **User namespace:** rootless podman maps container UIDs into your subuid
  range. Use `PODMAN_USERNS=keep-id` (and set `UID`/`GID` in `.env` to your
  real IDs, `id -u` / `id -g`) so `/workspace` files stay owned by you.
- **SELinux hosts** (Fedora & friends): add `:Z` to the bind-mount suffixes
  in `docker-compose.yml` (`.../workspace:rw,Z` and `...:ro,Z`), or mounts
  will be denied by SELinux.
- Named volumes and `internal:` networks behave the same.

## Rollback / recovery

- **Agent wrecked the project:** on the host, `git status` / `git restore` /
  `git reset --hard origin/<branch>` in `$PROJECTS_DIR`. That is the whole
  accepted blast radius.
- **Broken sandbox state:** `make clean` (removes containers + local
  images), then `make build`.
- **Logged-out / corrupt Claude state:** `make distclean` also removes the
  `claude-config` volume (you'll need to `/login` again).
- **Key trouble:** keys live only under `secrets/git-signing/` on the host.
  Archived keys are in `secrets/git-signing/archive/<fingerprint>/`.

## Optional extras

- **PHP toolchain:** set `BUILD_TARGET=dev-php` in `.env` and `make build`
  (adds `php-cli` + pinned, checksum-verified composer). Uncomment the
  packagist entries in `egress/allowlist.txt`.
- **Custom seccomp:** `security/seccomp.json` documents the syscalls that
  matter; read its `_comment` before enabling — the runtime default profile
  is the better choice unless you have a concrete reason.
