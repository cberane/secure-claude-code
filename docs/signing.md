# Commit signing & key rotation

Commits made inside the container are signed with a **dedicated,
signing-only, passphrase-less** SSH key (`gpg.format = ssh`). The key
folder is mounted read-only at `/run/secrets/git-signing/`; the container
can sign but can never create, modify or rotate keys. All key lifecycle
happens on the host, under `secrets/git-signing/` (gitignored).

Register the public key at your forge as a **Signing Key** — *not* an
authentication key. The forge then trusts it for exactly one thing:
marking commits verified.

## Rotation policy

Configurable in `.env`:

- **≥ 30 days** (`SIGNING_KEY_WARN_DAYS`) — yellow warning at session
  start and once per session at commit time; work continues.
- **≥ 45 days** (`SIGNING_KEY_MAX_DAYS`) — commits are blocked until you
  run `make rotate-signing-key` on the host. Emergency override:
  `SIGNING_KEY_ENFORCE=false` (don't leave it set).

Key age is always computed from `key.meta` → `created_at`, never from file
mtime (mtime is unreliable across mounts and copies).

## Why old keys stay in `allowed_signers`

If a rotated public key were removed, **every commit it ever signed would
become unverifiable**. Rotation therefore never deletes: the outgoing
key's entry is bounded with `valid-before=<rotation time>`, and the new
key is appended with `valid-after=<rotation time>`:

```
you@example.com valid-after="20260401000000Z",valid-before="20260501120000Z" ssh-ed25519 AAAA... old
you@example.com valid-after="20260501120000Z"                                ssh-ed25519 AAAA... current
```

Git verifies a signature against the **commit timestamp**, so historical
commits keep matching the old key's validity window while new commits must
be signed by the current key. Old private keys are archived under
`secrets/git-signing/archive/`, never deleted. After rotating: register
the new public key at your forge **before** removing the old one, then
`make restart`.

## Signing key exfiltration trade-off

The private key is readable inside the container (file mount). This is
acceptable **only because the egress allowlist provides no channel to send
it anywhere** — and the forge only trusts it for signing, not
authentication. **If you widen `egress/allowlist.txt` toward
general-purpose hosts (pastebins, storage, arbitrary APIs), this reasoning
collapses.** In that case switch to the ssh-agent variant documented in
[DECISIONS.md](../DECISIONS.md), where only signatures — never key
material — enter the container.
