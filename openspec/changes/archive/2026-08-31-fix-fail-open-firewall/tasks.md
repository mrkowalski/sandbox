## 1. Make init-firewall.sh fail closed

- [x] 1.1 Reorder `.devcontainer/init-firewall.sh` so the three chain policies are set to DROP *before* the flush: capture the Docker DNS NAT rules, set `iptables -P INPUT/OUTPUT/FORWARD DROP`, then flush, then restore the DNS rules and add loopback/DNS ACCEPT. Verify by reading the script that no line between the first flush and the final ruleset leaves the chains permissive.
- [x] 1.2 Add the `seal` EXIT trap with a `FIREWALL_OK` success flag, setting all three policies DROP, flushing, and re-adding loopback only; set `FIREWALL_OK=1` on the last line of a successful run. Verify the trap is `EXIT` (not `ERR`) and that the success path leaves the completed ruleset untouched.
- [x] 1.3 Update the script's header comment block to state the fail-closed guarantee — that an abort leaves the container sealed, never more open than it was found — matching the repo's convention that each script opens by stating what it guarantees.
- [x] 1.4 Confirm the abort-on-unresolvable-domain behaviour is preserved: the `exit 1` paths for an unresolvable name, an invalid address, an empty whitelist, an unreadable whitelist, and an undetectable host IP all remain, and now land in the sealed state.

## 2. Anchor firewall installation to container start

- [x] 2.1 Create `.devcontainer/entrypoint.sh`: run `sudo -n init-firewall.sh`, then `sudo -n verify.sh --iptables-only`, write the `/tmp/.sandbox-firewall-installed` marker, and `exec "$@"`. Each failure must write an attributable reason to stderr and exit non-zero before reaching `exec`. Open with the standard comment block and `set -euo pipefail`.
- [x] 2.2 Handle an empty argument list (`$# -eq 0`) with a sensible fallback rather than an `exec` with no arguments, so the image is still runnable without a supplied command; verify with a direct `docker run` that passes no command.
- [x] 2.3 Wire it into `.devcontainer/Dockerfile`: `COPY entrypoint.sh /usr/local/bin/`, `chmod +x` it in the existing root block alongside the other scripts, and add `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]` in exec form. Verify the Dockerfile still ends with `USER node` and that no new sudoers entry was needed.
- [x] 2.4 ~~Confirm `.devcontainer/devcontainer.json` needs no change~~ — **falsified by the 2026-08-31 live test; see §6.** The devcontainer CLI's `overrideCommand` default replaces the image `ENTRYPOINT`, so the entrypoint never ran and the container came up with no firewall. Set `"overrideCommand": false` in `.devcontainer/devcontainer.json`. `postStartCommand` and `waitFor` still stay exactly as they are.

## 3. Assert the new guarantees in verify.sh

- [x] 3.1 Add a check that the `/tmp/.sandbox-firewall-installed` marker exists, at `bad` severity, with a comment noting that `/tmp` is a tmpfs recreated each start so the marker proves the entrypoint ran *this* start. Verify it FAILs in a container started without the entrypoint and PASSes in one started with it.
- [x] 3.2 Add an `info` line reporting what PID 1 is, read from `/proc/1/cmdline`. ~~so a start that bypassed the entrypoint is attributable in the log~~ — **that rationale is wrong; corrected 2026-08-31.** `entrypoint.sh` ends in `exec "$@"`, which replaces its own process, so PID 1 reads as the launch tool's shim whether the entrypoint ran or not; the two cases were confirmed byte-identical in the live container. Keep the line as context for an unexpected PID 1, but the marker in 3.1 is the only check that detects a bypass — and it did detect this one. Update the comment so a future reader does not trust the line for attribution.
- [x] 3.3 Add a comment in `verify.sh` (or extend the marker check's block) recording that the marker is a configuration check and not tamper-proof, so a future reader does not mistake it for an attestation.

## 4. Update documentation

- [x] 4.1 Correct the "load-bearing line" claim in `CLAUDE.md`: `postStartCommand` with `waitFor` fails the launch *command* but does not stop the container and does not re-run on restart, so it is no longer what enforces the sandbox. Describe the entrypoint as the enforcement point. Verify the architecture section's file chain is renumbered coherently and that no remaining sentence claims `postStartCommand` is what makes the properties hold.
- [x] 4.2 Document the fail-closed contract in `CLAUDE.md`: a failed firewall install stops the container, the whitelist's abort paths leave it sealed rather than open, and the host-side `docker run --entrypoint /bin/bash` override is the escape hatch when a container will not start.
- [x] 4.3 Add a short README note that restarting the container by any means re-installs the firewall, and that a container which fails to start is the sandbox refusing to run unprotected rather than a fault.

## 5. Host-side verification (user runs these; not possible from inside the container)

~~Blocked on §6.~~ ~~**Unblocked 2026-08-31 14:15** — 5.3–5.8 remain.~~ **Complete 2026-08-31** — §6 landed, the container was recreated, and 5.1/5.2 passed at 14:15; the user then exercised the restart, abort, seal, outage, and escape-hatch paths (5.3–5.8) on the host and confirmed all six. Every path this change claims is now verified against a live container rather than reasoned about.

- [x] 5.1 Rebuild and confirm the entrypoint composes correctly with the devcontainer CLI *before* judging anything else: `devcontainer up --remove-existing-container` completes and the container stays up.

  **Attempted 2026-08-31 14:02 — FAILED.** The container started and stayed up, but the entrypoint never ran: no `/tmp/.sandbox-firewall-installed`, `OUTPUT` policy `ACCEPT`, no ipset, `example.com` answering HTTP 200 by name and by raw IP, `verify.sh` 7 FAIL / `NOT VERIFIED`. Cause: the CLI's `overrideCommand` default replaces the image `ENTRYPOINT` — see §6.

  **Re-run 2026-08-31 14:15 after §6 — PASSED.** Marker present, `verify.sh` 36 passed / 0 warnings / 0 failed, `VERIFIED`. PID 1 reads as the image's own keep-alive (`sandbox keep-alive (image CMD)`), not the CLI shim — and since `--entrypoint` is written into the container config at create time, that is positive proof the container was *recreated* under `"overrideCommand": false` rather than merely restarted.

  The original pass criterion, "PID 1 is still the devcontainer sleep shim", was **removed**: it was satisfied by the failing container, because PID 1 looks identical either way. Judged instead on the marker and the ruleset — `/tmp/.sandbox-firewall-installed` present, `OUTPUT` policy `DROP`, `verify.sh` `VERIFIED`.
- [x] 5.2 Confirm the firewall is active after a normal launch: `verify.sh` prints `VERIFIED` and exits 0, and all six checks failing in the 2026-08-31 baseline now pass — `example.com` blocked by name over HTTP and HTTPS and by raw IP, OUTPUT policy DROP, the ipset ACCEPT rule present, the ipset populated.

  **Confirmed 2026-08-31 14:15.** All six inverted. `example.com` fails at TCP on both :80 and :443 with `time_connect=0.000000` — no connection at all, so this is a genuine block and not a certificate error being misread; the raw-IP probe passes with it. `OUTPUT`, `INPUT`, and `FORWARD` policies all `DROP`, the ipset ACCEPT rule present, the ipset populated with 15 entries, and the catch-all REJECT in place. All four whitelisted endpoints still reachable, so the whitelist works rather than everything being blocked.
- [x] 5.3 Confirm defect C is fixed: `docker stop` then `docker start` the container — with no `devcontainer up` — and check the ruleset is in whitelist mode and `verify.sh` still passes.
- [x] 5.4 Confirm defect B is fixed: temporarily put an unresolvable hostname in `allowed-domains.txt`, rebuild, and check the container stops instead of running unprotected, that `docker logs` shows the reason, and that `devcontainer exec` cannot attach to it.
- [x] 5.5 Confirm the seal (defect A): in a healthy running container, run `sudo /usr/local/bin/init-firewall.sh` by hand with an unresolvable name in the whitelist, and check the chains end with all three policies DROP, no general-egress ACCEPT rule, and loopback still working — never the open state seen today.
- [x] 5.6 Confirm an upstream outage does not block startup: with the firewall correct but `api.anthropic.com` unreachable (for example by removing it from the whitelist), the container still starts and the full `verify.sh` reports the unreachable endpoint as a FAIL.
- [x] 5.7 Confirm the escape hatch: `docker run --entrypoint /bin/bash` on the image gives a shell without installing the firewall, so a container that will not start can still be diagnosed.
- [x] 5.8 Restore `allowed-domains.txt` to its correct contents and rebuild; verify `git status` shows no leftover test edits.

## 6. Keep the entrypoint from being overridden (defect D)

- [x] 6.1 Add `"overrideCommand": false` to `.devcontainer/devcontainer.json` with a comment (or a README/CLAUDE.md note, since the file is strict JSON if it has no `jsonc` affordances) recording *why*: the CLI otherwise creates the container with `--entrypoint /bin/sh`, discarding the image `ENTRYPOINT` that is the enforcement point, and bakes that override into the container config so every later `docker start` bypasses it too.
- [x] 6.2 Add a keep-alive `CMD` to `.devcontainer/Dockerfile`, taking over the job the CLI's sleep shim was doing. Required, not optional: with the override off the CLI supplies no command, so `"$@"` falls through to the base image's `CMD ["node"]` (`node:24-trixie-slim`), which without a TTY exits immediately and stops the container. Mirror the shim's two properties — hold the container open, and forward `SIGTERM` so `docker stop` stays prompt rather than waiting out the timeout.
- [x] 6.3 Confirm `entrypoint.sh`'s `$# -eq 0` fallback is no longer load-bearing. With an explicit `CMD` the devcontainer path always passes a command, so `exec /bin/bash` goes back to being what task 2.2 intended — a convenience for a hand-run `docker run -it <image>`. Leave it; just make sure no launch path now depends on it.
- [x] 6.4 Add a `verify.sh` check, at `bad` severity, that the container's command is the image's own keep-alive and not a launch tool's shim — or, if that cannot be distinguished from inside, record in the marker check's comment block why the marker is the only available detector. Note the constraint from §3.2: `/proc/1/cmdline` cannot tell the two apart.
