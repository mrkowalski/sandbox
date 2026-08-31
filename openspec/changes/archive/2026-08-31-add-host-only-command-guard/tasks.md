> **Note on verification.** Nothing under `.devcontainer/` can be exercised from
> inside the sandbox (see `CLAUDE.md` — "Working from inside the sandbox"). Every
> task below whose verification needs a running container is marked **[host]** and
> must be run by the user on the host with
> `devcontainer up --workspace-folder "$PWD" --config "$SBX" --remove-existing-container`.
> Tasks not so marked are verifiable by reading or by running a script directly.

## 1. Resolve the two blocking unknowns before building anything

- [x] 1.1 **[host]** Determine how a `PreToolUse` hook blocks a `Bash` call in the installed Claude Code version when running with `--dangerously-skip-permissions`. Write a throwaway hook that unconditionally refuses, try both the exit-2-with-stderr form and the JSON `permissionDecision: "deny"` form, and verify by observing which one actually prevents the command from running *and* surfaces its message to the agent. Record the answer — it determines what `host-only-guard.sh` emits (design D1). *(cannot be run from inside the container)* **Answered by the host run, not by the throwaway hook described:** task 7.3 showed that exit 2 with the message on stderr does block the command and does surface the message to the agent under `--dangerously-skip-permissions`. The JSON `permissionDecision` form was never tried, because the primary worked.
- [x] 1.2 **[host]** Determine which settings path the installed Claude Code reads for hook configuration that is independent of the mounted workspace and survives the `/home/node/.claude` volume. Verify by placing a trivial hook there, starting a session against a project that has no `.claude/` of its own, and confirming the hook fires (design D2). *(cannot be run from inside the container)* **Answered by the host run:** `/etc/claude-code/managed-settings.json` is honoured — tasks 7.3 and 7.4 fired the hook against a project with no `.claude/` of its own, and then against one actively trying to disable it. D2's fallback is not needed.
- [x] 1.3 **[host]** Determine which instruction-file path is loaded into every session regardless of the mounted project. Verify by placing a file with a distinctive sentence there and confirming it appears in a session's loaded memory (`/memory`) against an unrelated project (design D5). *(cannot be run from inside the container)* **Answered behaviourally, not as written:** the `/memory` listing was not inspected. `/etc/claude-code/CLAUDE.md` is taken as loaded because in task 7.2 the agent announced the host-only step unprompted in an unrelated project, which it could not do without the instructions.
- [x] 1.4 If 1.2 or 1.3 finds no workspace-independent path, switch to the design's fallback — wiring the hook and instructions through the launcher's `claude` invocation — and note the deviation in `design.md` before continuing. Verify by confirming the recorded decision matches what the rest of the tasks build. *(depends on 1.2 and 1.3)* **Not applicable** — both 1.2 and 1.3 found a workspace-independent path, so there is no deviation to record and the launcher fallback stays unused.

## 2. The list

- [x] 2.1 Write `.devcontainer/host-only-commands.txt` in the shape of `allowed-domains.txt`: a header comment explaining the file's role, that it is the only place a command is declared host-only, the `<ERE>  ::  <human text>` entry format, and that entries take effect on rebuild. Verify by reading it alongside `allowed-domains.txt` — the two should read as siblings.
- [x] 2.2 Seed the list with the account-touching `wrangler` subcommands only (`login`, `logout`, `whoami`, `deploy`, `publish`, `versions`, `secret`, `d1`, `kv`, `r2`, `tail`), each with a remedy sentence naming the exact host-side command. Verify each pattern matches its `npx`-prefixed form and none matches `wrangler dev` or `wrangler types` by running the patterns against a list of sample command strings with `grep -E`. **Done** — patterns exercised against ~40 command spellings; a first draft missed `wrangler --config x deploy` (flag with a separate value) and the pattern was widened.

## 3. The guard

- [x] 3.1 Write `.devcontainer/host-only-guard.sh` with the repo's script conventions — an opening comment block stating what it guarantees and how it is invoked, `set -euo pipefail`, and comments explaining *why* steps are ordered as they are. It reads the hook's tool-input payload from stdin, extracts the `Bash` command string with `jq`, and matches it against the list. Verify by running it directly with a synthetic payload on stdin.
- [x] 3.2 Make it block a matching command using whichever contract task 1.1 established, emitting the entry's remedy text verbatim plus a line stating the command must be run outside the sandbox. Verify by piping a payload containing `npx wrangler login` and checking both the exit status and the emitted message. **Done** — exit 2 with the remedy on stderr, the design's D1 primary. Confirmed on the host by task 7.3.
- [x] 3.3 Make it pass through anything that matches no entry, with no output. Verify by piping payloads for `ls -la`, `npm test`, and `wrangler types` and checking each exits 0 silently.
- [x] 3.4 Make an unreadable, missing, or unparseable list a hard failure that blocks the command rather than failing open. Verify by pointing the script at a nonexistent list and at a malformed line and confirming it refuses rather than permitting.
- [x] 3.5 Implement the `HOST_ONLY_GUARD_BYPASS=1` prefix: a matching command carrying the prefix is allowed through, with a note on stderr that the guard was bypassed. Verify by piping the same payload with and without the prefix and confirming the two outcomes differ, and that a following un-prefixed payload is still blocked.

## 4. Wiring into the image

- [x] 4.1 Add the settings file that registers the hook for the `Bash` tool at the path task 1.2 established. Verify by reading it back out of a built image. **Done** — written to `/etc/claude-code/managed-settings.json`, the design D2 target. Read back out of the built image by task 7.1: `verify.sh`'s host-only section asserts the file is installed and that it references the guard's installed path, and that section passed.
- [x] 4.2 Write the container-global instruction file: consult `/usr/local/etc/host-only-commands.txt` before proposing shell work, never attempt a listed command, state to the user that the command must be run outside the sandbox and why, quote it verbatim, do not retry or silently substitute a workaround, and finish the steps the sandbox *can* do while naming the ones left for the host. Keep it short — it competes with the mounted project's own instructions. Verify against the spec's "The agent tells the user what to run outside the sandbox" scenarios, one by one.
- [x] 4.3 Extend the `Dockerfile` to `COPY` the list to `/usr/local/etc/`, the guard to `/usr/local/bin/`, and the settings and instruction files to the paths from tasks 1.2 and 1.3, with the same explicit `chmod` treatment the existing scripts get. Verify **[host]** that all four exist with the expected modes in a freshly built image. **Done** — confirmed by task 7.1: the host-only section asserts all four files are installed and the guard is executable, and it passed in a freshly built image.

## 5. Verification section in `verify.sh`

- [x] 5.1 Add a `section` asserting the list, guard, settings, and instruction file are all installed, the guard is executable, and the settings actually reference the guard's installed path. Use `bad` (not `warn`) throughout — design D6. Verify by running `verify.sh` **[host]** in a container built with the files and again in one with a file deliberately removed. **Done** — exercised against working-tree copies via fixtures (correct build, and one fixture per failure mode: each of the four files missing, guard not executable, settings not wiring the guard, guard failing open, guard over-blocking, list malformed, list empty). Since run inside a built image by task 7.1, where the section passed.
- [x] 5.2 Assert the list parses: every non-comment, non-blank line has both a pattern and remedy text, and every pattern is a valid ERE. Verify by running against the real list and against a deliberately malformed copy.
- [x] 5.3 Add the two behavioural probes: invoke the installed guard with a synthetic payload for a known-listed command and assert it blocks; invoke it with an ordinary command and assert it passes. Verify **[host]** that both report PASS on a correct build, and that breaking the guard turns each into a FAIL. **Done** — same fixture run as 5.1; a fails-open guard and an over-blocking guard each produce named FAILs. Since run inside a built image by task 7.1.
- [x] 5.4 Confirm the new section respects the script's existing shape — it must work under the `--iptables-only` re-exec split without leaking into the child's `__VERIFY_COUNTS__` trailer, since these checks need no root. Verify by running `verify.sh` and `sudo verify.sh --iptables-only` **[host]** and checking the counts add up. **Done** — the `--iptables-only` branch exits at verify.sh:291, well before the section at :525; confirmed by running it and seeing no host-only output in the `__VERIFY_COUNTS__` trailer.

## 6. Documentation

- [x] 6.1 Add a `README.md` section: what the list is, that a blocked command is the sandbox working as designed, how to add an entry (edit one line, rebuild), and the bypass. Verify by following the written instructions to add a throwaway entry end to end.
- [x] 6.2 Extend `CLAUDE.md` — the architecture section gains the guard as a fifth file in the chain, and the "Working from inside the sandbox" section gains a line stating that a blocked host-only command is expected behaviour, not a bug to route around. Verify by reading: a fresh agent should be able to tell from `CLAUDE.md` alone why a command was blocked.

## 7. End-to-end confirmation

- [x] 7.1 **[host]** Rebuild and launch. Verify that `verify.sh` prints VERIFIED with the new section passing and the launch is not blocked. **Confirmed on the host.**
- [x] 7.2 **[host]** In a session mounted on an unrelated Cloudflare project, ask the agent to deploy. Verify it states up front that the deploy must be run outside the sandbox, quotes the command, and does not attempt it — the spec's "Host-only step reached during a task" scenario. **Confirmed on the host.**
- [x] 7.3 **[host]** In the same session, instruct the agent to run `npx wrangler login` directly. Verify the guard blocks it and the agent relays the remedy to the user rather than retrying or working around it — the spec's "The agent is stopped mid-attempt" scenario. **Confirmed on the host.**
- [x] 7.4 **[host]** Verify a mounted project's own `.claude/settings.json` cannot disable the hook, by adding one that tries and confirming enforcement survives — the spec's "Workspace content attempts to disable enforcement" scenario. **Confirmed on the host.**
- [x] 7.5 Record in the change's notes exactly which tasks were confirmed on the host and which were not, so the archived change does not imply verification that never happened. **Done** — the Verification record below.

## Verification record

Written for task 7.5, so the archived change states what was actually
exercised rather than implying more.

**Confirmed by the user on the host, 2026-08-31**, by rebuilding with
`devcontainer up --remove-existing-container` and driving a session:

- `verify.sh` prints VERIFIED with the host-only section passing and the
  launch is not blocked (7.1). That run is also the built-image evidence for
  4.1 (settings installed and referencing the guard), 4.3 (all four files
  installed, guard executable), and the in-image runs that 5.1, 5.3 and 5.4
  were waiting on — those three had until then been exercised only against
  working-tree copies via fixtures.
- The agent anticipates a host-only step in an unrelated Cloudflare project,
  states it must run outside the sandbox, quotes the command, and does not
  attempt it (7.2).
- A direct `npx wrangler login` is blocked by the guard, and the remedy
  reaches the agent, which relays it rather than retrying (7.3). This is the
  empirical answer to 1.1: **exit 2 with the message on stderr is honoured**
  under `--dangerously-skip-permissions`. The JSON `permissionDecision`
  alternative was never exercised.
- A mounted project's own `.claude/settings.json` cannot disable the hook
  (7.4). With 7.3 this answers 1.2: `/etc/claude-code/managed-settings.json`
  is read, is independent of the mounted workspace, and survives the
  `/home/node/.claude` volume. D2's launcher fallback stays unused.

**Confirmed indirectly, not as the task was written:**

- 1.3 asked for the instruction file to be seen in a session's loaded memory
  via `/memory`. That listing was not inspected. `/etc/claude-code/CLAUDE.md`
  is taken as loaded on the strength of 7.2, where the agent announced the
  host-only step unprompted in a project carrying no instructions of its own.
  The conclusion is sound; the stated check was not the one performed.

**Not applicable:**

- 1.4 — the fallback it describes was never triggered, because 1.2 and 1.3
  both found a workspace-independent path.

**Resting entirely on that host run:** every task marked **[host]**. Nothing
under `.devcontainer/` was exercised from inside the sandbox at any point,
per `CLAUDE.md`.
