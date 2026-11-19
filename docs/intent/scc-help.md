# Intent: scc CLI discoverability (confirmed 2026-11-18)

- **Outcome:** Bare `scc` shows every command (grouped, shortcuts inline);
  `-h` works at any level (`scc gh -h` → just the gh commands, `scc token -h`
  → usage details instead of minting); a bare group name (`scc gh`) equals
  its `-h`; `scc completion` auto-detects the shell and emits the
  completion script + the exact source-line to stdout.
- **User:** the user at the terminal, recalling a forgotten verb.
- **Why now:** `scc token` and `scc up` exist but were guess-only; the old
  help forced script-reading.
- **Success:** never open `scripts/scc.sh` or docs to remember how to
  invoke something; `scc <anything> -h` always answers.
- **Constraint:** one help table as the single source of truth in
  `scc.sh` (top-level, group, and per-command views all render from it);
  exactly one completion command; completion covers `scc` only; nothing
  writes to rc files; `scc completion` never mutates anything.
- **Out of scope:** completion for `make` or other commands, rc-file
  auto-editing, docs restructuring beyond a short docs/scc.md update.
