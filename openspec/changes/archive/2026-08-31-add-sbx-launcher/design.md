## Context

See `proposal.md` — Why. The relevant current state:

- `.devcontainer/devcontainer.json` builds the image from `Dockerfile`, mounts `${localWorkspaceFolder}` at `/workspace`, and runs `sudo init-firewall.sh && verify.sh` as `postStartCommand` with `waitFor: postStartCommand`. The firewall and its verification are therefore part of every successful `devcontainer up`.
- Container identity is per project: the devcontainer CLI keys containers off the workspace folder plus the config file, and the two named volumes are keyed on `${devcontainerId}`.
- `sbx-up` currently passes `--remove-existing-container`, which is why it always rebuilds. `devcontainer up` without that flag already reuses an existing container, starts it if stopped, and re-runs `postStartCommand`.
- The repo is cloned to a fixed location (`~/tools/sandbox` in the README) and everything so far is documented as shell functions, not shipped executables.

Constraint that shapes everything below: the sandbox's whole value is that Claude Code cannot run outside it or against a stale firewall. Speed is secondary to that.

## Goals / Non-Goals

**Goals:**

- One command, no arguments, from any project directory.
- Reuse is the fast path; rebuild happens only when the sandbox configuration actually changed.
- Correct-by-construction failure behavior: no path through the script reaches `claude` without a verified container.
- No dependency beyond what the repo already requires (bash, coreutils, `devcontainer`, `docker`).

**Non-Goals:**

- Managing container lifecycle beyond starting it — `sbx` never stops or prunes containers.
- Multiplexing sessions, attaching to a running Claude Code session, or any TUI of its own.
- Changing anything about the sandbox itself: image, firewall, whitelist, verification, and `devcontainer.json` are untouched by this change.
- Rebuilding on changes outside `.devcontainer/` (e.g. a new Claude Code release upstream). `--rebuild` covers that case manually.

## Decisions

### A shipped executable, not a shell function

`bin/sbx` is checked in and made executable; the README tells the user to add `~/tools/sandbox/bin` to `PATH`. Logic lives in the repo, so `git pull` updates it.

The script resolves its own real path (`readlink -f "$0"`, falling back to a `cd`/`pwd -P` loop on systems without GNU coreutils) and derives `<repo>/.devcontainer/devcontainer.json` from it. `SBX_CONFIG` overrides this for anyone with a non-standard layout.

*Alternative rejected:* keeping a `sbx()` function in the README. Staleness detection is more logic than belongs in a snippet users paste once and never re-paste.

### Staleness = content fingerprint of `.devcontainer/`, recorded per project

After a successful `devcontainer up`, the script writes a fingerprint of the sandbox configuration to `${XDG_STATE_HOME:-$HOME/.local/state}/sbx/<slug>.fingerprint`, where `<slug>` is derived from the absolute project path (hashed, so it is filesystem-safe and collision-free).

The fingerprint is a SHA-256 over the sorted list of `(relative path, mode, content hash)` for every file under `.devcontainer/`. Sorting makes it stable; including the path and mode catches renames, additions, deletions, and a script losing its executable bit. Content hashing rather than mtimes means a `git pull` or fresh clone that leaves the config identical does not force a rebuild.

On each run: recompute, compare to the recorded value. Missing or different ⇒ rebuild.

*Alternatives rejected:*
- **mtime vs. container creation time.** No state file needed, but every `git pull` of this repo rewrites mtimes and would force a spurious rebuild of every project.
- **Stamping the fingerprint into a Docker label via `runArgs`.** Self-referential: the label lives in `devcontainer.json`, which is itself part of what is being hashed, and it would require rewriting a tracked file on every run.
- **Comparing against the image's build history.** Only covers the `Dockerfile`, missing `allowed-domains.txt` and the scripts, which are `COPY`ed but also the parts most likely to be edited.

### "Rebuild if needed" is expressed as one flag on one command

There is no separate "does a container exist?" query. The decision reduces to whether `--remove-existing-container` is passed to `devcontainer up`:

```
rebuild = --rebuild given  OR  recorded fingerprint missing  OR  fingerprint differs
```

`--remove-existing-container` against a project with no container is a harmless no-op, so the missing-fingerprint case (first run after adopting `sbx`, or state cleared) costs at most one rebuild and never requires the script to reason about Docker's inventory. That keeps `docker` needed only as a liveness precondition, not as a data source, and avoids depending on the CLI's container-labelling scheme.

When rebuilding, the script says so and why (`sandbox config changed since this container was built - rebuilding`) *before* the slow part starts.

### `devcontainer up` runs on every invocation, including the fast path

Even when nothing changed, `sbx` runs `devcontainer up` rather than going straight to `exec`. Because `waitFor` is `postStartCommand`, this re-runs `init-firewall.sh` and `verify.sh`, so every session begins with the egress firewall freshly installed and asserted — including sessions attaching to a container someone started by hand, and sessions where a previously whitelisted domain has since resolved to a different address.

*Alternative rejected:* detecting a running container and skipping straight to `exec`. Saves the verification seconds on the hot path, at the cost of being able to attach to a container whose firewall was never checked. Wrong trade for this repo.

### Prerequisites are checked up front; `claude` is reached only by `exec`

The script checks, in order: `devcontainer` on `PATH`, `docker` on `PATH`, `docker info` succeeding. Each failure prints what is missing and the fix, and exits non-zero.

The final line is `exec devcontainer exec --workspace-folder "$PWD" --config "$SBX_CONFIG" claude --dangerously-skip-permissions "$@"`. Using `exec` hands over the TTY and makes Claude Code's exit status the script's own, with no code after it that could run in a degraded state. `set -euo pipefail` plus this single terminal `exec` is what makes "never falls through to an unsandboxed session" structural rather than a matter of careful branching.

### Argument handling

`sbx [--rebuild] [--help] [-- <claude args>...]`. Everything after `--` is forwarded verbatim; the script's own flags are consumed. An explicit `--` avoids the ambiguity of guessing whether `--resume` was meant for `sbx` or for `claude`, and leaves room to add launcher flags later without breaking pass-through.

### `sbx-up` / `sbx-claude` stay as they are

They remain documented in the README, unchanged and unwrapped. `sbx` is presented as the everyday entry point, with `sbx-up` as the "burn it down" escape hatch and `sbx-claude` as "attach, skip everything else". Leaving them as literal `devcontainer` invocations means the escape hatches keep working even if `sbx` itself is what is broken.

## Risks / Trade-offs

- **A rebuild may orphan the per-container volumes, losing Claude Code's stored credentials and bash history.** The volumes are keyed on `${devcontainerId}`, and the definition of that id determines whether it survives a config change. → Implementation must verify empirically whether `devcontainerId` is stable across a `--remove-existing-container` rebuild after editing `devcontainer.json`. If it is not stable, the README must warn that a config change means re-authenticating Claude Code; the alternative is switching to fixed volume names keyed on the workspace path, which is a change to `devcontainer.json` and out of scope here.
- **Auto-rebuild is an occasional slow surprise** — the user asked for one command, and sometimes that command takes minutes. → Announce the rebuild and its reason before starting, so the wait is explained rather than mysterious.
- **Two `sbx` runs in the same project directory can fight**, the second removing the container the first is using. → Out of scope to solve properly; a simple advisory lock file per project, or at minimum a documented caveat, is the fallback. Distinct projects are unaffected, which is the common case.
- **The fingerprint covers `.devcontainer/` only.** Upstream changes to the Claude Code npm package, or to base image tags, are invisible to it. → `--rebuild` and `sbx-up` remain the documented way to force a refresh; the README should say so plainly.
- **A partial `devcontainer up` failure could leave a container up but unverified.** → The fingerprint is written only after `devcontainer up` exits zero, so a failed run leaves state stale and the next run rebuilds.
- **State directory is per-user and per-machine.** Using the sandbox from a second account or machine re-triggers one rebuild per project. Acceptable.

## Migration Plan

Purely additive: a new file plus README edits. Existing users keep working with `sbx-up`/`sbx-claude` and opt in by adding `bin/` to `PATH`. Rollback is removing that `PATH` entry — no container, image, or volume state needs undoing, and any fingerprint files left behind are inert.
