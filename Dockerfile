# Dockerfile for Claude Code (OAuth / Subscription login)
FROM node:20-bookworm

# Install useful dev tools and dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    wget \
    vim \
    ripgrep \
    fd-find \
    jq \
    gosu \
    sudo \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --break-system-packages pre-commit

# Remove the default 'node' user (UID 1000) that ships with the node image
# so it doesn't conflict with UID remapping at runtime
RUN userdel -r node

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Create the coder user — UID/GID will be remapped at runtime
RUN useradd -m -s /bin/bash coder \
    && echo "coder:abrakadabra" | chpasswd \
    && usermod -aG sudo coder

COPY entrypoint.sh /entrypoint.sh
COPY CLAUDE.md /home/coder/CLAUDE.md
RUN chmod +x /entrypoint.sh \
    && chown coder:coder /home/coder/CLAUDE.md

WORKDIR /home/coder/workspace

ENTRYPOINT ["/entrypoint.sh"]
CMD ["claude"]
