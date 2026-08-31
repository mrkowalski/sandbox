## Context

See proposal.md — Why. The constraints that shape this design are all in `.devcontainer/`:

- `devcontainer.json` bind-mounts `${localWorkspaceFolder}` to `/workspace`, mounts two named volumes for `/commandhistory` and `/home/node/.claude`, sets `remoteUser: node` (uid 1000, created by the `node:24-trixie-slim` base image), and passes `runArgs` of `--cap-add=NET_ADMIN --cap-add=NET_RAW --read-only --tmpfs=/tmp`.
- `postStartCommand` runs `init-firewall.sh` then `verify.sh`, with `waitFor: postStartCommand`, so a failing verification fails the launch. That property is what makes parity enforceable rather than aspirational.
- `init-firewall.sh` flushes all iptables rules, then restores only the NAT rules it captured by grepping `iptables-save -t nat` for `127.0.0.11` — Docker's embedded DNS address, hardcoded.
- `verify.sh` already re-execs itself under a narrow passwordless sudo entry to read the iptables ruleset, and distinguishes PASS / WARN / FAIL with a non-zero exit on any FAIL.

Rootless Podman differs in exactly three ways that matter here: the host user is mapped to container uid 0 by default (so `node` would not own the bind mount), SELinux-enforcing hosts deny a container access to an unlabeled bind mount, and there is no `127.0.0.11`.

## Goals / Non-Goals

**Goals:**

- Rootless Podman reaches the same verified end state as Docker, using the same image, the same firewall script, and the same verification script.
- The Docker path is bit-for-bit unchanged. A Docker user should not be able to tell this change happened.
- Divergence between the two engines is confined to the two configuration files and is small enough to eyeball.
- Where rootless Podman can silently produce a *working but wrong* sandbox — a writable-looking workspace that is actually root-owned, an unenforceable firewall — the failure is made loud.

**Non-Goals:**

- Rootful Podman, `podman-compose`, and Docker Compose.
- `podman machine` on macOS or Windows. The uid-mapping story runs through a VM there and is a separate problem; this design targets Linux hosts running Podman natively.
- Auto-detecting the engine, or a wrapper script that picks one. Engine selection stays explicit (see spec: *Explicit engine selection*), and a launcher script was deliberately abandoned in `2026-08-31-add-sbx-launcher`.
- Reducing the duplication between the two configuration files by generating them. Two hand-maintained files are cheaper than a build step at this size.

## Decisions

### A separate `devcontainer.podman.json`, not one shared config

Rootless Podman needs `runArgs` that Docker rejects outright — `--userns=keep-id:uid=1000,gid=1000` is not a Docker flag — and a `workspaceMount` carrying an SELinux relabel option that is meaningless to Docker. A single file cannot express both.

*Alternatives considered.* A single config plus `--docker-path podman`: fails on the first Podman-only flag. An environment variable read by a wrapper that assembles flags: reintroduces the launcher script this repo just decided against, and hides which flags are in play — the opposite of what a sandbox wants. `devcontainer.json` variants via Dev Container Features: a heavier mechanism than a second 25-line JSON file.

*Cost.* Two files that must stay in sync. Mitigated below.

### `--userns=keep-id:uid=1000,gid=1000` for identity mapping

Rootless Podman maps the invoking host user to container uid 0 by default. Under that mapping the bind-mounted workspace appears root-owned to the container, and `node` (uid 1000) cannot write it — which would break Claude Code in a way that looks like a permissions bug rather than a configuration one. `keep-id:uid=1000,gid=1000` maps the host user directly onto the container's `node` user, so the workspace is writable inside and files written by the sandbox come back owned by the launching user on the host, with no `chown` and no root.

*Alternatives considered.* The `:U` mount option, which makes Podman recursively `chown` the source to match the mapping: it mutates the user's actual project directory on the host, and is O(files) on every launch — unacceptable for a tool meant to be run in any repo. Running Claude Code as root inside the container: violates the sandbox's unprivileged-user restriction. Default mapping plus a world-writable workspace: weakens the isolation being sold.

`keep-id` with explicit `uid=`/`gid=` requires Podman ≥ 4.3; that becomes the documented floor.

### Named volumes inherit ownership from the image, so they need no special handling

Podman initializes a new named volume by copying the image content at the mount point, preserving ownership. The Dockerfile already creates `/commandhistory` and `/home/node/.claude` owned by `node`, so under `keep-id` both land writable. This is a decision to *not* add `:U` or an init container — but it is an inference about engine behavior, so the spec requires it to be verified rather than assumed (*Persistent state is writable and survives restarts*).

### `:Z` on the workspace mount, not `:z`

`:Z` applies a private SELinux label; `:z` applies a shared one that any container could then access. One sandbox owns its workspace mount, so private is correct and strictly tighter. On non-SELinux hosts the option is inert, so it costs nothing to carry unconditionally in the Podman config.

### Preserve container-DNS NAT rules by resolver address, not by the literal `127.0.0.11`

`init-firewall.sh` currently captures NAT rules matching `127.0.0.11` before flushing. That address is a Docker implementation detail; on Podman there is no such rule, and the script's existing `|| true` means it flushes DNS away and prints "No Docker DNS rules to restore" — silently, on the engine where it matters.

The replacement reads the nameserver addresses out of `/etc/resolv.conf` and preserves any pre-existing NAT rule referencing one of them. This is strictly more general: it recovers the identical rule set on Docker (whose `resolv.conf` names `127.0.0.11`), does the right thing on Podman regardless of whether aardvark-dns, pasta, or slirp4netns is in play, and correctly does nothing when the engine installed no NAT rules at all. The unconditional `--dport 53 ACCEPT` rules stay as they are, so resolution to an off-loopback resolver keeps working.

*Alternative considered.* Branching on a detected engine name. Rejected: the code would then encode a list of engines and their DNS addresses, and go stale on the next Podman networking change. Reading the resolver the container was actually given has no such coupling.

### Verification learns about the engine, and gains two positive write checks

`verify.sh` gains: engine detection (`/run/.containerenv` and `$container` for Podman, `/.dockerenv` for Docker, `unknown` otherwise), user-namespace reporting from `/proc/self/uid_map`, and two new FAIL-level checks that create-write-delete a temporary file in `/workspace` and in each persistent state location. All three are engine-neutral code that runs identically on Docker.

Write checks are positive assertions, deliberately: every existing check in the file asserts something is *blocked*, and the rootless failure mode is the opposite shape — everything looks fine until a write fails. Engine detection is reported, never branched on for pass/fail; the spec forbids an engine-conditional bar.

### Drift between the two configs is caught by review, not tooling

The two JSON files must agree on everything except `runArgs`, `workspaceMount`, and `name`. A generator or a test is disproportionate at this size, so the Podman config carries a header comment naming the exact keys that must be kept in step with `devcontainer.json`, and the task list includes a diff of the two as an explicit step.

## Risks / Trade-offs

- **`ipset` may be unusable in a rootless container.** `ipset create` needs the host's `ip_set` kernel modules; a container cannot load them, and rootless cannot either. If they are not already loaded on the host, `init-firewall.sh` fails and — because `waitFor: postStartCommand` — the launch fails. → Document `ip_set` (and `ip_set_hash_net`) as a rootless prerequisite alongside subuid/subgid, and confirm `init-firewall.sh`'s existing `set -e` surfaces it as a clear error rather than a partially-installed firewall. A half-installed firewall would be the one genuinely dangerous outcome, so this is the first thing the task list tests.
- **`iptables` inside a rootless network namespace may behave differently than assumed.** The container has `CAP_NET_ADMIN` within its own netns, which should be sufficient, but nft-vs-legacy backend selection and pasta/slirp4netns differences are real. → `verify.sh` already asserts `OUTPUT` policy is `DROP` and that the ipset-matching ACCEPT rule exists; those assertions are what decide whether rootless Podman ships at all.
- **The host-network ACCEPT rule derives from the default route** (`HOST_IP`, widened to a `/24`). Under slirp4netns or pasta the gateway sits in a different range than Docker's bridge. The rule stays correct by construction since it is computed at runtime, but it may admit a different neighbourhood than on Docker. → Note it; the egress-blocked checks in `verify.sh` are what bound the actual exposure.
- **Two configs will drift.** The mitigation above is a convention and a review step, not enforcement. Accepted deliberately: the alternative is machinery larger than the thing it protects.
- **Rootless Podman may simply fail parity.** The spec's *No engine-specific exemption* scenario is what this design is willing to pay: if the firewall cannot be enforced rootless, the outcome is that rootless Podman is documented as unsupported and this change ships only its engine-neutral parts (the DNS fix, the write checks). That is a real possible end state, not a fallback to a weaker sandbox.

## Migration Plan

Additive. No existing file changes behavior for Docker users: `devcontainer.json` is untouched, and the `init-firewall.sh` and `verify.sh` edits are engine-neutral by construction (the DNS change recovers the same rules on Docker; the new checks pass on Docker). Rollback is deleting `devcontainer.podman.json` and reverting the two scripts. No state migration — a user who never launches the Podman config is unaffected.

## Open Questions

- Whether the `ip_set` modules can be assumed present on mainstream Podman hosts (Fedora, RHEL, Debian) or must always be an explicit `modprobe` prerequisite in the README. Answering it changes documentation wording only.
- Whether to name the exact minimum Podman version in the README or state "4.3 or newer" and let the launch failure speak for itself. Cosmetic either way.
