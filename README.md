# Claude Code headless sandbox

## What is it?

It is a sandbox Docker dev container that restricts Claude Code's access to the current folder and applies firewall whitelisting.

It is loosely based on https://github.com/anthropics/claude-code/tree/main/.devcontainer

It is a headless sandbox; it contains no human-facing features. It restricts what Claude Code can do and makes cost the only risk of the `--dangerously-skip-permissions` flag.

### Crucially, it:

- does not allow `git push`
- mounts the container fs as readonly except for volumes and tmps
- disables outbound network traffic for everything except for entries in `.devcontainer/allowed-domains.txt`

## Running

### Install devcontainers

`npm install -g @devcontainers/cli`

### Clone the repo into a homedir folder (tools)

`git clone https://github.com/mrkowalski/sandbox ~/tools/sandbox`

### Put into your `.bashrc`:

```bash
# ~/.bashrc
SBX=~/tools/sandbox/.devcontainer/devcontainer.json
sbx-up()   { devcontainer up --workspace-folder "$PWD" --config "$SBX" --remove-existing-container; }
sbx-claude(){ devcontainer exec --workspace-folder "$PWD" --config "$SBX" claude --dangerously-skip-permissions; }
sbx-resume(){ devcontainer exec --workspace-folder "$PWD" --config "$SBX" claude --dangerously-skip-permissions --resume; }
```

## The firewall

The firewall is installed by the image entrypoint. 
It fails closed. If the firewall cannot be installed - most often a hostname in
`allowed-domains.txt` that will not resolve - the container stops instead of
starting, and `docker logs` says why.

A container that refuses to start is the sandbox declining to run unprotected,
not a fault. Fix the whitelist and start it again. If you need a shell inside
an image whose container will not start, bypass the entrypoint from the host:

```bash
docker run --rm -it --entrypoint /bin/bash <image>   # no firewall installed
```

## Commands that must run outside the sandbox

Some commands cannot work in here no matter what: they authenticate against, or
act on, an account whose credentials live in your home directory on the host,
over an API the firewall does not allow. `npx wrangler login` is the archetype
- and running it on the host does not help the container either, because the
credentials it writes stay on the host.

`.devcontainer/host-only-commands.txt` is the list of those commands. When
Claude Code hits one it says so and hands you the exact command to run in your
own terminal, instead of running it, failing, and guessing. If it tries anyway,
a guard blocks the command before it executes and gives it the same message.

To add one, add a line to that file and rebuild:

```
<pattern>  ::  <what the user should be told>
```

`<pattern>` is a POSIX ERE matched against the start of each command in the
line the agent submitted, after `npx`-style runners are stripped - so a pattern
reading `wrangler ... deploy` also catches `cd app && npx wrangler deploy`. The
file's header documents the format and the normalization in full.

If a pattern turns out to be too broad, you do not need a rebuild to get past
it - prefix the command with the bypass, which applies to that one invocation:

```bash
HOST_ONLY_GUARD_BYPASS=1 npx wrangler deploy
```

## Maintenance

Each container gets its own npm cache volume (`claude-code-npm-<devcontainerId>`) so that `npm install` and `npx` work against the read-only rootfs. npm never prunes that cache on its own, so it grows without bound. To reclaim the space, either run `npm cache clean --force` inside the container, or remove the volume from the host:

```bash
docker volume ls  | grep claude-code-npm     # find them
docker volume rm  <volume-name>              # container must be stopped
```
