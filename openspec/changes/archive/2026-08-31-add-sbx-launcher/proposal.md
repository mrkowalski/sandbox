> **Abandoned 2026-08-31 — not implemented.** This change was archived without
> any implementation (0/21 tasks). The two-command flow (`sbx-up` + `sbx-claude`)
> stays as-is. Artifacts kept for reference only; nothing here reflects the state
> of the repo.

## Why

Starting work on a project in the sandbox currently takes two commands (`sbx-up` then `sbx-claude`), and `sbx-up` always destroys and recreates the container, so the safe habit is also the slow one. Every project needs its own container, so this friction is paid on every project, every day. A single `sbx` command that brings the container up only when it needs to be brought up removes that friction without weakening the sandbox.

## What Changes

- Add `bin/sbx`, an executable launcher checked into this repo. Running `sbx` in a project folder brings that project's sandbox container up if it is not already usable, then opens Claude Code inside it.
- `sbx` detects when the sandbox configuration (anything under `.devcontainer/`) has changed since the project's container was last provisioned, and rebuilds the container automatically before opening Claude Code. A stale container is never silently reused.
- `sbx --rebuild` forces a rebuild regardless of detected staleness.
- Arguments after `--` are passed through to `claude`.
- `sbx` fails with a clear message, and without opening Claude Code, when the `devcontainer` CLI is missing, Docker is unreachable, or the container fails to come up or verify.
- `sbx-up` and `sbx-claude` remain documented and unchanged; they stay available as escape hatches (force-rebuild, and attach-only).
- README gains instructions for putting `bin/` on `PATH` and using `sbx` as the everyday entry point.

## Capabilities

### New Capabilities
- `sandbox-launcher`: the user-facing command that starts and attaches to a project's sandbox container — container reuse, staleness detection and rebuild, argument pass-through, and failure behavior.

### Modified Capabilities

(none — this repo has no existing specs)

## Impact

- New file: `bin/sbx`.
- Modified: `README.md` (installation and usage).
- No change to `.devcontainer/` — the container image, firewall, and verification are untouched, and `sbx` invokes the same `devcontainer` CLI and config that `sbx-up`/`sbx-claude` do.
- New host-side state: a small fingerprint file per project under `${XDG_STATE_HOME:-~/.local/state}/sbx/`, used only to detect configuration drift. Deleting it costs at most one extra rebuild.
- Dependencies unchanged: `@devcontainers/cli`, Docker, and standard POSIX shell tooling already required to use this repo.
