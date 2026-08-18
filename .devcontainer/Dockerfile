FROM node:24-trixie-slim

ARG CLAUDE_CODE_VERSION=latest

# Install basic development tools and iptables/ipset
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

# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default editor and visual
ENV EDITOR=vim
ENV VISUAL=vim

# Install Claude
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Copy and set up scripts
COPY init-firewall.sh /usr/local/bin/
COPY verify.sh /usr/local/bin/
COPY allowed-domains.txt /usr/local/etc/
USER root
RUN echo 'export PATH="$PATH:/usr/local/share/npm-global/bin"' \
      > /etc/profile.d/npm-global-path.sh && \
    chmod 0644 /etc/profile.d/npm-global-path.sh && \
    chmod 0644 /usr/local/etc/allowed-domains.txt && \
    chmod +x /usr/local/bin/init-firewall.sh && \
    chmod +x /usr/local/bin/verify.sh && \
    echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
    echo "node ALL=(root) NOPASSWD: /usr/local/bin/verify.sh" > /etc/sudoers.d/verify && \
    chmod 0440 /etc/sudoers.d/node-firewall && \
    chmod 0440 /etc/sudoers.d/verify
USER node
