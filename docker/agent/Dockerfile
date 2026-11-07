# Image shared by every agent container.
# Pin versions: every agent should run the same tools during an experiment.
FROM node:24-bookworm-slim

ARG USER_UID=1000
ARG USER_GID=1000
# Pin CLAUDE_CODE_VERSION to a specific release rather than latest.
ARG CLAUDE_CODE_VERSION=latest
ARG LEAN_TOOLCHAIN=leanprover/lean4:v4.35.0
ARG LASM_VERSION=0.3.5

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq less procps tmux python3 python3-pip \
 && rm -rf /var/lib/apt/lists/*

# lean-lsp-mcp, the Lean tools CLAUDE.md tells agents to verify with.
RUN pip install --no-cache-dir --break-system-packages lean-lsp-mcp

# GitHub CLI, from GitHub's apt repository.
RUN mkdir -p -m 755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Claude Code and Lasm (check Lasm's README for any further prerequisites).
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
                   "@lasm/cli@${LASM_VERSION}"

# Non-root user whose UID/GID match the host user that owns secrets/.
# -o allows IDs already used in the base image (e.g. macOS's GID 20).
RUN userdel -r node \
 && groupadd -o -g "${USER_GID}" agent \
 && useradd -o -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash agent \
 && mkdir -p /home/agent/.claude /workspace /etc/claude-code \
 && chown -R agent:agent /home/agent /workspace

# Policy and helpers the agent cannot edit.
COPY managed-settings.json PROTOCOL.md /etc/claude-code/
COPY gitconfig /etc/gitconfig
COPY check-inbox.sh git-credential-agent gh-agent agent-init /usr/local/bin/
RUN chmod 0644 /etc/claude-code/* /etc/gitconfig \
 && chmod 0755 /usr/local/bin/check-inbox.sh /usr/local/bin/git-credential-agent \
               /usr/local/bin/gh-agent /usr/local/bin/agent-init \
 && ln -s /usr/local/bin/gh-agent /usr/local/bin/gh

USER agent
WORKDIR /home/agent

# elan and the toolchain Lasm requires are installed by agent-init, into the
# elan-shared volume mounted over ~/.elan: a RUN layer here would be hidden by
# the volume as soon as it was mounted. The directory exists only so that a
# volume created from this image is owned by agent rather than root.
RUN mkdir -p /home/agent/.elan

ENV PATH=/home/agent/.elan/bin:/usr/local/bin:${PATH} \
    CLAUDE_CONFIG_DIR=/home/agent/.claude \
    LEAN_TOOLCHAIN=${LEAN_TOOLCHAIN}
