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
