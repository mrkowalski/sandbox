> **Abandoned 2026-08-31 — not implemented.** This change was archived without
> any implementation (0/23 tasks). The sandbox remains Docker-only. Artifacts kept
> for reference only; nothing here reflects the state of the repo.

## Why

The sandbox only runs on Docker today. Everything about the container — a bind-mounted workspace, named volumes, `NET_ADMIN`/`NET_RAW`, a read-only rootfs, an iptables/ipset firewall — assumes Docker's uid semantics and Docker's embedded DNS. Users who run rootless Podman (no daemon, no root, and the default on Fedora/RHEL and increasingly on corporate Linux images) cannot use this repo at all. Supporting rootless Podman removes a hard blocker for those users without changing what the sandbox promises.

## What Changes

- Add a second devcontainer configuration, `.devcontainer/devcontainer.podman.json`, carrying the runArgs rootless Podman needs (user-namespace identity mapping so the in-container `node` user owns the bind-mounted workspace, and SELinux relabeling for the workspace mount). The existing `devcontainer.json` stays the Docker configuration and is unchanged in behavior.
- Both configurations share one `Dockerfile`, one `init-firewall.sh`, one `verify.sh`, and one `allowed-domains.txt`. The engine difference is confined to the two JSON files.
- `init-firewall.sh` stops treating the pre-existing NAT rules it preserves as Docker-specific. It preserves whatever container-DNS NAT rules the engine installed — Docker's `127.0.0.11` rules or Podman's aardvark-dns rules — so name resolution survives the flush on both engines.
- `verify.sh` gains engine-aware assertions: it reports which container engine and user-namespace mode it is running under, and asserts the invariants that rootless Podman can silently break — that `/workspace` is writable by `node`, and that the two named volumes are writable — while every existing check must still pass unchanged.
- README gains a Podman section: the rootless prerequisites, the `--docker-path podman` invocation, and a second pair of shell functions (`sbx-up`/`sbx-claude` equivalents) pointing at the Podman config.
- Rootful Podman (`sudo podman`) is out of scope; it is neither documented nor verified.

## Capabilities

### New Capabilities
- `container-engine`: which container engines the sandbox supports, how one is selected, and the guarantee that the sandbox's security properties are identical on every supported engine — including the rootless-Podman-specific invariants (workspace and volume writability under user-namespace mapping, firewall enforceability inside a rootless network namespace).

### Modified Capabilities

(none — this repo has no existing specs)

## Impact

- New file: `.devcontainer/devcontainer.podman.json`.
- Modified: `.devcontainer/init-firewall.sh` (engine-neutral DNS rule preservation), `.devcontainer/verify.sh` (engine reporting plus writability assertions), `README.md` (Podman prerequisites and usage).
- Unchanged: `.devcontainer/Dockerfile`, `.devcontainer/allowed-domains.txt`, and `.devcontainer/devcontainer.json` — the Docker path must behave exactly as it does today, and the image is engine-agnostic.
- Dependencies: no new runtime dependency for Docker users. Podman users need `podman` (rootless, with `newuidmap`/`newgidmap` and a configured subuid/subgid range) in place of Docker; `@devcontainers/cli` is already required and supports `--docker-path`.
- Risk concentrated in two places: whether `iptables`/`ipset` can install a default-deny ruleset inside a rootless Podman network namespace, and whether the read-only rootfs plus tmpfs combination behaves identically. Both are verified rather than assumed — if either fails, the spec's parity requirement means rootless Podman is declared unsupported rather than shipped with a weaker sandbox.
