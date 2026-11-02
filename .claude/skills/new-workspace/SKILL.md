---
name: new-workspace
description: Create a named workspace profile (workspaces/<name>.env) for the sandbox — gather project dir, toolchains and egress needs interactively, seed the definition and optional per-workspace allowlist fragment, then offer to activate it with make workspace. Use when the user wants to add, define or set up a workspace/profile for another project, or asks to switch to a project that has no workspace yet.
---

# Create a workspace definition

Automate the definition side of `docs/workspaces.md`. Run everything on
the HOST (this repo's root). The mechanics are fixed — definitions in
`workspaces/`, activation only via `make workspace NAME=<name>`, never a
hand-written `.env` — do not deviate.

## Step 1 — Name

- If the skill was invoked with an argument, that is the name.
- Otherwise derive a suggestion from the project directory (basename,
  lowercased, non-alphanumerics to `-`) and confirm with the user.
- Must be kebab-case (`[a-z0-9-]`); `common` is reserved. If a
  `workspaces/<name>.env` already exists, offer to edit that instead.

## Step 2 — Gather the settings

Ask for / determine, in one round if possible:

- **PROJECTS_DIR** — absolute host path; verify it exists. If the user
  described the project ("my laravel app in ~/projects/x"), resolve and
  confirm rather than ask twice.
- **TOOLCHAINS** — infer a suggestion from the project, then confirm:
  `composer.json` → `php`; `docker-compose.yml` / Sail → add `docker`;
  `pyproject.toml`/`requirements.txt` → `python`. Empty is valid (slim
  runtime) and the right default for research/reading workspaces.
- **EGRESS** — default `allowlist`. Only suggest `learning` when the user
  explicitly wants unrestricted research egress, and spell out what it
  means: open but logged egress, signing key removed from sessions,
  doctor red while active. Recommend pairing it with empty `TOOLCHAINS`
  (the confirm gate in `make learn` exists for good reason).
- **Extra domains** — does the project talk to APIs beyond the toolchain
  registries? Candidates come from the user, from project config
  (`.env.example`, service configs), or from `make denied` output of past
  sessions.

## Step 3 — Write the definition

```sh
make new-workspace NAME=<name>
```

This seeds `workspaces/common.env` on first use and creates
`workspaces/<name>.env` prefilled from the current `.env`. Then edit the
generated file to the gathered values (`PROJECTS_DIR`, `TOOLCHAINS`,
`EGRESS`, any limit overrides). Value format rules are the same as `.env`:
no `#` or `$` inside values.

Extra domains go into `workspaces/<name>.allowlist.txt`, one squid-style
domain per line (leading dot for subdomain wildcards, e.g.
`.api.stripe.com`). Do NOT add them to `egress/allowlist.txt` — that file
is machine-global.

## Step 4 — Offer activation

Show a short summary of the definition, then offer:

```sh
make workspace NAME=<name>
```

Warn beforehand when the switch will be disruptive: a running
`claude-session` dies on restart (the script prompts for this), and a
`TOOLCHAINS` change triggers `make build`. If the user declines, stop —
the definition is complete and can be activated any time.

## Step 5 — Verify (only if activated)

- `scripts/workspace.sh current` should report ".env is in sync".
- For `EGRESS=allowlist` workspaces, suggest `make doctor`.
- For `EGRESS=learning`, remind: distill with `make learned`, leave with
  `make learn-off` (or by switching to a hardened workspace — that runs
  `learn-off` automatically).
