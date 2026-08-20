# Dockerfile for Claude Code (OAuth / Subscription login)
# Node 22+ required by pi 0.75+.
FROM node:22-trixie

# Install useful dev tools and dependencies.
# The python3-{requests,cryptography,pypdf} packages are for the expense
# submission script.
RUN apt-get update && apt-get install -y \
    git \
    git-lfs \
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
    postgresql-client \
    unzip \
    bc \
    python3-requests \
    python3-cryptography \
    python3-pypdf \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --break-system-packages pre-commit \
    && git lfs install --system --skip-repo

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

# Install Flux GitOps toolkit CLI (flux) — official upstream install script
# https://fluxcd.io/flux/installation/
ARG FLUX_VERSION=2.9.2
RUN curl -fsSL https://fluxcd.io/install.sh \
        | FLUX_VERSION=${FLUX_VERSION} bash

# Install Terraform
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com trixie main" \
        > /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update && apt-get install -y terraform \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI (client only; daemon comes from the host via socket bind mount)
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin \
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

# Install Grafana Cloud CLI (gcx) — official upstream install script
# https://github.com/grafana/gcx/blob/main/docs/installation.md
ARG GCX_VERSION=0.2.11
RUN curl -fsSL https://raw.githubusercontent.com/grafana/gcx/main/scripts/install.sh \
        | INSTALL_DIR=/usr/local/bin VERSION=${GCX_VERSION} sh

# Install Teleport tsh client (binary provided in build context)
COPY tsh-linux-amd64 /usr/local/bin/tsh
RUN chmod +x /usr/local/bin/tsh

# Install uv / uvx (fast Python package & project manager).
# System python3 (from Debian Trixie) is already 3.13, so uv will use it.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Remove the default 'node' user (UID 1000) that ships with the node image
# so it doesn't conflict with UID remapping at runtime
RUN userdel -r node

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Install pi (https://pi.dev) coding agent
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent

# Create the coder user — UID/GID will be remapped at runtime
RUN useradd -m -s /bin/bash coder \
    && echo "coder:abrakadabra" | chpasswd \
    && usermod -aG sudo coder

# Optionally pre-configure glab for a self-hosted GitLab and make it the default
# host. Both values come from the untracked local.env via run.sh (see README);
# without them this step is skipped. Only the OAuth application client_id is
# baked in — no credentials. Log in from inside the container with (opens a
# browser via host-browser):
#   glab auth login --hostname <GLAB_HOST> --web
ARG GLAB_HOST=
ARG GLAB_CLIENT_ID=
RUN if [ -n "$GLAB_HOST" ] && [ -n "$GLAB_CLIENT_ID" ]; then \
        export GLAB_CONFIG_DIR=/home/coder/.config/glab-cli \
        && glab config set client_id "$GLAB_CLIENT_ID" -g --host "$GLAB_HOST" \
        && glab config set host "$GLAB_HOST" -g; \
    fi \
    && mkdir -p /home/coder/.config \
    && chown -R coder:coder /home/coder/.config

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
