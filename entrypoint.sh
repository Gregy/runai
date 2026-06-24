#!/bin/bash
set -e

# Default to UID/GID 1000 if not provided
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Get current UID/GID of the coder user
CURRENT_UID=$(id -u coder)
CURRENT_GID=$(id -g coder)

# Remap GID if needed
if [ "$HOST_GID" != "$CURRENT_GID" ]; then
    # Check if a group with this GID already exists
    if getent group "$HOST_GID" > /dev/null 2>&1; then
        EXISTING_GROUP=$(getent group "$HOST_GID" | cut -d: -f1)
        usermod -g "$EXISTING_GROUP" coder
    else
        groupmod -g "$HOST_GID" coder
    fi
fi

# Remap UID if needed
if [ "$HOST_UID" != "$CURRENT_UID" ]; then
    usermod -u "$HOST_UID" coder
fi

# If the Docker socket is bind-mounted, ensure the coder user can access it
# by adding it to a group matching the socket's GID.
if [ -S /var/run/docker.sock ]; then
    DOCKER_SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
    if [ "$DOCKER_SOCK_GID" != "0" ]; then
        if getent group "$DOCKER_SOCK_GID" > /dev/null 2>&1; then
            DOCKER_GROUP=$(getent group "$DOCKER_SOCK_GID" | cut -d: -f1)
        else
            DOCKER_GROUP=docker-host
            groupadd -g "$DOCKER_SOCK_GID" "$DOCKER_GROUP"
        fi
        usermod -aG "$DOCKER_GROUP" coder
    fi
fi

# Fix ownership of the home directory itself (not recursively into mounted volumes)
chown coder:$(id -g coder) /home/coder
chown -R coder:$(id -g coder) /home/coder/.claude 2>/dev/null || true
chown -R coder:$(id -g coder) /home/coder/.pi 2>/dev/null || true
chown -R coder:$(id -g coder) /home/coder/.config 2>/dev/null || true
chown coder:$(id -g coder) /home/coder/workspace 2>/dev/null || true

# Run the actual command as the coder user
# Note: the SSH agent socket (if mounted) is already accessible because
# the coder user's UID has been remapped to match the host user who owns it.
exec gosu coder "$@"
