# Egress: the allowlist proxy and learning mode

The sandbox has no direct route to the internet. Its only network is
`internal: true` — no gateway, no LAN — and the single way out is the
**egress proxy** (squid), which permits exactly the domains on an
allowlist and denies everything else, including all private/LAN address
ranges. This is what makes YOLO mode safe: even a fully compromised agent
has nowhere to send what it finds.

If you read only one thing: **keep the allowlist narrow.** Every domain you
add is a potential exfiltration channel, and the security argument for the
readable signing key depends on there being none (see the
[exfiltration trade-off](signing.md#signing-key-exfiltration-trade-off)).
Git remote hosts stay out except for the deliberate per-workspace GitHub
scope ([docs/github.md](github.md)) — their absence from the allowlist is
the second line of defense behind the git wrapper.

## How the allowlist is built

Three layers plus the git scope, combined at proxy build time:

1. **Base list** — `egress/allowlist.txt`, your machine-local file
   (gitignored), created once from `egress/allowlist.template.txt`. Edit
   it freely; entries every user needs go into the tracked template
   instead.
2. **Workspace fragment** — `workspaces/<name>.allowlist.txt`, written by
   the switcher into `egress/allowlist.workspace.txt`.
3. **Per-project file** — `<project>/egress/allowlist.txt` (visible in the
   sandbox as `/workspace/egress/allowlist.txt`), merged by
   `scripts/merge-project-allowlist.sh` into `egress/allowlist.project.txt`
   on every make. The committed copy travels with the repo — document each
   domain with a `# why` comment; that file is the durable record.
4. **Toolchain fragments** — when `TOOLCHAINS` in `.env` names a toolchain,
   its registry domains (`egress/allowlist.d/<toolchain>.txt`) are merged
   in automatically. Dropping a toolchain removes its domains again on the
   next build. You never hand-edit these for the built-in toolchains.

Git hosts are NOT part of any of these: the only git-host source is the
generated `egress/allowlist.git-scope.txt` (docs/github.md), consulted by a
dedicated squid ACL that runs before the allowlist.

Apply a change to the base list with **`scc egress reload`** — it reruns
the project merge (unconditionally — a stale copy can't survive a
container rebuild), rebuilds and recreates only the proxy, so a running
session and any nested containers survive. (`scc restart` would tear down
the whole stack, including the dind sidecar and every nested container.)

## When a request is blocked

A denied request fails with a proxy **403** (for HTTPS: "CONNECT tunnel
failed, response 403"). This is policy, not breakage — do not retry or
work around it. From inside the sandbox, `blocked-domains` lists every
domain denied since the last proxy restart in a `HOST ACTION REQUIRED`
box; from the host, `scc denied` prints the same report. Then:

1. Review the list. Add **only** the domains the task genuinely needs to
   `egress/allowlist.txt`.
2. `scc egress reload`.
3. Continue — the agent retries and the request now succeeds.

## Common pitfalls

- **Browser-side vs server-side fetches.** A domain only needs
  allowlisting if the *sandbox* contacts it. A `<link href="https://…">`
  a page loads in **your host browser** never passes through the proxy —
  allowlisting it changes nothing. Font CDNs, analytics and asset hosts
  are usually browser-side; only add them if a build step or test fetches
  them server-side.
- **Single-hit domains are often noise.** A domain contacted once is
  frequently a redirect, a CDN edge, or a health ping you don't actually
  depend on. Try omitting it and see if anything breaks before adding it.
- **Wildcards widen more than they look.** `.example.com` matches
  `example.com` and every subdomain. Prefer exact hostnames; use a
  `.parent.tld` wildcard only when you've seen several sibling subdomains
  from one organization.
- **The denial log resets on proxy restart.** `scc egress reload` (and
  entering/leaving learning mode) truncates it, so `blocked-domains`
  reports only what was denied *since* the last restart. Capture the list
  before reloading if you need it.
- **Never git hosts.** `github.com`, `gitlab.com`, etc. stay off the list
  even when a task seems to want them. GitHub *read* endpoints
  (`api.github.com`, `codeload.github.com`, `raw.githubusercontent.com`)
  are the supported way to pull code and are already enabled by the `php`
  toolchain / addable when needed.

## Learning mode: capturing an allowlist for a research task

For a broad research task, discovering domains one 403 at a time is slow —
dozens of unknown hosts, a round trip each. **Learning mode** inverts the
loop: run one open pass that logs every contacted domain, then distill the
minimal allowlist from what was actually used, then lock back down.

```sh
scc egress learn     # egress OPEN (logged); LAN + git hosts still denied
scc claude           # start a FRESH session — it runs WITHOUT the signing key
# ... run the research task ...
scc egress learned   # distilled report: hits per domain, wildcard candidates,
                     # paste-ready allowlist block on stdout
# curate, append the domains you actually need to egress/allowlist.txt
scc egress learn-off # allowlist enforced again; proxy rebaked
# rerun the task under enforcement — blocked-domains catches any straggler
scc doctor           # confirm the posture is green again
```

### Turn the toolchains OFF first

**Strong recommendation: run learning mode in the minimal environment —
no `php`, `python` or `docker`.** Open egress plus a toolchain is the
sharpest edge in this project:

- With the allowlist, composer/pip/npm can only reach their registries.
  In learning mode they can reach *anywhere*, so a malicious or
  typosquatted dependency the agent installs gains both arbitrary code
  execution and an open channel to exfiltrate — the exact combination the
  sandbox otherwise prevents.
- The `docker` toolchain also means a privileged dind sidecar is running
  throughout.

So before a learning session, on the host:

```sh
# in .env:
TOOLCHAINS=
scc build
scc egress learn
```

`scc egress learn` **enforces this as a checkpoint**: if any toolchain is active
it prints the exposure and refuses to continue until you type `yes`
(automation can set `LEARN_ACK=yes`). It is a deliberate speed bump, not a
lock — but the recommendation is to disable the toolchains, not to click
through.

### What learning mode keeps, and what it gives up

Keeps (the invariants never bend):

- **LAN deny** — private/link-local ranges stay unreachable.
- **Git-host deny** — `egress/git-hosts-deny.txt` keeps the push/pull
  hosts blocked; GitHub read endpoints are open like everything else.
  Workspaces carrying a GITHUB scope normally cannot enter learning mode
  (refused at switch and at the learn gate), and the token mount is
  stripped by the `!override` volume list regardless (docs/github.md).
  The learn gate can do this fix itself on a terminal: answer yes to the
  offer and it writes a marked, empty `GITHUB_*` override into the
  machine-local `workspaces/<name>.env` — the merge chain's last word —
  and re-applies; the committed `.secure-container/workspace.env` is
  never touched. `scc egress learn-off` offers the restore on the way
  out; the manual spellings are `scc egress scope-off` / `scc egress
  scope-on` (automation: `SCOPE_ACK=yes`).
- **No signing key** — it is removed from sessions entirely (commits are
  unsigned), because the readable key is only defensible while egress
  offers no way out. The entrypoint refuses to start a learning session
  that somehow still has the key. Sessions started *before* `scc egress
  learn` keep their key — close them.
- **`scc doctor` stays red** while the mode is active, by design: an open
  egress must never produce a passing doctor.

Gives up (accepted, bounded exposure while active):

- The session's Anthropic token and the workspace contents can leave
  through the open proxy. So: pair learning mode with the minimal
  environment, never point it at a secret-bearing project, and keep it
  short — enter, capture, distill, leave. It is a capture instrument, not
  a place to live.

### The `scc egress learned` report

`learned-domains` reads the *successful* traffic (the counterpart of
`blocked-domains`, which reads denials) and produces:

- domains sorted by hit count, with the already-covered allowlist
  subtracted;
- wildcard candidates, suggested only when ≥3 sibling subdomains of one
  parent appeared;
- a paste-ready `domain # N hits` block on stdout to curate into
  `egress/allowlist.txt`.

After pasting and `scc egress learn-off`, **rerun the task under enforcement** —
that proves the curated list is complete, and any straggler surfaces
through the normal `blocked-domains` box.
