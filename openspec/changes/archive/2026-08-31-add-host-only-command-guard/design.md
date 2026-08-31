## Context

See `proposal.md` — Why. The constraints that shape the approach:

- The container runs Claude Code with `--dangerously-skip-permissions`, so anything built on the interactive permission system (an `ask` or `deny` permission rule) is unreliable here by construction. Enforcement has to sit somewhere that a bypassed permission mode does not switch off.
- The rootfs is read-only outside `/workspace`, `/tmp`, `/commandhistory`, and `/home/node/.claude`. Anything baked into the image is tamper-proof from inside a session; anything under `/workspace` is not, and `/home/node/.claude` is a per-container named volume whose contents are not guaranteed to match the image.
- The sandbox is used against arbitrary host projects bind-mounted at `/workspace`. A rule that lives in the mounted project reaches only that project.
- `verify.sh` runs as part of `postStartCommand` with `waitFor: postStartCommand`, so any assertion added there is a launch gate. `bad` fails the launch; `warn` does not.
- No new packages: the image already has `jq`, `grep`, `sed`, and bash.

## Goals / Non-Goals

**Goals:**

- One place — a text file that reads like `allowed-domains.txt` — where a command is declared unrunnable, with the host-side remedy stored next to the pattern so the message the user gets is written by whoever added the entry.
- Enforcement that holds under `--dangerously-skip-permissions` and cannot be turned off from the mounted workspace.
- The blocked-command message reaches the agent as text it is instructed to relay, so the user gets the host command whether the agent anticipated the block or ran into it.
- An escape hatch that does not require a rebuild.

**Non-Goals:**

- Not a containment mechanism. The firewall and the read-only rootfs are what contain the agent; a listed command is still blocked at the network layer if the guard never runs. The guard exists so the agent knows and says what is impossible. Nothing in this design should be read as a security control, and the guard's failure modes are judged as ergonomics failures, not as breaches.
- Not a general command policy engine. No allow-lists, no per-project rules, no severity levels — one list, one outcome.
- Not a credential bridge. Making host credentials reachable from inside the sandbox is the opposite of what this repo is for.
- Not attempting to catch every possible spelling of a command. Evasion is not the threat model; the agent is cooperative, and the instruction file is what makes it cooperative.

## Decisions

### D1: A `PreToolUse` hook, not a permission rule and not a `PATH` shim

**Chosen**: a hook script matched to the `Bash` tool, wired through Claude Code settings baked into the image.

- *Permission `deny` rules* were rejected because the container's whole point is running with permission prompts skipped; a mechanism that the launch flag disables is not a mechanism. Hooks are evaluated independently of permission mode.
- *A `PATH` shim* (a fake `wrangler` earlier on `PATH`) was rejected on three counts: it only catches commands invoked by that exact name, so `npx wrangler` slips past unless every runner is shimmed too; it makes the block look like a broken install rather than a deliberate policy; and it cannot see the command string the agent actually submitted, which is what the message should quote back.

The hook blocks by **exiting 2 with the message on stderr** — the oldest and most broadly supported `PreToolUse` blocking contract, where stderr is fed back to the model. A structured JSON `permissionDecision: "deny"` with a `permissionDecisionReason` is the nicer-looking alternative, but exit 2 is chosen as the primary because it is the least version-dependent. The very first implementation task is to confirm empirically which of the two the installed Claude Code honours under `--dangerously-skip-permissions`, and the hook emits whichever works; the rest of the design is unaffected either way.

**Resolved (task 7.3, on the host).** Exit 2 with the message on stderr blocks the command and surfaces the message to the agent under `--dangerously-skip-permissions`. The guard ships that form; the JSON alternative was never needed.

### D2: Settings baked into the image, at a path outside the mounted workspace

The hook is wired through a Claude Code settings file written into the image under the read-only rootfs. `/workspace/.claude/settings.json` is unusable — it belongs to whatever host project is mounted, would have to be added to every project, and could be edited by the agent. `/home/node/.claude/settings.json` is a named volume that shadows whatever the image put there, so it is unreliable as a delivery path.

Which exact path the installed Claude Code reads for image-level, workspace-independent settings is the second thing the implementation confirms before anything else is built. The enterprise/managed-settings location is the intended target. If none is honoured, the fallback is to pass the hook configuration through the launcher's `claude` invocation instead — a README change rather than an image change — and the specs still hold.

**Resolved (tasks 7.3 and 7.4, on the host).** `/etc/claude-code/managed-settings.json` is honoured: the hook fires against a project carrying no `.claude/` of its own, and a mounted project cannot switch it off. The launcher fallback stays unused.

### D3: The list format — pattern plus remedy on one line

Following `allowed-domains.txt`: comments with `#`, blank lines ignored, one entry per line, installed to `/usr/local/etc/`. An entry is a POSIX ERE matched against the full submitted command string, followed by a separator and the human text:

```
wrangler[[:space:]]+login  ::  Cloudflare auth writes credentials to the host's home directory, which is not mounted here. Run this on the host: npx wrangler login
```

Matching the whole command string, rather than an argv[0], is what makes `npx wrangler login` and `cd app && npx wrangler deploy` both match with one pattern. Storing the remedy beside the pattern means the person who adds an entry writes the sentence the user will read — the guard never has to invent one.

Seeded with the account-touching `wrangler` subcommands (`login`, `logout`, `whoami`, `deploy`, `publish`, `versions`, `secret`, `d1`, `kv`, `r2`, `tail`) and nothing else, per the decision to grow the list on demand. Local-only subcommands such as `wrangler types` and `wrangler dev` deliberately stay unlisted.

An unreadable or unparseable list is a hard failure, not a fail-open: consistent with `init-firewall.sh` aborting on an unresolvable domain. The guard exits with an error the agent sees, and `verify.sh` fails the launch.

### D4: A single-invocation environment-prefix bypass

`HOST_ONLY_GUARD_BYPASS=1 npx wrangler deploy` runs. The guard recognises the prefix in the submitted command string, lets it through, and says on stderr that the guard was bypassed.

The alternative — no bypass at all — was rejected because the rootfs is read-only and the list lives in the image: an over-broad pattern would otherwise mean a host-side rebuild before the user could get unstuck, and that is a bad trade for a mechanism that is not a security control. Because it is part of the command string it applies to exactly one invocation and cannot leak into later ones.

### D5: Instructions delivered as a container-global memory file

The behavioural half — anticipate, announce, quote the command, do not retry — is delivered as an instruction file baked into the image at the path Claude Code loads for every session independent of the workspace. Same reasoning as D2: it must survive an arbitrary mounted project, which rules out a project `CLAUDE.md`, and must not depend on the `/home/node/.claude` volume's contents.

The file states the rule, points at `/usr/local/etc/host-only-commands.txt` as the authority, and gives the required shape of the handoff. It is deliberately short: a long policy document competes with the mounted project's own instructions.

**Resolved (task 7.2, on the host).** `/etc/claude-code/CLAUDE.md` is the path, and the agent acts on it: in an unrelated project it announced the host-only step unprompted. Note that this is behavioural evidence — the `/memory` listing task 1.3 called for was not inspected.

### D6: `verify.sh` treats guard failures as `bad`

Every assertion in the new section fails the launch. This is the repo's stated stance — a capability the container claims is checked at every start — and the checks are deterministic and fast. The cost is real: an over-broad entry that makes the ordinary-command probe fail will block every container from starting. That cost is accepted because the probes are exactly what would catch such an entry, and because D4's bypass means a user who hits it is not stuck.

The section runs four assertions: files installed and parseable; settings reference the hook; the hook blocks a sample listed command; the hook passes an ordinary command. The last two invoke the hook script directly with a synthetic tool-input payload — they exercise the guard's logic without needing a live Claude Code session.

Whether the instruction file is actually *loaded into context* cannot be asserted from a shell script. `verify.sh` checks only that it is installed where it belongs. Confirming the agent reads it is a one-time manual check by the user, and is a task rather than an assertion — stated plainly rather than papered over.

## Risks / Trade-offs

- ~~**The hook's blocking contract may differ in the installed Claude Code version**~~ → **did not materialise.** Exit 2 plus stderr is honoured (D1, task 7.3). Originally planned to be resolved before anything is built: confirm exit-2-plus-stderr and the JSON form empirically, implement whichever the installed version honours, and record the finding in the script's header comment. This is the single assumption that would invalidate the approach.
- ~~**The image-level settings path may not be honoured**~~ → **did not materialise.** `/etc/claude-code/managed-settings.json` is read and cannot be disabled from the workspace (D2, tasks 7.3 and 7.4), so the fallback — moving the wiring into the launcher invocation in the README, delivered per-launch rather than per-image — was never needed.
- **An over-broad pattern blocks legitimate local work and, via the ordinary-command probe, can block launch** → the bypass (D4) unblocks the user immediately; the probe is what surfaces the bad entry rather than letting it rot.
- **The agent reasons around the block** — rewriting the command, base64-ing it, writing a script that calls it → not defended against, by design. The agent is cooperative and the instruction file tells it not to; the firewall is what actually stops the command from working. Guarding against a determined agent here would be theatre.
- **The list drifts out of date as tools change** → accepted. It is a text file the user edits when they hit a new case, exactly as `allowed-domains.txt` is.
- **This repo cannot test any of it** → per `CLAUDE.md`, none of this is verifiable from inside the container. Every task that changes `.devcontainer/` has to be exercised by the user on the host, and the tasks say so explicitly rather than implying the work was checked.

## Migration Plan

Additive; nothing existing changes behaviour. The change lands as a container rebuild — the user runs `devcontainer up --remove-existing-container` on the host and the new `verify.sh` section either passes or blocks the launch with a named failure. Rollback is reverting the commit and rebuilding; there is no persistent state to unwind, since the list, guard, settings, and instruction file all live in the image.

## Open Questions

- Whether to extend the list beyond `wrangler` in this change or in follow-ups. Deferred deliberately — the user chose to grow it on demand, and adding an entry is a one-line edit that needs no spec or design change.
