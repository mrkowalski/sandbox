## Context

See `proposal.md` — Why. The constraints that shape the approach, all confirmed by inspection inside a running container:

- `/` is `overlay (ro,...)`. `/home/node/.npm` is on it, so npm's cache writes fail with `EROFS`.
- The existing writable paths are `/workspace` (bind mount, ext4, exec), `/tmp` (`tmpfs rw,nosuid,nodev,noexec`), `/commandhistory` and `/home/node/.claude` (named volumes, ext4, exec).
- **`/tmp` is `noexec`.** Verified directly: a `chmod +x` script under `/tmp` fails to run with exit 126. This rules out the obvious fix. Pointing `npm_config_cache` at `/tmp` gets past `EROFS` and then fails at the next step — `npx` stages the package at `<cache>/_npx/<hash>/node_modules/` and executes `.bin/prettier`, which dies with `sh: 1: prettier: Permission denied`, exit 126. Confirmed by running exactly that.
- With an exec-capable writable cache (probed by pointing `npm_config_cache` into `/workspace`), `npx --yes prettier --check README.md` succeeds and prints `All matched files use Prettier code style!`.
- `/home/node/.npm/_cacache` already holds ~123 MB, populated by the Dockerfile's two `npm install -g` runs.
- `/home/node` itself is read-only, so no `~/.npmrc` can be created at runtime to redirect the cache. `npm config get cache` is therefore determined by the image, not by anything the agent can change mid-session.
- Nothing here is testable from inside the container: `devcontainer.json` and `runArgs` are host-side, and the scripts under `/usr/local/bin/` are baked copies. The probes above establish the *mechanism*; the change itself must be exercised by the user on the host.

## Goals / Non-Goals

**Goals:**

- Pick the cache location by the two properties that actually matter — writable *and* exec — rather than by convenience.
- Keep the change to the smallest possible surface: one mount entry, and the verification that comes with it.
- Turn "no sandbox leakage" from a claim in the proposal into assertions `verify.sh` re-runs at every start, including assertions about the rootfs that do not exist today.

**Non-Goals:**

- Sharing an npm cache between dev containers, or with the host. Per-container scoping is deliberate (see Decisions).
- Making other language ecosystems' caches writable (pip, cargo, go). Same class of problem, but out of scope; this change sets the pattern for them.
- Any offline/air-gapped npm story. `registry.npmjs.org` is already whitelisted and stays that way.

## Decisions

### Named volume at `/home/node/.npm`, not a tmpfs and not a relocated cache

`mounts` gains one line, matching the two entries already there:

```jsonc
"source=claude-code-npm-${devcontainerId},target=/home/node/.npm,type=volume"
```

Chosen because a named volume is the only option that is writable, exec-capable, per-container, and warm on first use.

Alternatives considered:

- **`--tmpfs=/tmp` reuse (`npm_config_cache=/tmp/...`)** — rejected, and this is the important rejection: it *appears* to work (the `EROFS` goes away) but `noexec` breaks `npx` one step later. A fix that only unblocks `npm install` of pure-JS deps while silently breaking every `npx` tool would be worse than the current honest failure.
- **`--tmpfs=/home/node/.npm:exec`** — works, but shadows the 123 MB baked cache with an empty directory, so every container start re-downloads from the registry, and the cache then competes with RAM. Ephemerality is its only advantage, and it is not worth those costs here; npm's cache is content-addressed and integrity-checked, so a stale cache is not a trust problem (see Risks). This was put to the user, who chose the named volume.
- **Cache inside `/workspace`** — rejected outright. It writes the agent's package cache into the user's bind-mounted project, where it would pollute the working tree, land in `git status`, and cross the sandbox boundary onto the host filesystem. That *would* be leakage in the plain sense.
- **Loosening `--read-only`** — rejected. It solves the symptom by discarding the guarantee.

### Keyed on `${devcontainerId}`

Follows the existing bashhistory and config mounts. One dev container's cache is not visible to another, so a package pulled while working on project A cannot be served to project B — cache state stays scoped the same way bash history and Claude Code config already are. The alternative, a single shared `claude-code-npm` volume, would save disk at the cost of a cross-project channel; not worth it.

### No `NPM_CONFIG_CACHE` in `containerEnv` — verify the path instead

`/home/node/.npm` is already npm's default and cannot be redirected at runtime (read-only `$HOME`), so pinning the env var would be redundant today. The failure it would guard against is a future base-image change to npm's default cache path, which would silently reintroduce `EROFS`.

Rather than pin the value, `verify.sh` resolves the cache location with `npm config get cache` and asserts *that* directory is writable and exec-capable. This detects the drift instead of papering over it, and keeps the mount target as the single source of truth. Consistent with the repo's preference for failing loudly over degrading quietly.

### Ownership needs no Dockerfile change

Unlike `/commandhistory` and `/home/node/.claude`, which the Dockerfile creates and `chown`s explicitly, `/home/node/.npm` is created by npm itself during the `USER node` global installs, so it is already `node:node`. Docker seeds a new empty named volume from the image content at the mount point, preserving ownership — so the volume comes up node-owned and pre-populated. No `chown`, no `mkdir`, no Dockerfile edit.

### Verification: new `bad`-level checks, in the unprivileged body

A new `verify.sh` section, placed with the other non-root checks (not in `--iptables-only`, since none of it needs root, and so it avoids the `__VERIFY_COUNTS__` trailer machinery entirely):

1. **Cache is usable** — resolve `npm config get cache`; assert the directory exists, is writable, and that a file created there with the exec bit actually runs. The exec probe is the one that matters, and it is the one a naive implementation would omit.
2. **Rootfs is still read-only** — assert that writes to `/usr/local/bin/`, `/usr/local/etc/allowed-domains.txt`, and the global `node_modules` holding the `claude` binary all fail. These are new assertions; `verify.sh` does not check the read-only rootfs at all today. They are what makes "the writable surface grew by exactly one directory" a checked property rather than a claim, and they guard the paths whose integrity the whole sandbox rests on.

Both at `bad` (FAIL) severity, per `CLAUDE.md`'s rule that a granted capability comes with an assertion, and accepting that a FAIL blocks every container start. `warn` was considered for check 1, on the argument that a broken cache is a convenience regression rather than a security one. Rejected: a silently unmounted volume degrades into exactly the confusing mid-session `EROFS` this change exists to eliminate, and failing at start is the repo's established posture. Check 2 is unambiguously FAIL-worthy — it is a confinement regression.

Every temp file the probes create must be cleaned up, and the checks must not disturb the cache's contents.

## Risks / Trade-offs

- **`npm install` / `npx` can now fetch and execute arbitrary registry code** → Not a new capability in kind: the agent already executes arbitrary commands and can write and run code in `/workspace`. Anything npm executes is confined by the same default-deny firewall, the same read-only rootfs, and the same no-`git push` guarantee — none of which this change touches, and all of which `verify.sh` asserts at every start. This is the intended effect of the change, stated plainly rather than mitigated away.
- **Cached packages persist across sessions** → npm's `_cacache` is content-addressed and keyed by the registry's integrity hash, so a cache entry cannot substitute different content for the same package version; a poisoned entry would have to match the hash npm was going to verify anyway. Accepted as the cost of the warm-cache choice. A user who wants a clean slate removes the volume on the host (`docker volume rm`).
- **The volume grows without bound** → npm never prunes `_cacache` on its own. Mitigation is manual and cheap: `npm cache clean --force`, or delete the volume. Worth a README note; not worth automation.
- **Volume seeding happens only on first creation** → If a `claude-code-npm-*` volume already exists from an earlier run, Docker will not re-seed it from a newer image, so it can drift from the image's baked cache. Harmless — a stale cache costs a re-download at most, and the integrity check above still applies.
- **`verify.sh` edits do not take effect until the image is rebuilt** → The installed `/usr/local/bin/verify.sh` is the copy that runs. Editing the working tree alone leaves the running container on the old script. Already documented in `CLAUDE.md`; the rebuild step below is what makes it real.
- **Nothing here was tested end-to-end** → The mechanism was proven inside the container (the `noexec` failure and the exec-capable success are both reproduced above), but the `devcontainer.json` mount, the volume seeding, and the new `verify.sh` checks are host-side and remain unverified until the user rebuilds.

## Migration Plan

1. Add the mount to `devcontainer.json`, the checks to `verify.sh`, and update `CLAUDE.md`'s writable-paths and architecture sections.
2. On the host, rebuild: `devcontainer up --workspace-folder "$PWD" --config "$SBX" --remove-existing-container`. Because `waitFor` is `postStartCommand`, a failing new check aborts the launch — which is the intended safety property, and also means a mistake in the new checks is loud rather than silent.
3. Confirm `verify.sh` prints `VERIFIED` with the new checks passing, then confirm `npx prettier --check README.md` succeeds.
4. Rollback is removing the mount line and rebuilding; optionally `docker volume rm` the `claude-code-npm-*` volume. Nothing else in the sandbox depends on it.
