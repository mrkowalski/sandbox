## Why

Commands that authenticate against, or deploy to, a host-side account cannot work inside this sandbox and never will: their credentials live in the host user's home directory, which is not mounted, and their APIs are not on the egress whitelist. `npx wrangler login` is the case that prompted this — it fails in a way that looks like a bug, and running it on the host does not help either, because the credentials it writes stay on the host.

Today Claude Code discovers this by attempting the command, reading an opaque network or auth failure, and then guessing: retrying, hunting for a token, or inventing a workaround. Every one of those paths wastes turns and ends without the one thing the user actually needs — the exact command to run in a terminal outside the sandbox. The sandbox already knows which commands are hopeless; it should say so up front instead of letting the agent find out the hard way.

## What Changes

- **New `.devcontainer/host-only-commands.txt`** — the declared list of commands that must run on the host, one entry per line with the reason and the host-side remedy, installed to `/usr/local/etc/`. It is the sibling of `allowed-domains.txt`: that file is the only place the sandbox is widened, this one is the only place a command is declared unrunnable. Seeded with the account-touching `wrangler` subcommands only; growing it is a one-line edit plus a rebuild.
- **New `.devcontainer/host-only-guard.sh`** — a `PreToolUse` hook installed to `/usr/local/bin/`. It matches the Bash tool's command string against the list and blocks a match before it executes, returning a message that names the command, why it cannot work here, and what to run on the host. A documented environment-variable prefix bypasses the guard for a single invocation, so a wrong pattern never requires a rebuild to escape.
- **A managed Claude Code settings file baked into the image** wires the hook for every session, at a path under the read-only rootfs so nothing in the bind-mounted `/workspace` can disable it. The guard therefore applies to whichever host project is mounted, not just to this repo.
- **A container-global instruction file baked into the image** amends what Claude Code is told in every session: consult the list before proposing shell work, never attempt a listed command, and state plainly and unprompted that the command has to run outside the sandbox — quoting it verbatim — rather than reporting a failure. Because it is container-global it holds during OpenSpec workflows and in any mounted project, not only when this repo is the workspace.
- **`verify.sh` gains a host-only-command section**: the list is present and parseable, the guard is installed and executable, the managed settings actually reference it, the instruction file is in place, and the guard demonstrably blocks a sample listed command while letting an ordinary one through.
- **`README.md` and `CLAUDE.md`** document the list, how to extend it, the bypass, and the fact that a blocked command is the sandbox working as designed.

Not a security boundary, and the proposal does not present it as one. Containment stays with the firewall and the read-only rootfs; a listed command remains blocked at the network layer whether or not the guard runs. This change is about the agent knowing, and saying, what is impossible — replacing a confusing failure with a clear handoff.

## Capabilities

### New Capabilities

- `host-only-commands`: the sandbox's declaration of which commands must run on the host — the list and its format, the enforcement that stops Claude Code attempting one, the required wording and timing of the handoff to the user, the bypass, and the start-time verification that all of it is installed.

### Modified Capabilities

(none — `openspec/specs/` is empty; this repo has no existing specs)

## Impact

- **New files**: `.devcontainer/host-only-commands.txt`, `.devcontainer/host-only-guard.sh`, and the two files baked into the image that carry the managed hook settings and the container-global instructions.
- **Modified**: `.devcontainer/Dockerfile` (install the four new files, set permissions), `.devcontainer/verify.sh` (new assertion section), `README.md`, `CLAUDE.md`.
- **Unchanged**: `init-firewall.sh`, `allowed-domains.txt`, `devcontainer.json` — no new capability is granted to the container, no egress is widened, and `postStartCommand`/`waitFor` keep their current load-bearing shape.
- **Dependencies**: none added. The guard is POSIX shell plus `jq`, already in the image.
- **Behavioral risk**: a guard failure is a FAIL in `verify.sh`, so a broken guard blocks container launch. That is deliberate and consistent with the repo's stance, but it does mean an over-broad pattern is a launch-blocking mistake — hence the bypass and the sample-command check.
- **Verification gap**: whether the instruction file is actually loaded into a session's context cannot be asserted from a shell script. `verify.sh` checks the file is installed where it belongs; confirming Claude Code reads it is a one-time manual check by the user on the host, recorded in the tasks.
