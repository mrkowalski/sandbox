## 1. Feasibility gate (rootless Podman go / no-go)

The design names two unknowns that decide whether rootless Podman can be supported at all. Settle them before writing the configuration, so the answer is evidence rather than assumption. These tasks run on a Linux host with rootless Podman installed — not inside this sandbox, which has no container engine.

- [ ] 1.1 On a rootless Podman host, run the sandbox image manually with `--cap-add=NET_ADMIN --cap-add=NET_RAW` and execute `init-firewall.sh`; verify it exits 0 and that `iptables -S` afterwards shows `OUTPUT` policy `DROP` plus the ipset-matching ACCEPT rule. Record whether `ip_set` had to be `modprobe`d on the host first.
- [ ] 1.2 In that same container, run `verify.sh` unchanged and record which checks pass, fail, or warn. This is the baseline the parity requirement is measured against.
- [ ] 1.3 Decide go / no-go from 1.1 and 1.2. If any security check cannot be made to pass rootless, stop and revise the proposal to drop rootless Podman rather than weakening a check — the spec's *No engine-specific exemption* scenario forbids the alternative. Verify by recording the decision and its evidence in the change before continuing.

## 2. Engine-neutral script changes

These land regardless of the outcome of group 1 and must not alter Docker behavior.

- [ ] 2.1 Replace the hardcoded `127.0.0.11` NAT-rule capture in `.devcontainer/init-firewall.sh` with a capture keyed on the nameserver addresses read from `/etc/resolv.conf`. Verify on Docker that `iptables-save -t nat` after the script runs contains the same DNS rules as before the change (diff the before/after rule sets).
- [ ] 2.2 Verify the new capture degrades correctly: on an engine that installs no matching NAT rules, `init-firewall.sh` still exits 0 and a whitelisted hostname resolves. Confirm the "nothing to restore" path prints an engine-neutral message, not a Docker-specific one.
- [ ] 2.3 Add engine and user-namespace reporting to `.devcontainer/verify.sh`: detect Podman via `/run/.containerenv` or `$container`, Docker via `/.dockerenv`, otherwise `unknown`, and report the mapping from `/proc/self/uid_map`. Verify it prints the correct engine on Docker and `unknown` does not cause a non-zero exit.
- [ ] 2.4 Add a FAIL-level workspace write check to `verify.sh` that creates, modifies, and deletes a temporary file under `/workspace`. Verify it passes on Docker, and that it reports FAIL (not WARN) when run against a deliberately read-only mount.
- [ ] 2.5 Add FAIL-level write checks for `/commandhistory` and `/home/node/.claude`. Verify both pass on Docker and that each names the specific location on failure.
- [ ] 2.6 Run the full `verify.sh` on Docker and confirm every pre-existing check still passes and the exit code is unchanged — the Docker path must be indistinguishable from before.

## 3. Podman configuration

- [ ] 3.1 Create `.devcontainer/devcontainer.podman.json` from `devcontainer.json`, adding `--userns=keep-id:uid=1000,gid=1000` to `runArgs` and `:Z` to the workspace mount, keeping the same Dockerfile, mounts, `containerEnv`, `remoteUser`, `postStartCommand`, and `waitFor`. Verify `devcontainer up --docker-path podman` starts the container.
- [ ] 3.2 Add the header comment naming the keys that must stay in step with `devcontainer.json`. Verify by diffing the two files and confirming the only differences are `name`, `runArgs`, `workspaceMount`, and the comment.
- [ ] 3.3 Verify identity mapping end to end: inside the container `id -u` is 1000, and a file written to `/workspace` is owned on the host by the launching user with no escalation needed to edit it.
- [ ] 3.4 Verify named-volume ownership is inherited from the image as the design assumes: on a first launch with fresh volumes, `node` can write to both `/commandhistory` and `/home/node/.claude`. If ownership is wrong, resolve it in the configuration — do not relax the write checks from 2.5.
- [ ] 3.5 Verify persistence: write a distinguishable file into the Claude config directory and shell history, stop the container, launch it again for the same project, and confirm both are present.

## 4. Parity verification

- [ ] 4.1 Run the full `verify.sh` under rootless Podman and confirm every check passes: blocked egress over HTTP and HTTPS, `git push` blocked over SSH and HTTPS, Anthropic endpoints reachable, `OUTPUT` policy `DROP`, ipset populated, and the three new write checks.
- [ ] 4.2 Confirm the launch actually fails when verification fails under Podman — `waitFor: postStartCommand` must gate the Podman config exactly as it gates Docker. Verify by temporarily pointing the whitelist at a domain that makes a check fail and observing the launch abort.
- [ ] 4.3 Verify SELinux behavior on an SELinux-enforcing host (Fedora or RHEL): the workspace is accessible with `:Z` present, and confirm the option is inert on a non-SELinux host.
- [ ] 4.4 Verify engine mismatch fails cleanly: launching `devcontainer.podman.json` with Docker errors out rather than starting a container without the intended mapping.
- [ ] 4.5 Verify the missing-prerequisite paths: launching with Podman absent, and launching rootless without subuid/subgid configured, each fail with a message naming the missing prerequisite and do not start Claude Code.

## 5. Documentation

- [ ] 5.1 Add a Podman section to `README.md` covering rootless prerequisites (Podman ≥ 4.3, configured subuid/subgid, and the `ip_set` modules if 1.1 showed they are needed) and the `--docker-path podman` invocation. Verify by following the section verbatim on a clean host and reaching a passing `verify.sh`.
- [ ] 5.2 Add the Podman equivalents of the `sbx-up` / `sbx-claude` shell functions, pointing at `devcontainer.podman.json`. Verify both work as documented.
- [ ] 5.3 State in the README that rootful Podman, `podman machine` on macOS or Windows, and Compose are unsupported, so the boundary is explicit rather than implied.
- [ ] 5.4 Resolve the design's two open questions in the README wording — whether `modprobe ip_set` is listed as a prerequisite, and how the minimum Podman version is stated. Verify both are answered in the shipped text.
