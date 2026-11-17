---
name: update-sandbox-skills
description: Refreshes the remote skill-sets available inside the secure sandbox container (~/.claude/skills) by re-fetching each source declared in sandbox/remote-skills.txt. Use when the user asks to update sandbox skills, add another remote skill-set, or when skills look stale inside the container. Own/local skills are never touched.
---

# Update sandbox skill-sets

Remote skill sources for the sandbox are declared in one tracked file,
`sandbox/remote-skills.txt` (one GitHub repo per line, optional `@ref`,
a `# why` comment per line). Currently: `https://github.com/addyosmani/agent-skills`.
Local/own skills live inside the container's `~/.claude/skills` and are
developed by the user — this skill must never modify them.

## Update the sets (standard run)

1. Run, on the HOST:

   ```sh
   make update-sandbox-skills
   ```

   This shallow-clones every declared source fresh (latest available
   version) into the machine-local `skills-remote/` directory, which is
   mounted read-only into the container at `/run/remote-skills`.

2. Report what changed: the sync prints each source, its skill count, and
   the clone path. If a source fails to clone (network/egress/ref), stop
   and surface the exact error — do not retry endlessly.

3. Activation: a **new** session links them via its entrypoint
   (`scc claude` / `make claude`). A running session only re-links on
   restart — tell the user to restart the session to see updated skills.

## Add a new remote source (extensible)

4. Edit `sandbox/remote-skills.txt`, add a line
   `https://github.com/<owner>/<repo>   # why: <reason>`, then run step 1.
   Verify the whole-checkout mount keeps repo-relative references working
   (e.g. agent-skills' shared `references/` resolves via
   `/run/remote-skills/<owner>.<repo>/references`).
5. Commit the modified `sandbox/remote-skills.txt` in THIS repo — the list
   is the durable record (Conventional Commits, signed, no trailers).

## Never

- Do not install skills via `npx skills add` or plugin marketplaces — the
  fetch is deliberately a git shallow-clone into the read-only mount.
- Do not copy remote skills into `~/.claude/skills` in the project repo or
  anywhere in the container writable tree.
- Do not remove or overwrite locally developed skills; the entrypoint
  links only paths that are absent or already managed symlinks.
