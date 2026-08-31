# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is not an application — it is the definition of a headless Docker dev container that sandboxes Claude Code itself. There is no source tree, no package manifest, no test suite. The deliverable is `.devcontainer/`: an image, a firewall, and a verification script. Everything else (README, `openspec/`) describes or plans that.

The sandbox exists so that `claude --dangerously-skip-permissions` is safe to run: the agent can only see the bind-mounted project folder, can only reach whitelisted hosts, and cannot `git push`. Cost is meant to be the only remaining risk.

## Working from inside the sandbox

If `$DEVCONTAINER=true` (the normal case when Claude Code runs here), you are inside the very container this repo builds:

- `docker`, `podman`, and the `devcontainer` CLI are **not** installed, and the rootfs is read-only outside `/workspace`, `/tmp`, `/commandhistory`, and `/home/node/.claude`. You cannot build, run, or rebuild the container.
- The scripts under `/usr/local/bin/` are the copies baked into the running image, not the repo's working tree. Editing `.devcontainer/*.sh` changes nothing about the current session; the change takes effect only after a host-side rebuild.
- Egress is default-deny, so most network commands fail by design. A failed fetch is usually the firewall working, not a bug.

Consequence: **you cannot verify your own changes to this repo.** Changes to `.devcontainer/` must be exercised by the user on the host (see below). Say plainly what you were unable to test rather than implying it was checked.

## Host-side commands (for the user, not for you)

```bash
SBX=~/tools/sandbox/.devcontainer/devcontainer.json
devcontainer up   --workspace-folder "$PWD" --config "$SBX" --remove-existing-container   # rebuild + launch
devcontainer exec --workspace-folder "$PWD" --config "$SBX" claude --dangerously-skip-permissions
```

`verify.sh` is the test suite. It runs automatically as part of `postStartCommand`; a manual re-run inside a container is:

```bash
verify.sh                  # full run; prints VERIFIED / NOT VERIFIED, exits 1 on any FAIL
sudo verify.sh --iptables-only   # just the ruleset checks (this is how the full run reads iptables)
```

## Architecture: how the security contract is enforced

Four files form one chain; a change to any of them is a change to the sandbox's guarantees.

1. **`devcontainer.json`** grants `NET_ADMIN`/`NET_RAW` (needed to install the firewall), makes the rootfs `--read-only` with a `/tmp` tmpfs, bind-mounts the host project at `/workspace`, and keeps bash history and Claude Code config in per-container named volumes keyed on `${devcontainerId}`. Its `postStartCommand` runs `init-firewall.sh && verify.sh` with `waitFor: postStartCommand` — **this is the load-bearing line**: because a failing verification fails the launch, the sandbox's properties are enforced rather than merely intended. Do not weaken `waitFor`, and do not move verification out of `postStartCommand`.

2. **`allowed-domains.txt`** is the whole egress policy, one hostname per line, installed to `/usr/local/etc/`. Widening the sandbox means adding a line here — not adding an iptables rule. A name that fails to resolve aborts firewall setup by design.

3. **`init-firewall.sh`** captures the engine's container-DNS NAT rules (grepping `iptables-save -t nat` for Docker's `127.0.0.11`), flushes everything, restores only those DNS rules, resolves each whitelisted host into the `allowed-domains` ipset, then sets all three chain policies to DROP with a single ACCEPT for the ipset and a catch-all REJECT. Order matters: DNS and loopback are allowed before anything is resolved, policies flip to DROP only after the set is built.

4. **`verify.sh`** independently asserts the end state rather than trusting step 3: arbitrary egress is dead (`example.com` by name *and* by IP, HTTP and HTTPS), `git push --dry-run` fails over both SSH and HTTPS, `api.anthropic.com` is reachable, and the OUTPUT chain is genuinely in whitelist mode with a populated ipset.

Two subtleties in `verify.sh` worth knowing before editing it:

- Reachability is judged by curl's `%{time_connect}`, not its exit code. A TLS or certificate error happens *after* a successful TCP connect, so exit-code-only logic would score a reachable host as blocked. Preserve this distinction in any new probe.
- Reading iptables needs root, so the script re-execs `/usr/local/bin/verify.sh --iptables-only` under a narrow passwordless sudo entry and folds the child's counts back via the `__VERIFY_COUNTS__`/`__VERIFY_FAILED__` trailer. That sudo entry (in the Dockerfile) names the installed path, so editing the working-tree copy alone leaves a stale installed copy — the script detects a missing trailer and fails loudly rather than silently skipping the check.

Distinguish `bad` (FAIL, exits non-zero, blocks launch) from `warn` (WARN, informational) when adding checks: a check promoted to FAIL will prevent every container from starting.

## Change workflow

This repo uses OpenSpec (`openspec` CLI is in the image; the `openspec-*` skills and `/opsx:*` commands drive it). Planning artifacts live in `openspec/changes/<name>/` — `proposal.md`, `design.md`, `specs/<capability>/spec.md`, `tasks.md` — and archived changes move to `openspec/changes/archive/`.

Important: `openspec/specs/` is currently **empty**, and both archived changes (`add-podman-support`, `add-sbx-launcher`) were abandoned with zero tasks implemented. Their headers say so. Read them as rejected proposals, never as descriptions of the repo — the sandbox is Docker-only and the launcher is still the two `sbx-up`/`sbx-claude` shell functions in the README.

The planning skills are planning-only: they do not edit `.devcontainer/`, and implementation starts only on an explicit follow-up request.

## Conventions

- Shell scripts open with a comment block stating what the script guarantees and how it is invoked, use `set -euo pipefail`, and carry comments that explain *why* a step is ordered or written the way it is. Match that density.
- Prefer failing loudly over degrading quietly — the existing scripts abort on an unresolvable domain, an unreadable whitelist, an undetectable host IP, or a missing verification trailer.
- Any new capability granted to the container should come with a corresponding assertion in `verify.sh`; the repo's design is that guarantees are checked at every start, not documented and hoped for.
