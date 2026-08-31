## 1. Mount the writable cache

- [x] 1.1 Add `"source=claude-code-npm-${devcontainerId},target=/home/node/.npm,type=volume"` to the `mounts` array in `.devcontainer/devcontainer.json`, alongside the existing bashhistory and config volumes; verify the file is still valid JSON (`jq . .devcontainer/devcontainer.json`) and that `runArgs`, `waitFor`, and `postStartCommand` are byte-for-byte unchanged.
- [x] 1.2 Confirm no Dockerfile change is needed: verify `/home/node/.npm` is created `node:node` by the `USER node` global installs, so the seeded volume comes up node-owned without an explicit `mkdir`/`chown`.

## 2. Assert the new capability in verify.sh

- [x] 2.1 Add a `section "npm cache must be writable and executable"` to `.devcontainer/verify.sh`, in the unprivileged main body next to the other non-root checks — not in `check_iptables`/`--iptables-only`, since none of it needs root. Open it with a comment block explaining *why* the exec probe exists (`/tmp` is `noexec`, so writability alone is not sufficient for `npx`), matching the file's existing comment density.
- [x] 2.2 Resolve the cache directory with `npm config get cache` rather than hardcoding `/home/node/.npm`, per the design decision to detect base-image drift instead of pinning it; `bad` if the command fails or returns an empty or non-existent path.
- [x] 2.3 Assert the cache directory is writable — create a temp file inside it, `bad` on failure, and remove it — verifying a manual run reports PASS.
- [x] 2.4 Assert the cache directory is exec-capable — write a trivial script there, `chmod +x`, run it, and `bad` unless it executes (a `noexec` mount fails with exit 126). Clean up the file whether or not the check passes, and verify the probe leaves no residue in `_cacache`.
- [x] 2.5 Add a `section` asserting the rootfs is still read-only: writes to `/usr/local/bin/`, `/usr/local/etc/allowed-domains.txt`, and the global `node_modules` directory containing the `claude` binary must each fail; `bad` if any succeeds, and remove anything a write unexpectedly created. Verify by confirming all three report PASS on an unmodified container.
- [x] 2.6 Confirm both new sections use `bad` (not `warn`), so a regression blocks launch, and verify the summary's failed-check list renders their names correctly by temporarily forcing one to fail.

## 3. Update documentation

- [x] 3.1 Update `CLAUDE.md`: add `/home/node/.npm` to the list of writable paths in "Working from inside the sandbox", and describe the npm cache volume in the `devcontainer.json` bullet of the architecture section; verify the writable-path list matches the container's actual mount table.
- [x] 3.2 Add a short note (`CLAUDE.md` or `README.md`) that the npm cache volume grows unbounded and is reclaimed with `npm cache clean --force` or by removing the `claude-code-npm-*` volume on the host.

## 4. Host-side verification (user runs these; not possible from inside the container)

- [x] 4.1 Rebuild on the host: `devcontainer up --workspace-folder "$PWD" --config "$SBX" --remove-existing-container`; verify the launch completes, which given `waitFor: postStartCommand` means `verify.sh` passed.
- [x] 4.2 Run `verify.sh` inside the new container and confirm it prints `VERIFIED` with the new npm-cache and read-only-rootfs checks all showing PASS.
- [x] 4.3 Confirm the fix: `npx prettier --check README.md` completes and prints prettier's formatting verdict with no `EROFS` error.
- [x] 4.4 Confirm the cache came up warm: `du -sh "$(npm config get cache)/_cacache"` shows the image's baked content (~123 MB) rather than an empty directory.
- [x] 4.5 Confirm persistence: restart the container and verify a package fetched before the restart is still cached and is served from cache.
- [x] 4.6 Confirm no egress regression: `verify.sh`'s existing `example.com` and `git push` checks still FAIL-as-expected (i.e. still report PASS), and `git diff` shows `allowed-domains.txt`, `init-firewall.sh`, and `runArgs` untouched by this change.
