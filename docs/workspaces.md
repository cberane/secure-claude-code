# Workspaces — named per-project profiles

Switching between projects used to mean hand-editing `.env` (change
`PROJECTS_DIR`, adjust `TOOLCHAINS`, remember which make targets to run) —
error-prone and easy to leave half-applied. Workspaces make that a single
command:

```sh
make workspace NAME=my-laravel-app
```

A **workspace** is one `.env`-worth of per-project settings stored as
`workspaces/<name>.env`. On switch, `.env` is regenerated from
`workspaces/common.env` + the workspace file, and the delta is applied
with the cheapest sufficient action — nothing, an egress reload, a
restart, or a rebuild.

## Quickstart

```sh
make new-workspace NAME=my-laravel-app   # creates the definition (seeded from your current .env)
$EDITOR workspaces/my-laravel-app.env    # set PROJECTS_DIR, TOOLCHAINS, ...
make workspace NAME=my-laravel-app       # generate .env + build/restart as needed
make claude                              # work
```

```sh
make workspaces                          # list definitions, active one marked
scripts/workspace.sh current             # active workspace + sync status
```

The first `make new-workspace` also creates `workspaces/common.env` with
the settings shared by every workspace (engine, UID/GID, git identity,
API key), seeded from your existing `.env`. Everything under `workspaces/`
is machine-local and gitignored, exactly like `.env` itself.

## Files

| File | Role |
|---|---|
| `workspaces/common.env` | Shared settings, merged first |
| `workspaces/<name>.env` | Per-workspace settings — wins on duplicate keys |
| `workspaces/<name>.allowlist.txt` | Optional: extra egress domains for this workspace only |
| `.workspace` | Name of the active workspace |
| `.env` | **Generated** — header records source workspace + checksum |
| `egress/allowlist.workspace.txt` | Generated copy of the active workspace's allowlist fragment, baked into the proxy |

`.env` stays the single interface the Makefile and compose read — nothing
else in the sandbox changed. But it is now a build product: **edit the
workspace files, not `.env`**. The switch refuses to clobber a hand-edited
`.env` (checksum mismatch) until you fold the edit into the definition —
or override once with `FORCE=1 make workspace NAME=<name>`.

A pre-existing hand-written `.env` is preserved as `.env.pre-workspaces`
on the first switch.

## What a switch does

`scripts/workspace.sh switch` compares old and new configuration and picks
the cheapest apply path:

| Change | Action |
|---|---|
| Nothing effective | none — values apply to new sessions automatically |
| Workspace allowlist fragment | `make reload-egress` (proxy only; sessions keep running) |
| `PROJECTS_DIR` / `DIND_MEM_LIMIT` | `make restart` (only if the sandbox is running) |
| `TOOLCHAINS` | `make build && make restart` |
| `EGRESS` posture | `make learn` / `make learn-off` (see below) |

BuildKit caches image layers per `TOOLCHAINS` value, so switching between
combinations you have built before is a cache-hit retag — seconds, not a
full rebuild.

If a session (`claude-session`) is running and the switch needs a restart,
it asks before killing it — a restart also drops the dind sidecar and every
nested container (databases, mailpit, ...). `WS_ACK=yes` skips the prompt
for automation.

## Research workspaces: `EGRESS=learning`

A workspace may declare its egress posture:

```sh
# workspaces/research.env
PROJECTS_DIR=/home/you/projects/scratch
TOOLCHAINS=
EGRESS=learning
```

`EGRESS=learning` routes through the **existing** learning mode
(`make learn` / `make learn-off`, [docs/egress.md](egress.md)): egress is
open but logged, the signing key is removed from sessions, and doctor goes
red while active. Switching *to* such a workspace enters learning mode
(with its usual confirmation gate when toolchains are enabled); switching
*away* runs `make learn-off` first, so a hardened workspace can never
inherit a leftover open proxy. There is deliberately **no** separate
"open egress" mode — see DECISIONS.md.

Pairing `EGRESS=learning` with empty `TOOLCHAINS` is the intended research
setup: slim image, no package managers, open-but-logged egress.

## Per-workspace egress domains

Projects often need a few extra domains (an API the app talks to, a
tile server, ...). Instead of editing the machine-global
`egress/allowlist.txt`, put them next to the workspace:

```
# workspaces/my-laravel-app.allowlist.txt
.api.stripe.com
.maptiler.com
```

The fragment is baked into the proxy on switch and disappears again when
you switch to a workspace without one. `make denied` shows what got
blocked when curating the list.

## Consistency checking

`make doctor` gains host-side check **26** whenever `.workspace` exists:
the generated `.env` must match its checksum and name the active
workspace, and the `.learning-mode` marker must agree with the declared
`EGRESS` posture. A red 26 almost always means "rerun
`make workspace NAME=<active>`".
