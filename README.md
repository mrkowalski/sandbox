# Claude Code headless sandbox

## What is it?

It is a sandbox Docker dev container that restricts Claude Code's access to the current folder and applies firewall whitelisting.

It is loosely based on https://github.com/anthropics/claude-code/tree/main/.devcontainer

It is a headless sandbox; it contains no human-facing features. It only restricts what Claude Code can do and and makes cost the only risk of the `--dangerously-skip-permissions` flag.

### Crucially:

- it does not allow `git push`
- it mounts the container fs as readonly except for volumes and tmps

## Running

### Install devcontainers

`npm install -g @devcontainers/cli`

### Clone the repo into a tools folder

`git clone https://github.com/mrkowalski/sandbox ~/tools/sandbox`

### Put into your `.bashrc`:

```bash
# ~/.bashrc
SBX=~/tools/sandbox/.devcontainer/devcontainer.json
sbx-up()   { devcontainer up --workspace-folder "$PWD" --config "$SBX" --remove-existing-container; }
sbx-claude(){ devcontainer exec --workspace-folder "$PWD" --config "$SBX" claude --dangerously-skip-permissions; }
```

### Start the dev container

`devcontainer up --workspace-folder . --remove-existing-container`

### Run Claude Code inside the dev container

`devcontainer exec --workspace-folder . claude --dangerously-skip-permissions`
