## Context

See `proposal.md` — Why, for the three defects. The facts that constrain the fix, gathered from the live container:

- The firewall is genuinely absent right now. A full `verify.sh` run on 2026-08-31 gives **25 passed / 3 warnings / 6 failed**, ending `NOT VERIFIED` (exit 1). The six failures are: `example.com` reachable over HTTP, over HTTPS, **and by raw IP** (`104.20.23.154:80`, HTTP 200); `OUTPUT` policy `ACCEPT`; no OUTPUT ACCEPT rule for the ipset; the ipset missing or empty. Egress is unrestricted, not partially broken. This is the "before" baseline the host-side verification in `tasks.md` §5 has to invert.
- In that same run, **every reachability check passes** — `api.anthropic.com` (405), `statsig.com` (200), `sentry.io` (200), `registry.npmjs.org` (200). They pass because *nothing is blocked*, not because the whitelist works. Reachability is therefore worthless as a containment signal, which is why it must not gate container start.
- PID 1 is the devcontainer sleep shim, `/bin/sh -c 'echo Container started; trap "exit 0" 15; exec "$@"; while sleep 1 & wait $!; do :; done'`, started 12:08:27. Nothing ran before it.
- `sudoers` grants `node` exactly two NOPASSWD entries, `/usr/local/bin/init-firewall.sh` and `/usr/local/bin/verify.sh`. `sudo -n iptables` is refused, so anything needing the ruleset must go through those two scripts. `sudo` prints a `/run/sudo` warning because the rootfs is read-only, but NOPASSWD entries still work.
- `verify.sh --iptables-only` needs root, does no network I/O, and exits 1 on failure — so it is usable as a fast, offline start-time gate.
- `init-firewall.sh` flushes at lines 29–33 and first sets a DROP policy at line 95. Everything between is an open window with six `set -e` exit points in it.
- The container is `--read-only` with a `/tmp` tmpfs, so `/tmp` is recreated empty on every start — which makes it the right place for a "did the entrypoint run *this* start" marker.

**Update, 2026-08-31 14:02 — the entrypoint approach was tested and the composition assumption failed.** A container built from this change's completed §1–§4 work came up with the firewall entirely absent: `example.com` HTTP 200 by name over :80 and :443 and by raw IP, `OUTPUT` policy `ACCEPT`, ipset missing, `verify.sh` 7 FAIL / `NOT VERIFIED`. `entrypoint.sh` was present at `/usr/local/bin/`, `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]` was in the Dockerfile, and `sudo -n -l` listed both NOPASSWD entries — so the script was installed and would have worked. It simply never ran: no `/tmp/.sandbox-firewall-installed` marker, on a container that was still running two minutes in. A run-and-fail would have exited before `exec` and left the container stopped, so "never ran" is the only reading. See the `overrideCommand` decision below. One caveat: `docker inspect` is host-side, so from inside the container the CLI override could not be told apart from an image built before the `ENTRYPOINT` line existed. The override fits better — it also explains why `postStartCommand` installed nothing on that start — but the host check should settle it.

**Resolved, 2026-08-31 14:15.** With `"overrideCommand": false` pinned and the keep-alive `CMD` added, a recreated container comes up correct: marker present, `example.com` refused at TCP on both ports (`time_connect=0.000000`), all three chain policies `DROP`, ipset populated with 15 entries, `verify.sh` 36 passed / 0 warnings / 0 failed / `VERIFIED`. PID 1 reads as the image's own keep-alive rather than the CLI shim, which is the direct confirmation that the image `ENTRYPOINT` is no longer being discarded. The restart, abort, seal, outage, and escape-hatch paths — `tasks.md` §5.3–§5.8 — were exercised on the host later the same day and all confirmed, so defects A, B, and C are now closed by observation on a live container rather than by argument from the mechanism.

None of this is testable from inside the container: the entrypoint, the Dockerfile, and the restart behaviour are all host-side. That is not a formality — defect D reached "all tasks done" and a live unprotected sandbox before anyone looked.

## Goals / Non-Goals

**Goals:**

- Move the enforcement point from the launch tool to the container, so that every way of starting it is covered by construction rather than by remembering to use the right command.
- Make every abort path end with strictly less network access than it started with.
- Keep the hard fail-closed posture without letting a third party's outage prevent the sandbox from starting.

**Non-Goals:**

- Defending against a malicious agent tampering with the checks. The agent already runs as `node` with `--dangerously-skip-permissions`; the containment boundary is the kernel's netfilter state and the read-only rootfs, not `verify.sh`. The new checks catch misconfiguration and regression, which is what actually went wrong here.
- Reworking the whitelist, `allowed-domains.txt`, or what the firewall permits. Only *when* it is installed and *what happens when that fails* changes.
- Persisting iptables state across restarts. Rules are rebuilt each start; that is simpler and always current.

## Decisions

### An image `ENTRYPOINT` becomes the enforcement point

New `.devcontainer/entrypoint.sh`, installed to `/usr/local/bin/` and declared in exec form:

```dockerfile
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

Docker composes ENTRYPOINT with the container's command, so that command arrives as `"$@"` and the entrypoint ends with `exec "$@"`. Because ENTRYPOINT is part of the *image*, it runs on `docker start` and on a post-reboot restart, which is precisely what `postStartCommand` cannot do — **provided the launch configuration does not override it**, which is a condition, not a given; see the `overrideCommand` decision below. With the pin in place that command is the image's own `CMD`, not the devcontainer CLI's sleep shim. Shape:

```bash
set -euo pipefail
sudo -n /usr/local/bin/init-firewall.sh   || die "firewall installation failed"
sudo -n /usr/local/bin/verify.sh --iptables-only || die "firewall ruleset is not in whitelist mode"
: > /tmp/.sandbox-firewall-installed
exec "$@"
```

It runs as the image's final `USER node` and reaches root through the two existing NOPASSWD sudo entries, so no new privilege is granted and the Dockerfile's `USER` does not change. `die` writes to stderr and exits non-zero; because the failure happens before `exec`, the container stops and its reason is visible in `docker logs` and in the launching tool's output.

Alternatives considered:

- **Keep `postStartCommand` as the only enforcement point** — rejected; it is defect C, and no amount of care in the script fixes a hook that does not run.
- **A `--restart` policy or a supervisor inside the container** — heavier, and still leaves the first start unguarded.
- **Persisting iptables rules across restarts** — the network namespace is new each start; there is nothing to persist into.

### Failure exits rather than seals-and-runs

Per the chosen posture: a container that cannot install its firewall does not run. This closes defect B structurally — there is no unprotected container to attach to, so `sbx-claude` cannot reach one. The trade-off, accepted deliberately: a genuine misconfiguration means the container will not start at all, and you cannot `docker exec` into a stopped container to debug it.

The escape hatch is Docker's own, and deliberately not an in-image one: the host operator can run `docker run --entrypoint /bin/bash ...` (or `--entrypoint ""`) to get a shell without the firewall. An env-var bypass such as `SANDBOX_SKIP_FIREWALL=1` was considered and rejected — it would be a permanent documented way to start the sandbox unprotected, and `--entrypoint` already gives the host operator the same power without putting one in the image. Note that the agent cannot use either: it has no container engine.

### The start-time gate is `--iptables-only`, not the full `verify.sh`

The gate must be fast and must depend on nothing outside the container. `verify.sh --iptables-only` asserts the OUTPUT policy is DROP, the ipset ACCEPT rule exists, and the ipset is populated — all local state, no sockets.

Running the *full* `verify.sh` at the gate was considered and rejected: it probes `api.anthropic.com` as a required check, so an Anthropic outage or a slow network would stop the container from starting. Reachability is a health signal, not a containment property; it belongs in `postStartCommand`, where a failure is reported as `NOT VERIFIED` rather than being fatal. Bricking the sandbox because a third party is down would be a worse failure than the one being fixed.

The three properties the gate asserts are exactly `verify.sh`'s FAIL-severity iptables checks: OUTPUT policy DROP, the ipset ACCEPT rule present, the ipset populated. The section's other three observations — INPUT policy, FORWARD policy, and the catch-all REJECT — are `warn`, so they do not gate. Consequence, accepted: a container that is DROP on OUTPUT but ACCEPT on INPUT/FORWARD would still start. Only OUTPUT bears on egress containment, and promoting the other two to `bad` would make every check in the section launch-blocking for properties that are not the sandbox's promise.

### `init-firewall.sh` is reordered to DROP-first and gains a sealing trap

The script must be safe on its own, because it is separately sudo-able and may be re-run by hand mid-session. New order:

1. Capture the Docker DNS NAT rules (must precede any flush).
2. **Set INPUT/OUTPUT/FORWARD policy to DROP.**
3. Flush the filter chains. From here the container is sealed.
4. Restore the Docker DNS NAT rules.
5. Allow loopback and DNS — the minimum needed to resolve the whitelist.
6. Create the ipset, resolve each domain, populate it.
7. Host-network rules, ESTABLISHED/RELATED, the ipset ACCEPT, the catch-all REJECT.

Steps 2–3 in that order are the whole fix: from the first moment any pre-existing rule is removed, the default is already deny. During a successful run there is no instant at which the chains are both flushed and permissive.

The trap covers aborts after step 3 that might have added a permissive rule:

```bash
FIREWALL_OK=0
seal() {
  local rc=$?
  [ "$FIREWALL_OK" -eq 1 ] && return 0
  echo "ERROR: firewall setup aborted (exit $rc) - sealing the container" >&2
  iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT DROP
  iptables -F
  iptables -A INPUT  -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
}
trap seal EXIT
```

`EXIT` with a success flag rather than `ERR`, because `ERR` is not inherited into every construct and would miss some exits. Loopback is deliberately re-allowed in the sealed state: it grants no egress and keeps local tooling working, so a human diagnosing a sealed container is not fighting a broken shell. `FIREWALL_OK=1` is set on the last line of a successful run.

Keeping the abort-on-unresolvable-domain behaviour was confirmed with the user: the contract is unchanged, only the resulting state flips from open to sealed.

### `devcontainer.json` must pin `overrideCommand: false`

**Reversed on 2026-08-31.** This decision previously read "`devcontainer.json` is left alone" and asserted the entrypoint was purely additive. The live test above disproved it.

The devcontainer CLI defaults `overrideCommand` to true for Dockerfile- and image-based configs. That is not merely "it supplies the container's command": the CLI creates the container with `--entrypoint /bin/sh` and passes its sleep shim as the arguments, which **replaces the image `ENTRYPOINT` outright**. The decision that made the entrypoint the enforcement point rested on the two composing, and they do not compose — the CLI wins, and the image's entrypoint is discarded without a warning anywhere.

Worse for defect C specifically: `--entrypoint` is recorded in the *container's* configuration at create time, not applied per start. So a container created that way keeps bypassing the entrypoint on every subsequent `docker start`, Desktop restart, and post-reboot restart. The override does not just delay the fix for C, it defeats it permanently for the life of that container.

```jsonc
"overrideCommand": false
```

**Consequence: the image must supply its own keep-alive command.** With the override off, the CLI passes no command, so `"$@"` falls through to the image `CMD`. The Dockerfile currently declares none, and the base image is `node:24-trixie-slim`, whose `CMD` is `["node"]` — a REPL with no TTY, which exits immediately and stops the container. The Dockerfile therefore needs an explicit keep-alive `CMD` taking over the job the CLI's shim was doing. Its shape should mirror the shim: hold the container open and forward `SIGTERM` so `docker stop` is still prompt.

This also revises the zero-argument fallback in `entrypoint.sh`. Its `exec /bin/bash` was written for a bare `docker run <image>` with a TTY, and stays right for that; it must not become the path a devcontainer launch depends on. With an explicit `CMD` in place, `$#` is never 0 on the devcontainer path, and the fallback goes back to being what it was meant to be — a convenience for a hand-run image, not the keep-alive.

`postStartCommand` still runs `init-firewall.sh && verify.sh` and `waitFor` stays `postStartCommand`. Once the script is DROP-first the second install is safe and idempotent, it costs one extra DNS resolution per `devcontainer up` (not per start), and it means an image built *before* this change still gets a firewall by the old path. Reducing `postStartCommand` to `verify.sh` alone was considered — it gives installation a single owner — but the redundancy is cheap insurance against exactly the class of bug being fixed here, and defect D is what that insurance was for: it is the only reason the 2026-08-31 container was merely open rather than open *and* unreported.

Rollback is no longer a single Dockerfile line. Backing this change out means removing the `ENTRYPOINT`, the `CMD`, and the `overrideCommand` pin together — leaving `overrideCommand: false` with no keep-alive `CMD` produces a container that will not stay up.

### `verify.sh` asserts the enforcement point exists

Two additions, both FAIL severity:

1. The entrypoint marker `/tmp/.sandbox-firewall-installed` exists. `/tmp` is a tmpfs recreated on every start, so its presence means the entrypoint ran *this* start — which is the property that defect C violates.
2. `/proc/1/cmdline` is inspected to report what PID 1 is, as `info`, giving the reader of a failing log something to correlate against.

   **Corrected 2026-08-31.** This was originally justified as making "a launch that bypassed the entrypoint attributable in the log". It cannot do that, and the live test confirmed it: because `entrypoint.sh` ends in `exec "$@"`, the exec replaces the entrypoint's own process, so PID 1 reads as the CLI sleep shim *whether or not the entrypoint ran*. The two cases are byte-identical in `/proc/1/cmdline`. Keep the line — it is useful context, and it names whatever unexpected thing is PID 1 in a container launched some third way — but the marker is the only check that actually detects a bypass. It did detect this one, correctly and at FAIL severity.

Stated plainly: the marker is a configuration check, not an attestation. The agent can write `/tmp` and could forge it. That is acceptable — `verify.sh` exists to catch a sandbox that was built or started wrong, and the containment boundary is netfilter and the read-only rootfs, not this file.

## Risks / Trade-offs

- **A broken ENTRYPOINT breaks every start, including the one you would use to fix it** → This is the biggest risk in the change; it is a single point of failure for the whole image. Mitigations: exec form so there is no shell-parsing surprise; `exec "$@"` with a fallback when `$#` is 0; and the host-side `docker run --entrypoint /bin/bash` override, which needs nothing in the image. Rollback is deleting one Dockerfile line and rebuilding.
- **The devcontainer CLI could interact badly with an image ENTRYPOINT** → **This risk materialized on 2026-08-31, exactly as flagged.** The original assessment — "it sets the container's *command*, not its entrypoint, so the two compose normally" — was wrong. `overrideCommand` defaults to true and replaces the entrypoint, so the image `ENTRYPOINT` was silently discarded and the container ran with no firewall while every implementation task read as done. Addressed by the `overrideCommand: false` decision above, and **confirmed fixed on a recreated container at 14:15** — `verify.sh` `VERIFIED`, PID 1 the image keep-alive. Two lessons worth keeping: an anchor in the image is only as good as the launch configuration that honours it, and the "test the composition first, before judging anything else" instruction in the migration plan earned its place — it was the step that would have caught this on day one.

  The check added for this (`PID1_KEEPALIVE` in `verify.sh`) went FAIL on the broken container and PASS on the fixed one, across exactly the change it exists to detect. That is the standard a new assertion should meet before it is trusted: observed failing for the real defect, not only passing once the defect is gone.
- **A transient DNS failure now prevents the container from starting** → The deliberate consequence of the chosen posture, and the correct trade for a sandbox: not starting is safe, starting unprotected is not. Re-running `sbx-up` after the blip resolves it.
- **A sealed container is hard to diagnose** → Mitigated by keeping loopback up in the sealed state, by writing the abort reason to stderr where `docker logs` shows it, and by the `--entrypoint` override for the worst case.
- **`sudo`'s `/run/sudo` warning on a read-only rootfs** → Cosmetic; NOPASSWD entries work, as the live container demonstrates. Worth not mistaking for a failure when reading entrypoint output.
- **Redundant firewall installs per `devcontainer up`** → One extra pass over the whitelist. Accepted for the redundancy it buys.
- **Verified on the host, not from inside** → This bullet previously read "none of this is verified", and it was the right caution: the entrypoint, the restart path, and the fail-closed exit are all host-side, and defect D is what reasoning-without-testing cost. That exercise is now done — every check in `tasks.md` §5 was run against a live container on 2026-08-31 and passed. What remains true is the standing constraint, not a gap in this change: no future edit to `entrypoint.sh`, the Dockerfile, `devcontainer.json`, or `init-firewall.sh` can be checked from inside the sandbox, so each one re-enters this same unverified state until someone rebuilds on the host.

## Migration Plan

1. Add `entrypoint.sh`, wire it into the Dockerfile with a keep-alive `CMD`, set `"overrideCommand": false` in `devcontainer.json`, reorder `init-firewall.sh`, add the `verify.sh` checks, update the docs.
2. **Test the entrypoint composition first, in isolation** — rebuild and confirm the container starts at all *and that the entrypoint actually ran*. The 2026-08-31 failure is the reason this step is first and the reason the check is the marker, not PID 1: a container that starts and looks healthy proves nothing, because a discarded entrypoint looks exactly like an honoured one from inside. `/tmp/.sandbox-firewall-installed` present, `OUTPUT` policy `DROP`, `verify.sh` `VERIFIED`. If this step fails, nothing else matters.
3. Confirm the fix for defect C: `docker stop` then `docker start` the container, and check the ruleset is in whitelist mode without any `devcontainer up`.
4. Confirm the fail-closed path: temporarily add an unresolvable name to `allowed-domains.txt`, rebuild, and check the container stops rather than starting open.
5. Confirm the seal: run `sudo init-firewall.sh` by hand with a bad whitelist in a running container and check the chains end DROP with no egress.
6. Rollback at any point: remove the `ENTRYPOINT`, the `CMD`, and the `overrideCommand` pin together, then rebuild; the `postStartCommand` path is untouched and still works. Removing them together matters — `overrideCommand: false` without a keep-alive `CMD` leaves a container that will not stay up.
