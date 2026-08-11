# Local HTTPS (dev CA + project certificates)

Some projects need *valid* HTTPS during development — PWAs, service
workers, secure-context APIs — where a fresh self-signed cert per project
just produces browser warnings. This repo ships a small, deliberately
constrained PKI for that:

- **One local dev CA**, created once on the host (`make certificates`),
  trusted once in your browser.
- **Per-project leaf certificates** (`make cert DOMAIN=myapp.test`),
  valid **3 days** and renewed automatically.

## Security model

The design follows the same containment rules as the commit-signing key:

- **The CA private key never enters the sandbox.** It lives in
  `secrets/dev-ca/` (host-only, gitignored). The sandbox is mounted only
  `secrets/dev-ca/public/ca.crt` (read-only); the entrypoint refuses to
  start if key material ever shows up in that mount, and doctor check 24
  re-verifies it. All minting happens host-side. A compromised session can
  at worst use an existing 3-day leaf for its own `.test` name — it cannot
  create new trust.
- **The CA carries critical X.509 name constraints**: `.test`, `dind`,
  `localhost`, `127.0.0.1`. Browsers enforce these, so even a stolen CA
  key could not sign a working certificate for a real-world domain.
  That is what makes installing this CA into your trust store acceptable —
  and it is the deliberate difference from tools like mkcert, whose CA is
  unconstrained. Doctor check 25 proves the constraint end-to-end
  (a non-`.test` mint is refused).
- **Leaf certificates live in the project** (`<project>/certs/`), i.e. in
  the agent-writable workspace — which is fine, because each leaf is
  scoped to one project's domain and expires after 3 days.
- **Everything runs on port 8443**, never 443 — no privileged port
  anywhere in the chain, which also keeps rootless podman and rootless
  dind happy.

## Setup (once)

```console
$ make certificates
```

creates the CA (idempotent — safe to re-run; it prints the trust steps
again) and shows how to trust it:

- **Windows / WSL2** (browsers run on Windows):
  `certutil.exe -user -addstore Root <path>` — the exact command with the
  translated path is printed.
- **Linux**: copy to `/usr/local/share/ca-certificates/` +
  `update-ca-certificates`.
- **Firefox** ignores the OS store by default: set
  `security.enterprise_roots.enabled = true` in `about:config`, or import
  the cert manually.

Also once per dev domain, on **Windows** (`C:\Windows\System32\drivers\etc\hosts`,
as Administrator) or Linux (`/etc/hosts`):

```
127.0.0.1 myapp.test
```

And enable the 8443 ingress port if you haven't: it is part of the example
override (`docker-compose.override.example.yml`); after adding it to your
override, apply with `make reload-ingress`.

## Per project

> Shortcut: in a Claude Code session in this repo, `/setup-https-in-project
> myapp.test` performs this whole section — cert, nginx service in the
> project's compose file, allowlist/ingress wiring — and prints what
> remains manual.

```console
$ make cert DOMAIN=myapp.test          # writes to $PROJECTS_DIR/certs/
$ make cert DOMAIN=api.test DIR=api    # writes to $PROJECTS_DIR/api/certs/
```

This mints `certs/myapp.test.crt` + `.key` (plus a copy of the public
`ca.crt`) with SANs for `myapp.test`, `*.myapp.test` — any subdomain works
without a re-mint — `dind`, `localhost` and `127.0.0.1`. Only `.test`
domains are accepted; anything else is outside the CA's name constraints
and would be rejected by browsers anyway.

### Renewal (3-day validity)

Three days is deliberate: long enough that a YOLO session started on
Friday still has valid HTTPS on Monday, short enough that a leaked leaf
key ages out over a long weekend. Renewal is automatic — every
`make build`, `make up`, `make shell/claude/yolo` re-mints **all**
dev-CA-issued certs found under `$PROJECTS_DIR` (any `*/certs/*.crt`
whose issuer is the dev CA; foreign certs are left alone). No CA yet =
silent no-op, so nothing changes until you opt in with
`make certificates`. Manually:

```console
$ make renew-certs
```

**A running TLS server keeps the old certificate in memory.** After a
renewal, reload it — e.g. `./vendor/bin/sail restart nginx` or
`docker compose exec nginx nginx -s reload` — or the browser keeps seeing
the expired cert.

## Example: Laravel Sail + nginx (inside dind)

Add an nginx TLS terminator to the project's `docker-compose.yml`
(nested inside dind; add the nginx image to `dind/images-allowlist.txt`
first and run `make reload-images`):

```yaml
    nginx:
        image: 'nginx:1.29-alpine'
        ports:
            - '8443:443'        # rootless dind cannot bind < 1024
        volumes:
            - './certs:/etc/nginx/certs:ro'
            - './docker/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro'
        depends_on:
            - laravel.test
        networks:
            - sail
```

`docker/nginx/default.conf`:

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name myapp.test;

    ssl_certificate     /etc/nginx/certs/myapp.test.crt;
    ssl_certificate_key /etc/nginx/certs/myapp.test.key;

    location / {
        proxy_pass http://laravel.test:80;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

The path from browser to app (8443 end-to-end, every hop unprivileged):

```
browser ── https://myapp.test:8443
   └─> host ingress (127.0.0.1:8443, override)
        └─> dind-guard :8443 (dind/haproxy.cfg)
             └─> dind daemon :8443 (nginx port publish)
                  └─> nginx :443 ── TLS ends here ──> laravel.test:80
```

Because nginx terminates TLS, the nested app containers never need the CA;
set Laravel's `APP_URL=https://myapp.test:8443` and let the
`X-Forwarded-Proto` header do the rest.

## Testing from inside the sandbox

The sandbox cannot resolve `.test` names (internal network, no host DNS),
but every leaf carries a `dind` SAN and the session already trusts the CA
(the entrypoint builds a combined bundle and sets `SSL_CERT_FILE`,
`CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`):

```console
$ curl https://dind:8443/                                  # verifies cleanly
$ curl --connect-to myapp.test:8443:dind:8443 https://myapp.test:8443/
```

The second form keeps SNI/Host correct when nginx routes by server name.
PHP's curl extension reads neither env var — pass the bundle explicitly
when needed: `php -d curl.cainfo="$CURL_CA_BUNDLE" ...`.

## Rotation & removal

- **Rotate the CA**: `rm -r secrets/dev-ca && make certificates`, then
  re-install browser trust and `make renew-certs` (renewal re-issues every
  project cert under the new CA).
- **Remove trust**: delete the CA from the stores it was added to
  (Windows: `certutil.exe -user -delstore Root "<CA common name>"`), and
  `rm -r secrets/dev-ca` — the auto-renew hooks fall back to doing
  nothing.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `NET::ERR_CERT_AUTHORITY_INVALID` | CA not trusted in *this* browser — redo the trust step; for Firefox see the enterprise-roots note. |
| Cert shown as expired | Leaf older than 3 days and nginx still serves the in-memory copy — `make renew-certs`, then reload nginx. |
| `SEC_ERROR_UNKNOWN_ISSUER` only in Firefox | `security.enterprise_roots.enabled` not set. |
| `curl: (60)` inside the sandbox | Session started before `make certificates` — start a fresh session so the entrypoint picks up the CA. |
| Browser can't connect at all | 8443 missing from the override `ports:` (then `make reload-ingress`), or the hosts-file entry is missing. |
