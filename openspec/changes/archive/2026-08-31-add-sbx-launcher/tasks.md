## 1. Establish facts the design depends on

- [ ] 1.1 Determine whether `${devcontainerId}` is stable across a rebuild after a config edit: run `devcontainer up` for a scratch project, note the two volume names via `docker volume ls`, edit `allowed-domains.txt`, run `devcontainer up --remove-existing-container`, and record whether the same volumes are reattached. Verified by writing the answer into `design.md` under Risks, replacing the open item.
- [ ] 1.2 Confirm `devcontainer up` exits non-zero when `postStartCommand` fails: temporarily point `ALLOWED_DOMAINS_FILE` at a file with an unresolvable host (or otherwise force `verify.sh` to fail) and check `$?`. Verified by recording the observed exit status; if it exits zero, add a task to parse the CLI's JSON `outcome` field instead of relying on the exit code.
- [ ] 1.3 Confirm plain `devcontainer up` (no `--remove-existing-container`) reuses a running container and re-runs `postStartCommand`. Verified by seeing the firewall/verify output on the second `up` with the container id unchanged.

## 2. The launcher script

- [ ] 2.1 Create `bin/sbx` with `#!/usr/bin/env bash`, `set -euo pipefail`, and a usage/`--help` block; commit it executable. Verified by `sbx --help` printing usage and exiting 0, and `git ls-files -s bin/sbx` showing mode `100755`.
- [ ] 2.2 Implement self-location: resolve the script's real path, derive `<repo>/.devcontainer/devcontainer.json`, allow `SBX_CONFIG` to override, and fail with a clear message if the config file is missing. Verified by invoking `sbx` through a symlink from another directory and confirming it resolves the repo config.
- [ ] 2.3 Implement argument parsing: `--rebuild`, `--help`, and `--` separating pass-through arguments for `claude`. Verified by a dry-run mode or `set -x` trace showing launcher flags consumed and post-`--` arguments forwarded verbatim in order.
- [ ] 2.4 Implement prerequisite checks — `devcontainer` on `PATH`, `docker` on `PATH`, `docker info` succeeding — each with its own message naming the fix, exiting non-zero. Verified by running `sbx` with `PATH` stripped of each tool in turn and with the Docker daemon stopped, confirming three distinct messages and non-zero exits.
- [ ] 2.5 Implement the configuration fingerprint: SHA-256 over the sorted `(relative path, mode, content hash)` triples of every file under `.devcontainer/`. Verified by a check that the value is stable across repeated runs and across `touch` of a file, and changes when a file's content, mode, or name changes, or a file is added or removed.
- [ ] 2.6 Implement per-project state: read/write `${XDG_STATE_HOME:-$HOME/.local/state}/sbx/<slug>.fingerprint` keyed on a hash of the absolute project path, creating the directory as needed. Verified by running in two different project directories and confirming two distinct state files.
- [ ] 2.7 Implement the rebuild decision (`--rebuild` given, or recorded fingerprint missing, or differing) and print the reason before a rebuild starts. Verified by running twice unchanged (no rebuild message), then after editing `allowed-domains.txt` (rebuild message naming the config change), then with `--rebuild` (rebuild message naming the explicit request).
- [ ] 2.8 Invoke `devcontainer up --workspace-folder "$PWD" --config "$SBX_CONFIG"`, adding `--remove-existing-container` when rebuilding; on non-zero exit, surface the output, report that the sandbox is not usable, and exit non-zero without reaching `claude`. Verified by forcing an `up` failure (per task 1.2) and confirming no Claude Code session starts.
- [ ] 2.9 Write the fingerprint to the state file only after `devcontainer up` exits zero. Verified by forcing a failure and confirming the state file is unchanged, so the next run still rebuilds.
- [ ] 2.10 End the script with `exec devcontainer exec --workspace-folder "$PWD" --config "$SBX_CONFIG" claude --dangerously-skip-permissions "$@"`. Verified by `sbx -- --version` exiting 0 and `sbx -- --nonexistent-flag` propagating Claude Code's non-zero status back to the host shell.

## 3. End-to-end verification against the specs

- [ ] 3.1 Cold start: in a project with no container, run `sbx` and confirm the container is provisioned, `VERIFIED` appears from `verify.sh`, and an interactive Claude Code session opens.
- [ ] 3.2 Warm start: exit and re-run `sbx` in the same project; confirm no image rebuild, the same container id is reused, the firewall/verify output appears again, and the session opens noticeably faster than the cold start.
- [ ] 3.3 Stopped container: `docker stop` the project's container, run `sbx`, and confirm it starts the existing container rather than creating a new one.
- [ ] 3.4 Drift: edit `.devcontainer/allowed-domains.txt`, run `sbx`, and confirm the rebuild message, a fresh container, and that the new whitelist is in effect inside the session (`sudo ipset list allowed-domains`).
- [ ] 3.5 Isolation: run `sbx` in project A and then project B; confirm two containers exist simultaneously, each bound to its own workspace, and that `/workspace` inside each shows only that project.
- [ ] 3.6 Unsandboxed-fallthrough audit: read `bin/sbx` end to end and confirm `claude` is reachable only via the single terminal `exec`, with every other path exiting non-zero. Record the audit result in the change's completion notes.

## 4. Documentation

- [ ] 4.1 Update `README.md`: add `bin/` to the `PATH` in the `.bashrc` snippet, present `sbx` as the everyday command, document `--rebuild` and `--` pass-through, and keep the `sbx-up`/`sbx-claude` functions documented as escape hatches. Verified by following the README from a clean shell and reaching a working session using only its instructions.
- [ ] 4.2 Document the caveats the README needs to carry: that the fingerprint watches `.devcontainer/` only (so upstream Claude Code or base-image updates need `--rebuild`), that concurrent `sbx` runs in the same directory can fight, and — if task 1.1 found the id unstable — that a config change means re-authenticating Claude Code. Verified by the README containing each caveat.
