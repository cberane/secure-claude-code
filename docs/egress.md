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
Never add git remote hosts — pushing is a host-only operation by design,
and their absence from the allowlist is the second line of defense behind
the git wrapper.

## How the allowlist is built

Two layers, combined at proxy build time:

1. **Base list** — `egress/allowlist.txt`, your machine-local file
   (gitignored), created once from `egress/allowlist.template.txt`. Edit
   it freely; entries every user needs go into the tracked template
   instead.
2. **Toolchain fragments** — when `TOOLCHAINS` in `.env` names a toolchain,
   its registry domains (`egress/allowlist.d/<toolchain>.txt`) are merged
   in automatically. Dropping a toolchain removes its domains again on the
   next build. You never hand-edit these for the built-in toolchains.

Apply a change to the base list with **`make reload-egress`** — it rebuilds
and recreates only the proxy, so a running session and any nested
containers survive. (`make restart` would tear down the whole stack,
including the dind sidecar and every nested container.)

## When a request is blocked

A denied request fails with a proxy **403** (for HTTPS: "CONNECT tunnel
failed, response 403"). This is policy, not breakage — do not retry or
work around it. From inside the sandbox, `blocked-domains` lists every
domain denied since the last proxy restart in a `HOST ACTION REQUIRED`
box; from the host, `make denied` prints the same report. Then:

1. Review the list. Add **only** the domains the task genuinely needs to
   `egress/allowlist.txt`.
2. `make reload-egress`.
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
- **The denial log resets on proxy restart.** `make reload-egress` (and
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
make learn        # egress OPEN (logged); LAN + git hosts still denied
make claude       # start a FRESH session — it runs WITHOUT the signing key
# ... run the research task ...
make learned      # distilled report: hits per domain, wildcard candidates,
                  # paste-ready allowlist block on stdout
# curate, append the domains you actually need to egress/allowlist.txt
make learn-off    # allowlist enforced again; proxy rebaked
# rerun the task under enforcement — blocked-domains catches any straggler
make doctor       # confirm the posture is green again
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
make build
make learn
```

`make learn` **enforces this as a checkpoint**: if any toolchain is active
it prints the exposure and refuses to continue until you type `yes`
(automation can set `LEARN_ACK=yes`). It is a deliberate speed bump, not a
lock — but the recommendation is to disable the toolchains, not to click
through.

### What learning mode keeps, and what it gives up

Keeps (the invariants never bend):

- **LAN deny** — private/link-local ranges stay unreachable.
- **Git-host deny** — `egress/git-hosts-deny.txt` keeps the push/pull
  hosts blocked; GitHub read endpoints are open like everything else.
- **No signing key** — it is removed from sessions entirely (commits are
  unsigned), because the readable key is only defensible while egress
  offers no way out. The entrypoint refuses to start a learning session
  that somehow still has the key. Sessions started *before* `make learn`
  keep their key — close them.
- **`make doctor` stays red** while the mode is active, by design: an open
  egress must never produce a passing doctor.

Gives up (accepted, bounded exposure while active):

- The session's Anthropic token and the workspace contents can leave
  through the open proxy. So: pair learning mode with the minimal
  environment, never point it at a secret-bearing project, and keep it
  short — enter, capture, distill, leave. It is a capture instrument, not
  a place to live.

### The `make learned` report

`learned-domains` reads the *successful* traffic (the counterpart of
`blocked-domains`, which reads denials) and produces:

- domains sorted by hit count, with the already-covered allowlist
  subtracted;
- wildcard candidates, suggested only when ≥3 sibling subdomains of one
  parent appeared;
- a paste-ready `domain # N hits` block on stdout to curate into
  `egress/allowlist.txt`.

After pasting and `make learn-off`, **rerun the task under enforcement** —
that proves the curated list is complete, and any straggler surfaces
through the normal `blocked-domains` box.
