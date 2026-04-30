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
    openssh-client \
    unzip \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --break-system-packages pre-commit

# Install AWS CLI v2
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# Install kubectl
RUN curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

# Install kustomize
RUN curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash \
    && mv kustomize /usr/local/bin/kustomize

# Install Terraform
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com bookworm main" \
        > /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update && apt-get install -y terraform \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (gh)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install GitLab CLI (glab) — official .deb from GitLab releases
# https://gitlab.com/gitlab-org/cli/-/releases
ARG GLAB_VERSION=1.93.0
RUN curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_amd64.deb" \
        -o /tmp/glab.deb \
    && apt-get update && apt-get install -y /tmp/glab.deb \
    && rm -f /tmp/glab.deb \
    && rm -rf /var/lib/apt/lists/*

# Install Teleport tsh client (binary provided in build context)
COPY tsh-linux-amd64 /usr/local/bin/tsh
RUN chmod +x /usr/local/bin/tsh

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
COPY host-browser /usr/local/bin/host-browser
RUN chmod +x /entrypoint.sh /usr/local/bin/host-browser \
    && ln -s /usr/local/bin/host-browser /usr/local/bin/xdg-open \
    && chown coder:coder /home/coder/CLAUDE.md

# Route URL-opening tools (gh, gcloud, aws sso, claude, ...) through the
# host-side opener daemon started by run.sh.
ENV BROWSER=/usr/local/bin/host-browser

WORKDIR /home/coder/workspace

ENTRYPOINT ["/entrypoint.sh"]
CMD ["claude"]
