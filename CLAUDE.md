# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is not an application — it is the definition of a headless Docker dev container that sandboxes Claude Code itself. There is no source tree, no package manifest, no test suite. The deliverable is `.devcontainer/`: an image, a firewall, and a verification script. Everything else (README, `openspec/`) describes or plans that.

The sandbox exists so that `claude --dangerously-skip-permissions` is safe to run: the agent can only see the bind-mounted project folder, can only reach whitelisted hosts, and cannot `git push`. Cost is meant to be the only remaining risk.

## Working from inside the sandbox

If `$DEVCONTAINER=true` (the normal case when Claude Code runs here), you are inside the very container this repo builds:

- `docker`, `podman`, and the `devcontainer` CLI are **not** installed, and the rootfs is read-only outside `/workspace`, `/tmp`, `/commandhistory`, `/home/node/.claude`, and `/home/node/.npm`. You cannot build, run, or rebuild the container.
- `/tmp` is a tmpfs mounted **`noexec`**. It is writable but nothing there can be executed, so it is not a general-purpose staging area for tools — a script written to `/tmp` and `chmod +x`-ed still fails to run with exit 126.
- The scripts under `/usr/local/bin/` are the copies baked into the running image, not the repo's working tree. Editing `.devcontainer/*.sh` changes nothing about the current session; the change takes effect only after a host-side rebuild.
- Egress is default-deny, so most network commands fail by design. A failed fetch is usually the firewall working, not a bug.
- Some commands are blocked outright, before they run, by the guard described below — they authenticate against or act on an account that only exists on the host. That is expected behaviour, not a defect to route around: relay the message you are given to the user, quoting the command they need to run outside the sandbox, and get on with the rest of the task. `/usr/local/etc/host-only-commands.txt` lists them.

Consequence: **you cannot verify your own changes to this repo.** Changes to `.devcontainer/` must be exercised by the user on the host (see below). Say plainly what you were unable to test rather than implying it was checked.

## Host-side commands (for the user, not for you)

```bash
SBX=~/tools/sandbox/.devcontainer/devcontainer.json
devcontainer up   --workspace-folder "$PWD" --config "$SBX" --remove-existing-container   # rebuild + launch
devcontainer exec --workspace-folder "$PWD" --config "$SBX" claude --dangerously-skip-permissions
```

`verify.sh` is the test suite. It runs twice per launch: the image entrypoint runs it in `--iptables-only` mode as a start-time gate, and `postStartCommand` runs it in full afterwards. A manual re-run inside a container is:

```bash
verify.sh                  # full run; prints VERIFIED / NOT VERIFIED, exits 1 on any FAIL
sudo verify.sh --iptables-only   # just the ruleset checks (this is how the full run reads iptables)
```

### The fail-closed contract, and what to do when the container will not start

The sandbox refuses to run unprotected. Three consequences, in the order you are likely to meet them:

- **A failed firewall install stops the container.** The entrypoint exits before `exec`ing the container command, so there is no running container to attach to and `devcontainer exec` has nothing to reach. `docker logs <container>` carries the reason.
- **An aborted `init-firewall.sh` leaves the container sealed, not open.** The documented abort paths — chiefly a whitelist entry that will not resolve — still abort, but they now end with all three chain policies DROP and loopback only. A hand re-run (`sudo /usr/local/bin/init-firewall.sh`) that fails mid-way does the same thing, so a healthy container cannot be knocked back to unrestricted egress by a bad run.
- **The escape hatch is `--entrypoint`, and it is the host operator's alone.** To get a shell in an image whose container will not start:

  ```bash
  docker run --rm -it --entrypoint /bin/bash <image>   # no firewall installed
  ```

  There is deliberately no in-image bypass (no `SANDBOX_SKIP_FIREWALL=1`): that would be a permanent, documented way to start the sandbox unprotected. Docker's own override gives the operator the same power without shipping one, and the agent — which has no container engine — cannot use it.

A container that will not start is therefore the mechanism working. Diagnose the whitelist or the ruleset; do not look for a way to start it anyway.

## Architecture: how the security contract is enforced

The six files that enforce the contract — `devcontainer.json`, `entrypoint.sh`,
`allowed-domains.txt`, `init-firewall.sh`, `verify.sh`, and the host-only
command list plus its guard — and the reasoning behind how each is written are
documented in `.devcontainer/CLAUDE.md`, which loads automatically when working
with files under that directory. Read it before changing anything there: a
change to any of those files is a change to the sandbox's guarantees.

## Change workflow

This repo uses OpenSpec (`openspec` CLI is in the image; the `openspec-*` skills and `/opsx:*` commands drive it). Planning artifacts live in `openspec/changes/<name>/` — `proposal.md`, `design.md`, `specs/<capability>/spec.md`, `tasks.md` — and archived changes move to `openspec/changes/archive/`.

Important: **an archived change is not automatically a description of the repo.** The archive holds both kinds, and only the change's own header tells them apart:

- `add-podman-support` and `add-sbx-launcher` were **abandoned with zero tasks implemented**. Read them as rejected proposals — the sandbox is Docker-only and the launcher is still the two `sbx-up`/`sbx-claude` shell functions in the README.
- `add-host-only-command-guard`, `fix-fail-open-firewall`, and `add-writable-npm-cache` were **implemented and verified on the host**. They describe what the repo now does.

`openspec/specs/` is the reliable place to look instead, and it is no longer empty: `host-only-commands`, `firewall-enforcement`, and `npm-cache` are synced from the three implemented changes and state the behaviour the sandbox actually guarantees. A capability only lands there once its change is implemented, so anything in `specs/` is real and anything absent from it is not yet built.

The planning skills are planning-only: they do not edit `.devcontainer/`, and implementation starts only on an explicit follow-up request.

## Conventions

- Shell scripts open with a comment block stating what the script guarantees and how it is invoked, use `set -euo pipefail`, and carry comments that explain *why* a step is ordered or written the way it is. Match that density.
- Prefer failing loudly over degrading quietly — the existing scripts abort on an unresolvable domain, an unreadable whitelist, an undetectable host IP, or a missing verification trailer.
- Any new capability granted to the container should come with a corresponding assertion in `verify.sh`; the repo's design is that guarantees are checked at every start, not documented and hoped for.
