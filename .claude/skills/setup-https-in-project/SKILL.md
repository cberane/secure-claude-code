---
name: setup-https-in-project
description: Set up valid local HTTPS for the project referenced by PROJECTS_DIR in .env — mint a .test certificate, add an nginx TLS terminator to the project's docker-compose (Sail-aware), and wire the 8443 chain (dind image allowlist, ingress override), ending with the exact host steps (hosts entry, CA trust) the user still has to do.
---

# Set up HTTPS in the mounted project

Automate the per-project part of `docs/https.md`: certificate, nginx
service, and the 8443 plumbing. Run all commands on the HOST (this repo's
root), never inside the sandbox. The design rules are fixed — host-only
CA, `.test` domains only, port 8443 end-to-end, never 443 — do not deviate
from them even if asked to "simplify".

## Step 1 — Domain

- If the skill was invoked with an argument, that is the domain.
- Otherwise ask the user for one, suggesting `<project-dir-name>.test` as
  the default (derive from the basename of `PROJECTS_DIR`, lowercased,
  non-alphanumerics replaced with `-`).
- The domain MUST end in `.test` (the CA's name constraints permit nothing
  else; `mint-cert.sh` enforces this too). If the user wants another TLD,
  explain the constraint and stop — do not widen the CA.

## Step 2 — Inspect the project

- `PROJECTS_DIR` comes from `.env` (quote-stripped). STOP with a clear
  message if `.env` or the directory is missing.
- Look at `$PROJECTS_DIR/docker-compose.yml`:
  - **Sail project** (services like `laravel.test`, a `sail` network):
    note the app service name — it becomes the `proxy_pass` target and
    `depends_on` entry.
  - **Other compose project**: pick the service that serves HTTP and its
    internal port; confirm the choice with the user if ambiguous.
  - **No compose file**: only Steps 3–4 apply (cert + CA). Tell the user
    nginx-in-dind needs a compose project, and that a session-side HTTPS
    server can use the same cert from `/workspace/certs/` instead.
- If an `nginx` service already exists, reconcile idempotently: update
  cert paths/server_name if the domain changed, otherwise report
  "already set up" and skip to Step 6.

## Step 3 — CA and certificate

```sh
ls secrets/dev-ca/ca.key >/dev/null 2>&1; ca_existed=$?   # remember for Step 6
make certificates    # idempotent; creates CA on first run
make cert DOMAIN=<domain>
```

Certs land in `$PROJECTS_DIR/certs/` (3-day validity, auto-renewed by
make build/up/shell/claude/yolo — no cron needed). Never generate CA or
certs with ad-hoc openssl calls; always go through the make targets.

## Step 4 — nginx config in the project

Write `$PROJECTS_DIR/docker/nginx/default.conf` (create dirs; if the file
exists and differs, show the diff and ask before overwriting):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name <domain>;

    ssl_certificate     /etc/nginx/certs/<domain>.crt;
    ssl_certificate_key /etc/nginx/certs/<domain>.key;

    location / {
        proxy_pass http://<app-service>:80;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

## Step 5 — nginx service in the project's compose file

Add to `$PROJECTS_DIR/docker-compose.yml`, matching the file's existing
indentation and quoting style (Sail uses 4 spaces and single quotes):

```yaml
    nginx:
        image: 'nginx:1.29-alpine'
        ports:
            - '8443:443'
        volumes:
            - './certs:/etc/nginx/certs:ro'
            - './docker/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro'
        depends_on:
            - <app-service>
        networks:
            - <project network, e.g. sail>
```

Port stays `8443:443` — rootless dind cannot bind below 1024, and the
whole ingress chain expects 8443.

## Step 6 — Host plumbing (this repo)

- `dind/images-allowlist.txt` must contain an nginx line; append if
  missing, then apply:

  ```sh
  grep -q 'nginx' dind/images-allowlist.txt \
      || { printf '^(docker\\.io/)?(library/)?nginx$\n' >> dind/images-allowlist.txt; make reload-images; }
  ```

- `docker-compose.override.yml` must publish `- "127.0.0.1:8443:8443"`
  under the ingress `ports:`; add it and run `make reload-ingress` if
  missing. If there is no override/ingress at all, point the user at
  `docker-compose.override.example.yml` — don't invent a new one silently.
- For a Laravel project, set `APP_URL=https://<domain>:8443` in the
  project's `.env` and mention that the proxy sends
  `X-Forwarded-Proto` (Laravel needs its trusted-proxy config to honor
  it, e.g. `->trustProxies(at: '*')` in `bootstrap/app.php`).

## Step 7 — Tell the user what only they can do

Print a HOST ACTION box with exactly what remains manual:

1. **Hosts entry** — Windows (`C:\Windows\System32\drivers\etc\hosts`, as
   Administrator) or Linux `/etc/hosts`: `127.0.0.1 <domain>`.
2. **CA trust** — ONLY if `ca_existed` from Step 3 said the CA was just
   created: repeat the trust-install steps (`make certificates` reprints
   them). If the CA already existed, the browser trust is already done —
   don't nag.
3. **Start the stack** — the nested compose runs from a sandbox session
   (`sail up -d` / `docker compose up -d` inside `make claude|yolo`), not
   from the host.

## Step 8 — Verify (best effort)

If the nested nginx is already running
(`docker exec "$(docker compose ps -q dind-daemon)" docker -H tcp://127.0.0.1:2375 ps`),
prove the full chain from the host:

```sh
curl -sS --cacert secrets/dev-ca/public/ca.crt \
     --resolve <domain>:8443:127.0.0.1 https://<domain>:8443/
```

Report the result honestly; if the stack is not running, say the check is
pending until the user starts it. On cert errors later, the fix is
`make renew-certs` + reloading nginx (it keeps the old cert in memory) —
see the troubleshooting table in `docs/https.md`.
