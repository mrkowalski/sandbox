# Claude Code headless sandbox

## What is it?

It is a sandbox Docker dev container that restricts Claude Code's access to the current folder and applies firewall whitelisting.

It is loosely based on https://github.com/anthropics/claude-code/tree/main/.devcontainer

## Running

- `devcontainer up --workspace-folder . --remove-existing-container`
- `devcontainer exec --workspace-folder . claude --dangerously-skip-permissions`
