# scc — the sandbox CLI

`scc` is the user-facing command line for the sandbox and the per-project
GitHub automation. It is a thin bash dispatcher over the repo's Makefile
targets (the Makefile stays the single source of truth — CI, doctor and the
skills keep using it) plus an **init wizard** that onboards a project.

Install once (user context, no root):

```sh
make install-scc      # symlink ~/.local/bin/scc -> scripts/scc.sh
```

The symlink resolves the repo through the script's own location — it always
runs against this checkout, without configuration.

## The one command that matters

```sh
cd ~/projects/<repo>
scc init
```

walks the full onboarding: host preflight → register the repo-anchored
workspace (`.secure-container/`) → create the per-project GitHub App
(manifest flow, two browser clicks; skipped when already wired) → activate
the workspace → mint a 1 h token → print the "start working" summary.
Non-interactive contexts get told the exact commands instead of prompts.
Re-running on an already-onboarded project is safe (idempotent steps, app
setup skipped when `GITHUB_APP_ID` exists).

## Command groups

| Group | Commands | Notes |
|---|---|---|
| **runs** | `scc claude` / `scc yolo` / `scc shell` / `scc run build\|up\|down\|stop\|restart` | session lifecycle |
| **GitHub** | `scc token` (1 h mint + host gh), `scc renew` (refresh loop beside a session), `scc gh app`, `scc gh app-rescue KEY=… [APP_ID=…]` | docs/github.md |
| **workspaces** | `scc ws list` / `scc ws switch NAME=x` / `scc switch x`, `scc ws add PROJECT=…`, `scc ws new NAME=…` | docs/workspaces.md |
| **egress** | `scc egress reload` / `scc egress learn` / `learn-off` / `learned` / `denied` / `allowlist` | docs/egress.md |
| **TLS + signing** | `scc tls certs` / `scc tls cert DOMAIN=x.test` / `renew` / `keygen` / `rotate-key` / `hooks` | docs/https.md, docs/signing.md |
| **inspect** | `scc doctor` / `scc ps` / `scc logs` / `scc df` / bare `scc inspect` | — |
| **maintenance** | `scc maintain prune` / `prune-dind` / `clean` / `clean-dind` / `distclean` | — |
| **meta** | `scc` (grouped help), `scc version` | — |

Direct shortcuts exist for the daily verbs (`scc claude`, `scc token`,
`scc denied`, …); group-prefixed forms keep the surface enumerable. Flags
map to the make variables you already know (`DOMAIN=`, `KEY=`, `WS=`,
`FORCE=1` — pass them as environment or after the arguments).

## Conventions kept

- The wizard only automates what the individual targets already do — every
  step has a plain `make`/`scripts/` equivalent (docs/workspaces.md,
  docs/github.md).
- Project onboarding stays **repo-anchored**: `scc init` writes the
  committed `.secure-container/` (no secrets — the app key path lives in
  machine-local `workspaces/secrets.env`), so a fresh clone is one
  `scc init` away from a working setup.
- `scc` never runs inside the sandbox; it manages it from the host, in
  user context only.
