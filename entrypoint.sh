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

# Fix ownership of the home directory itself (not recursively into mounted volumes)
chown coder:$(id -g coder) /home/coder
chown -R coder:$(id -g coder) /home/coder/.claude 2>/dev/null || true
chown -R coder:$(id -g coder) /home/coder/.config 2>/dev/null || true
chown coder:$(id -g coder) /home/coder/workspace 2>/dev/null || true

# Run the actual command as the coder user
# Note: the SSH agent socket (if mounted) is already accessible because
# the coder user's UID has been remapped to match the host user who owns it.
exec gosu coder "$@"
