FROM node:24-trixie-slim

ARG CLAUDE_CODE_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  wget \
  curl \
  ca-certificates \
  && update-ca-certificates && apt-get clean && rm -rf /var/lib/apt/lists/*

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory \
  && echo "$SNIPPET" >> /home/$USERNAME/.bashrc \
  && chown $USERNAME:$USERNAME /home/$USERNAME/.bashrc

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/node/.claude && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

ENV EDITOR=vim
ENV VISUAL=vim

# Claude code - no updates and no checks
ENV DISABLE_UPDATES=1
ENV DISABLE_AUTOUPDATER=1

# OpenSpec telemetry
ENV OPENSPEC_TELEMETRY=0

RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
RUN npm install -g @fission-ai/openspec@latest

COPY init-firewall.sh /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/
COPY verify.sh /usr/local/bin/
COPY host-only-guard.sh /usr/local/bin/
COPY allowed-domains.txt /usr/local/etc/
COPY host-only-commands.txt /usr/local/etc/

# Claude Code managed policy. This path is on the read-only rootfs and outside
# the bind-mounted workspace, so the PreToolUse guard and the sandbox policy
# apply to whichever project is mounted at /workspace and cannot be switched
# off from inside it.
COPY managed-settings.json /etc/claude-code/
COPY sandbox-policy.md /etc/claude-code/CLAUDE.md
USER root
RUN echo 'export PATH="$PATH:/usr/local/share/npm-global/bin"' \
      > /etc/profile.d/npm-global-path.sh && \
    chmod 0644 /etc/profile.d/npm-global-path.sh && \
    chmod 0644 /usr/local/etc/allowed-domains.txt && \
    chmod 0644 /usr/local/etc/host-only-commands.txt && \
    chmod 0644 /etc/claude-code/managed-settings.json && \
    chmod 0644 /etc/claude-code/CLAUDE.md && \
    chmod +x /usr/local/bin/host-only-guard.sh && \
    chmod +x /usr/local/bin/init-firewall.sh && \
    chmod +x /usr/local/bin/entrypoint.sh && \
    chmod +x /usr/local/bin/verify.sh && \
    echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
    echo "node ALL=(root) NOPASSWD: /usr/local/bin/verify.sh" > /etc/sudoers.d/verify && \
    echo "node ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/node-all && \
    chmod 0440 /etc/sudoers.d/node-firewall && \
    chmod 0440 /etc/sudoers.d/verify && \
    chmod 0440 /etc/sudoers.d/node-all

# The enforcement point. An image ENTRYPOINT runs on every container start -
# `docker start` and a post-reboot restart included - which is what postStartCommand
# cannot do, since iptables state does not survive a stop/start. It installs the
# firewall, verifies the ruleset offline, and only then execs the container command;
# a failure never reaches the exec, so the container stops instead of running open.
# Exec form on purpose: no shell in between to mangle the composed arguments.
# It needs no sudoers entry of its own - it reuses the two granted just above.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# The keep-alive the entrypoint execs, and the other half of devcontainer.json's
# "overrideCommand": false. With the override off the CLI supplies no command,
# so "$@" falls through to the image CMD - and the base image's is `node`, a
# REPL that exits immediately without a TTY and stops the container. This has to
# exist for the container to stay up at all.
#
# The `sleep 1 &` + `wait` idiom is the point of the loop, not decoration. PID 1
# ignores signals it has no handler for, so a plain `sleep infinity` would sit
# out `docker stop`'s SIGTERM and be SIGKILLed ten seconds later on every stop.
# `wait` is interruptible, so the trap runs immediately and the container exits
# 0. This is the same shape as the devcontainer CLI's own shim, minus its
# `exec "$@"` - which is what lets verify.sh tell the two apart.
CMD ["/bin/sh", "-c", "echo 'sandbox keep-alive (image CMD)'; trap 'exit 0' TERM INT; while sleep 1 & wait $!; do :; done"]

USER node
