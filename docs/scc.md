# scc — the sandbox CLI

`scc` is the user-facing command line for the sandbox and the per-project
GitHub automation. It is a thin bash dispatcher over the repo's Makefile
targets (the Makefile stays the single source of truth — CI, doctor and the
skills keep using it) plus an **init wizard** that onboards a project.

Discoverability (one command table in `scripts/scc.sh`, all views render
from it):

- bare `scc` lists **every** spelling, grouped — nothing is guess-only
- any command accepts `-h`: `scc gh -h` shows just the gh commands, bare
  `scc gh` equals `scc gh -h`, and `scc token -h` shows usage details
  instead of running
- `scc completion [bash|zsh]` prints a tab-completion script to stdout
  (shell auto-detected from `$SHELL`); it covers the `scc` command only
  and wiring it into your rc is up to you — the command writes nothing

```sh
mkdir -p ~/.local/share/scc
scc completion bash > ~/.local/share/scc/completion.bash
echo 'source ~/.local/share/scc/completion.bash' >> ~/.bashrc
source ~/.bashrc        # make completion available immediately
```

### fast updates: make the wiring self-healing

The completion is generated at emit time, so it can go stale when `scc`
gains commands. Instead of re-running the wiring by hand, **replace** the
static `source ~/.local/share/scc/completion.bash` line in your `.bashrc`
with this snippet — every new shell then regenerates the cache only when
`scripts/scc.sh` is newer than the cached completion, and sources it:

```bash
# scc completion: regenerate when the scc script changed, else reuse cache
_scc_comp="$HOME/.local/share/scc/completion.bash"
_scc_src="$HOME/projects/secure-claude-code/scripts/scc.sh"
if [[ "$_scc_src" -nt "$_scc_comp" ]] && command -v scc >/dev/null; then
    mkdir -p "$(dirname "$_scc_comp")"; scc completion bash > "$_scc_comp" 2>/dev/null
fi
[[ -r "$_scc_comp" ]] && source "$_scc_comp"
unset _scc_comp _scc_src
```

Adjust `_scc_src` if this checkout lives somewhere else. This stays a
user-side convenience: `scc completion` itself never writes anything (see
[docs/intent/scc-help.md](intent/scc-help.md)).

## Installing (and re-installing)

```sh
make install-scc      # launcher ~/.local/bin/scc -> this checkout's scripts/scc.sh
```

Installs a user-local launcher (no root) that `exec`s this checkout's
`scripts/scc.sh` — the checkout's path is resolved **once, at install
time**, and written into the launcher. Re-running `make install-scc` from
another clone cleanly replaces the launcher: last install wins, and `scc`
works from anywhere. If that clone is later moved or deleted, `scc` breaks
until re-installed from a live checkout — re-run it from whichever clone
should own the global command.

## before init: know where a folder stands

```sh
cd ~/projects/<repo>
scc status
```

Read-only feedback for the current folder: whether it is already onboarded or fresh,
whether its workspace is registered and active and the generated `.env`
is in sync, whether the GitHub App is wired and its 1 h token still
valid, whether the sandbox containers are up, and the project's egress
posture. It ends with one "next" line — usually `scc init` for a fresh
folder, `scc ws switch <name>` to apply a changed definition, or
`scc claude` when everything is good to go. No side effects.

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

Two things are deliberately **not** init's business — they happen once
per machine or per user, never per project:

- **Images:** init does not build. Honest sequence on a new machine:
  `scc build` once (a controlled, visible build). Compose would build
  missing images on demand at first `scc claude` anyway, but a surprise
  multi-minute build inside your first session is a poor way to find
  that out.
- **Authentication:** run `/login` in the first session (open the printed
  URL in your host browser) or put `ANTHROPIC_API_KEY` in `.env` — see
  [docs/setup.md](setup.md).

## no split starts: session commands are folder-checked

One container stack mounts **one** project: the active workspace's
`PROJECTS_DIR` — no matter from which folder a session command is typed.
A session "started for" folder B while workspace A is active would
silently run the agent against A. The session starters refuse that
instead of risking it (`scc claude`, `scc yolo`, `scc shell`, and their
`scc run …` forms):

| You are in | Result |
|---|---|
| the sandbox checkout (or under it) | starts — you are managing the sandbox itself |
| the mounted project (or under it, incl. nested repos) | starts — this is what the stack mounts |
| anything else | **refused** (exit 2, no container started), with both paths and the fix |

Example of a refusal — starting from a foreign project while `keep` is
active:

```
scc claude: refusing — you are probably trying to start an agent for a
different project.

  you are in:         /home/cb/projects/my-app
  the sandbox mounts: /home/cb/projects/keep   (active workspace's PROJECTS_DIR)

  scc status …        # see exactly where this folder stands
  scc init …          # not onboarded yet: register + activate + token
  scc ws list         # already onboarded — find its workspace name, then
  scc switch NAME     # activate it (regenerates .env) and run again
```

Global operations are **not** guarded — `scc build`, `scc status`,
`scc doctor`, `scc up`, egress/tls/maintenance act on the stack, not on a
project folder, and are equally valid from anywhere.

## Command groups

| Group | Commands | Notes |
|---|---|---|
| **runs** | `scc claude` / `scc yolo` / `scc shell` / `scc run build\|up\|down\|stop\|restart` | session lifecycle |
| **status** | `scc status [PATH]` (read-only per-folder feedback) | — |
| **GitHub** | `scc token` (1 h mint + host gh), `scc renew` (refresh loop beside a session), `scc gh app`, `scc gh app-rescue KEY=… [APP_ID=…]` | docs/github.md |
| **workspaces** | `scc ws list` / `scc ws switch NAME=x` / `scc switch x`, `scc ws add PROJECT=…`, `scc ws new NAME=…`, `scc ws prune` | docs/workspaces.md |
| **egress** | `scc egress reload` / `scc egress learn` / `learn-off` / `learned` / `denied` / `allowlist` | docs/egress.md |
| **TLS + signing** | `scc tls certs` / `scc tls cert DOMAIN=x.test` / `renew` / `keygen` / `rotate-key` / `hooks` | docs/https.md, docs/signing.md |
| **inspect** | `scc doctor` / `scc ps` / `scc logs` / `scc df` / bare `scc inspect` | — |
| **maintenance** | `scc maintain prune` / `prune-build` / `prune-dind` / `clean` / `clean-dind` / `distclean` | — |
| **meta** | `scc` (full grouped help), `scc version`, `scc completion [bash\|zsh]` | — |

Direct shortcuts exist for the daily verbs (`scc claude`, `scc token`,
`scc denied`, …) and all appear in the bare listing; group-prefixed forms
keep the surface enumerable. Flags map to the plumbing variables you
already know (`DOMAIN=`, `KEY=`, `WS=`, `FORCE=1` — pass them as
environment or after the arguments; lifecycle verbs forward trailing
`VAR=value` arguments to the command line, where they override `.env`).

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
