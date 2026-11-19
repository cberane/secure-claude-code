# Skill-sets in the sandbox

~/.claude/skills inside the container mixes two origins:

1. **Local skills** — developed by you, regular directories in the
   persistent config volume. Never touched by automation.
2. **Remote skill-sets** — whole GitHub checkouts, fetched host-side into
   the machine-local `skills-remote/` and mounted read-only at
   `/run/remote-skills/`. The entrypoint links every
   `/run/remote-skills/<source>/skills/<name>` with a `SKILL.md` into
   `~/.claude/skills/<name>` **as a managed symlink** at session start.

The symlink-into-a-checkout shape keeps skills like
`addyosmani/agent-skills` complete: their repo-relative references (the
shared `references/` directory) still resolve, because symlink resolution
walks the physical target — a per-skill copy would lose them.

## Sources: `sandbox/remote-skills.txt`

One GitHub repo per line, optional `@ref`, a `# why` per line. Currently
`https://github.com/addyosmani/agent-skills`. Add a line (with the reason),
commit the file (Conventional Commits, signed), then refresh the skill
sets with the repo's `update-sandbox-skills` target (Makefile layer —
no `scc` command wraps it yet).

Fresh shallow clone per run = latest available version, no incremental
state. New sessions pick the skills up at start; restart a running session
to re-link.

## Conflict policy

`~/.claude/skills/<name>` already present and **not** a symlink (yours) →
the remote one is skipped silently; that name is yours. Managed symlinks
(points to `/run/remote-skills/...`) → re-linked on every session start,
so an update lands the moment a new session starts.

## Removing a source

Delete its line from `remote-skills.txt`, run the update again
(the stale clone is pruned from `skills-remote/`), and restart the
session — the entrypoint no longer re-links those names. Stale symlinks
pointing at a no-longer-linked source simply stop resolving.

## Skill page

The project skill `/update-sandbox-skills` (in `.claude/skills/`) carries
this same procedure for the host agent in this repo.
