## Why

**The sandbox is currently running with no firewall at all.** Observed in a live container on 2026-08-31: `OUTPUT` policy `ACCEPT`, no ipset, no rules — `example.com` answers HTTP 200 by name over both HTTP and HTTPS and by raw IP. `verify.sh` correctly reports `NOT VERIFIED` and exits 1 — but it reports it to nobody, long after the container became usable.

This is not one bug. Investigation turned up four independent defects, each of which produces exactly that state, and each of which breaks the sandbox's central promise that egress is default-deny:

**A. `init-firewall.sh` fails open.** It flushes every chain at line 29 and does not set `iptables -P OUTPUT DROP` until line 95. Six abort paths sit in between — an unresolvable domain (the *documented* "aborts firewall setup by design" behaviour), a DNS blip, `ipset create` failing on a set still in use, an undetectable host IP, an invalid DNS answer, a failed DNS-rule restore. `set -euo pipefail` turns each into an immediate exit that leaves the container **more open than before the script ran**: original rules flushed, policies still `ACCEPT`. The script fails loudly in its log and silently open on the wire. The whitelist's own error path is the most likely trigger, and it is the one the docs advertise as safe.

**B. A failed `postStartCommand` does not stop the container.** `waitFor: postStartCommand` makes `devcontainer up` exit non-zero, but the container is already running and stays running. `sbx-claude` is a *separate* command; nothing stands between a failed launch and attaching to an unprotected container. `CLAUDE.md` calls this the load-bearing line, but what it actually guarantees is that the launch *command* fails — not that the sandbox is unusable.

**C. Restart bypasses `postStartCommand` entirely.** iptables rules and ipsets live in the container's network namespace and do not survive a stop/start. `docker start`, Docker Desktop's restart button, an IDE reattach, or a host reboot brings the container back with an empty ruleset — and `postStartCommand` is a devcontainer-CLI concept that does not re-run. The container comes up unprotected, `devcontainer exec` works normally, and nothing anywhere reports it. This is the most dangerous of the three because it needs no failure to trigger: a perfectly healthy sandbox becomes an open one just by being restarted.

**D. An image `ENTRYPOINT` is not self-enforcing — the launcher can override it, and the override sticks.** Found on 2026-08-31 by running the container built from this change's own §1–§4 work. `entrypoint.sh` was installed at `/usr/local/bin/`, the Dockerfile declared `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`, and both NOPASSWD sudoers entries it needs were present — and it still never ran: no `/tmp/.sandbox-firewall-installed` marker on a container two minutes into its life, with `OUTPUT` policy `ACCEPT` and no ipset. (Had it run and failed, it would have exited before `exec` and the container would be stopped, not running.) The devcontainer CLI defaults `overrideCommand` to true for Dockerfile-based configs and creates the container with `--entrypoint /bin/sh` plus its sleep shim; `devcontainer.json` never set `"overrideCommand": false`. Because `--entrypoint` is written into the *container's* config at create time, every later `docker start` of that container bypasses the entrypoint too — so the override defeats the fix for C as well as for the first start. This is the assumption `design.md` flagged as the one most worth testing first, and it did not hold. **Fixed and verified the same day:** with `"overrideCommand": false` pinned and a keep-alive `CMD` in the image, a recreated container came up with the marker present, `example.com` refused at TCP, all three chain policies `DROP`, and `verify.sh` reporting `VERIFIED` — 36 passed, 0 failed.

The common root cause of A–C is that firewall installation is anchored to a **launch tool** rather than to the **container**, and that its failure mode is open rather than closed. D is the correction to the fix itself: anchoring to the image is necessary but not sufficient, because the launch configuration can still detach the anchor. The configuration has to be pinned, and the pin has to be verified rather than assumed.

## What Changes

- **Anchor the firewall to container start, not to the devcontainer CLI.** A new image `ENTRYPOINT` installs the firewall on *every* start — `devcontainer up`, `docker start`, a Desktop restart, a host reboot — and only then execs the container's command. Closes C.
- **Pin the launch configuration so it cannot detach the anchor.** `devcontainer.json` sets `"overrideCommand": false`, and the Dockerfile supplies its own keep-alive `CMD` to replace the shim the CLI stops providing. Closes D. Without this the `ENTRYPOINT` is silently discarded and the rest of the change does nothing.
- **Fail closed by exiting.** If firewall setup or its structural verification fails, the entrypoint never reaches the container's command, so the container stops. There is no unprotected container left running to attach to. Closes B: a container whose firewall did not install no longer exists to be attached to.
- **Gate the entrypoint on offline checks only.** The entrypoint runs `verify.sh --iptables-only`, which asserts the ruleset is genuinely in whitelist mode and needs no network. The full network-probing `verify.sh` stays in `postStartCommand`. This keeps the hard fail-closed posture without making the sandbox unable to start during an upstream outage — an unreachable `api.anthropic.com` should report `NOT VERIFIED`, not brick the container.
- **Make `init-firewall.sh` fail closed on its own.** Set all three chain policies to `DROP` *before* flushing, and install a trap that seals the container (policies `DROP`, rules dropped) on any abort. The script is separately sudo-able and may be re-run mid-session, so it must not depend on the entrypoint for its safety. An abort now lands in a sealed state instead of an open one. **BREAKING** in one respect: a failed run now leaves the container with no egress rather than full egress. That inversion is the entire point.
- **Keep aborting on an unresolvable whitelist entry.** The documented contract stands; only the state it leaves behind changes, from open to sealed.
- **Assert the new guarantees in `verify.sh`**, per the repo's rule that every guarantee is checked at every start rather than documented and hoped for.

## Capabilities

### New Capabilities

- `firewall-enforcement`: when the egress firewall is installed, what must happen when installation fails, and what must be true of the container's state in either case. Covers the enforcement point (every container start, not every CLI launch), the fail-closed requirement, and the verification that proves it.

### Modified Capabilities

None. `openspec/specs/` is empty, so there is no existing spec to delta.

## Impact

- `.devcontainer/Dockerfile` — new `ENTRYPOINT`, a keep-alive `CMD` for it to exec, plus installing the entrypoint script.
- `.devcontainer/entrypoint.sh` — new file.
- `.devcontainer/init-firewall.sh` — reordered to DROP-first, plus a sealing trap.
- `.devcontainer/verify.sh` — new assertions.
- `.devcontainer/devcontainer.json` — **must set `"overrideCommand": false`**. This was initially planned as unchanged; the 2026-08-31 test showed the CLI's default silently overrides the image `ENTRYPOINT`, so the entrypoint is additive only once the override is off. `postStartCommand` and `waitFor` still stay as they are.
- `CLAUDE.md` — the architecture section's four-file chain becomes five, and the "load-bearing line" claim about `postStartCommand` needs correcting: it is no longer the thing that enforces the sandbox, and describing it that way is what let this go unnoticed.
- `README.md` — the restart caveat is worth stating for anyone who uses Docker Desktop's restart button.

Risk concentrated in one place: an `ENTRYPOINT` that mishandles its arguments breaks *every* container start, including the ability to get in and fix it. Turning off `overrideCommand` moves the container's keep-alive process from the CLI into the image, which puts that risk on the path that every launch now takes. The design covers argument handling and the rollback path.

As always, none of this is verifiable from inside the container; the user must exercise it on the host. Defect D is the standing proof of that: §1–§4 were all marked done, and the sandbox was still running wide open. That exercise was completed on 2026-08-31 — every check in `tasks.md` §5 was run against a live container and passed, covering the normal launch, the bare `docker start` restart, the unresolvable-whitelist abort, the manual re-run seal, an unreachable whitelisted endpoint, and the `--entrypoint` escape hatch.
