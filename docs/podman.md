# Podman (rootless)

```sh
systemctl --user enable --now podman.socket   # once — compose provider needs it
make ENGINE=podman build
make ENGINE=podman claude
```

`ENGINE` must be given on the make command line; as a plain environment
variable it would lose against the value in `.env` (or set it in `.env`
permanently).

Differences from Docker:

- **User namespace:** rootless podman maps container UIDs into your subuid
  range. With `ENGINE=podman` the Makefile automatically layers
  `compose.podman.yml` (`userns_mode: keep-id`) on top, so `/workspace`
  files stay owned by you and the signing-key mount passes its owner
  check. Set `UID`/`GID` in `.env` to your real IDs (`id -u` / `id -g`).
- **tmpfs options:** the compose file uses `mode=1777` instead of docker's
  `uid=`/`gid=` tmpfs options, which podman rejects.
- **Local override:** podman's explicit `-f` list disables compose
  auto-loading, so the Makefile appends `docker-compose.override.yml` by
  hand when it exists — behavior is the same, just not automatic.
- **SELinux hosts** (Fedora & friends): add `:Z` to the bind-mount
  suffixes in `docker-compose.yml` (`.../workspace:rw,Z` and `...:ro,Z`),
  or mounts will be denied by SELinux.
- Named volumes and `internal:` networks behave the same.

## Not supported: the `docker` toolchain

`TOOLCHAINS=...,docker` requires `ENGINE=docker`; `make preflight` rejects
the combination. The dind sidecar is the rootless dind image, and its
rootlesskit needs to create a *nested* user namespace with a multi-range
uid map — inside a rootless podman container that setuid `newuidmap` call
is denied by the kernel:

```
[rootlesskit:parent] error: failed to setup UID/GID map:
newuidmap: write to uid_map failed: Operation not permitted
```

This is a structural limit of nested rootless user namespaces, not a
configuration issue. A rootful-dind variant under podman's userns would be
a possible future direction (host-side confinement would then come from
podman instead of rootlesskit), but it changes the security reasoning in
DECISIONS.md and is not implemented. The `php` and `python` toolchains and
the core sandbox are unaffected.
