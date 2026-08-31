## Why

Every npm operation that needs to fetch a package fails inside the sandbox. `npx prettier --check` — and equally `npm install`, `npm ci`, any `npx <tool>` — dies with `EROFS` because npm's cache directory `/home/node/.npm` sits on the rootfs, which `devcontainer.json` mounts `--read-only`. The container can reach `registry.npmjs.org` (it is whitelisted); it simply cannot write what it downloads:

```
npm error code EROFS
npm error rofs Invalid response body while trying to fetch https://registry.npmjs.org/prettier:
  EROFS: read-only file system, open '/home/node/.npm/_cacache/tmp/...'
```

This makes the sandbox unable to run the ordinary JavaScript tooling a project under `/workspace` needs, which is the point of the sandbox. The fix must not widen what the container can reach or do — the read-only rootfs, the egress whitelist, and the no-`git push` guarantee all stay exactly as they are.

## What Changes

- Mount a per-container named volume `claude-code-npm-${devcontainerId}` at `/home/node/.npm`, so npm's cache directory is writable. This follows the pattern `devcontainer.json` already uses for `/commandhistory` and `/home/node/.claude`.
- The volume is **exec-capable**, which the existing `/tmp` tmpfs is not. This is load-bearing, not incidental: `/tmp` is mounted `noexec`, so pointing `npm_config_cache` at `/tmp` does *not* fix the problem — `npx` stages the package under `_npx/<hash>/node_modules/` and executes its bin, which fails with exit 126 `Permission denied`. Any fix that relocates the cache into `/tmp` is a non-fix.
- Because Docker seeds a new empty named volume from the image's content at that path, the volume starts warm with the ~123 MB cache already baked in by the Dockerfile's global installs, rather than empty.
- Add assertions to `verify.sh` covering the new grant, per the repo's rule that every capability granted comes with a check: the npm cache is writable, it is exec-capable, and — the security-relevant half — the rootfs outside the sanctioned writable paths is *still* read-only.
- No change to `allowed-domains.txt`, `init-firewall.sh`, the `runArgs` capability set, or `waitFor`.

### Explicitly not changed

The sandbox's security contract is unchanged, and this is the claim `verify.sh` will keep enforcing:

- **Egress**: no domain is added. `registry.npmjs.org` was already whitelisted for Claude Code self-update, so package fetches already had reach; only the write to disk was failing.
- **Rootfs**: `--read-only` stays. The writable surface grows by exactly one directory that npm alone owns — it does not become writable anywhere that a script, binary, or config on `PATH` is read from. `/usr/local/bin/` (the firewall and verify scripts), `/usr/local/etc/allowed-domains.txt`, and `/usr/local/share/npm-global/` (the `claude` binary itself) remain read-only.
- **git push**: untouched.
- **Capabilities**: no new `--cap-add`; `NET_ADMIN`/`NET_RAW` remain the only ones.

## Capabilities

### New Capabilities

- `npm-cache`: the sandbox's requirements for a writable, exec-capable npm cache — what must work (registry-fetching npm/npx commands), what must remain true alongside it (read-only rootfs outside sanctioned paths, unchanged egress policy), and the verification that enforces both at every container start.

### Modified Capabilities

None. `openspec/specs/` is empty, so there is no existing spec to delta.

## Impact

- `.devcontainer/devcontainer.json` — one added entry in `mounts`.
- `.devcontainer/verify.sh` — one new check section.
- `CLAUDE.md` — the architecture section enumerates the writable paths and the four-file security chain; both need the npm cache added.
- Requires a host-side rebuild (`devcontainer up --remove-existing-container`) to take effect. As documented in `CLAUDE.md`, none of this is verifiable from inside the container; the user must run it on the host.
- Consequence worth stating plainly: once the cache is writable, `npm install` and `npx <anything>` will fetch and execute arbitrary code from the registry. That capability is not new in kind — the agent already runs arbitrary commands and can already write and execute code in `/workspace` — and it stays inside the same firewall and the same read-only rootfs. It is a deliberate part of the change, not a side effect.
