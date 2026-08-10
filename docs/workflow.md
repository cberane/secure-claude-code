# Daily workflow

## Where what happens

| Where | What |
|---|---|
| Container (`make claude` / `make yolo`) | edit, build, test, `git add`, `git commit` (auto-signed) |
| Host | `git push`, `git pull`, `git fetch`, remote management, key rotation |

## The HOST ACTION REQUIRED protocol

The sandbox cannot reach git remotes and cannot leave the egress
allowlist. Instead of failing cryptically, both cases stop the agent and
print a box telling *you* what to run on the host:

**Git:** when the agent needs a push/pull it stops and prints the exact
command. Run it on the host, then tell the agent to continue. The same
box appears if you try a network git command yourself in the container
shell.

**Blocked egress:** when a request is denied by the proxy (403), the agent
runs `blocked-domains` and prints the same kind of box listing the denied
domains. You review them, add only what's needed to `egress/allowlist.txt`,
and `make reload-egress`. The full model — how the allowlist is built,
common pitfalls, and **learning mode** for research tasks — is in
[egress.md](egress.md).

## Applying policy changes without a restart

`make restart` tears down everything — including the dind sidecar and with
it every nested container (databases, mailpit, ...). For routine policy
edits there are surgical targets:

| After editing | Run | Restarts |
|---|---|---|
| `egress/allowlist.txt` | `make reload-egress` | only the proxy |
| `dind/images-allowlist.txt` | `make reload-images` | only the guard |
| `ingress/haproxy.cfg` / override ports | `make reload-ingress` | only the ingress |

A running session survives all three. Editing the egress allowlist is the
common case — see [egress.md](egress.md).

## Visibility

- `make ps` — sandbox containers, outer **and** nested inside dind.
- `make logs` — follow all sandbox logs.
- `make denied` — egress denials since the last proxy restart.
- `make df` — disk usage of the host engine and the nested dind daemon
  (whose storage is invisible to a plain `docker system df`).

## Parallel sessions

The first interactive session (`make claude|yolo|shell`) claims the
container name `claude-session`, which the host ingress forwards to.
Further parallel sessions start unnamed — they work normally, they are
just not the ingress target.
