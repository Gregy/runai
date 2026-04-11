#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="claude-code"
CONTAINER_NAME="claude-code-$(date +%s)"
WORKSPACE="${1:-.}"  # Default to current directory; first arg is workspace path
shift 2>/dev/null || true  # Remaining args passed to claude

# ── Build the image ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "🔨 Building Claude Code Docker image..."
docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"

# ── Prepare persistent config directory ──────────────────────────
# OAuth tokens are stored in ~/.claude. We persist this on the host
# so you only need to log in once across container restarts.
CLAUDE_CONFIG_DIR="${HOME}/.claude-code-docker"
CLAUDE_CONFIG_JSON="${HOME}/.claude-code-docker.json"
mkdir -p "$CLAUDE_CONFIG_DIR"
touch "$CLAUDE_CONFIG_JSON"

ABSOLUTE_WORKSPACE="$(cd "$WORKSPACE" && pwd)"

echo "📂 Mounting workspace: $ABSOLUTE_WORKSPACE"
echo "🔑 OAuth credentials stored in: $CLAUDE_CONFIG_DIR"
echo "🆔 Running as UID=$(id -u) GID=$(id -g)"
echo "🚀 Starting Claude Code..."
echo ""
echo "   On first run you'll be prompted to authenticate via browser."
echo "   Credentials are persisted so you won't need to log in again."
echo ""

# --security-opt label=disable: disables SELinux confinement for this container
#   instead of relabeling host files with :Z (which is dangerous on broad paths)
# --network host: required so the OAuth callback can reach the container
docker run -it --rm \
    --name "$CONTAINER_NAME" \
    --network host \
    --security-opt label=disable \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -v "$ABSOLUTE_WORKSPACE":/home/coder/workspace \
    -v "$CLAUDE_CONFIG_DIR":/home/coder/.claude \
    -v "$CLAUDE_CONFIG_JSON":/home/coder/.claude.json \
    "$IMAGE_NAME" claude \
    --allowedTools "Bash(*),Read,Edit,Write,Glob,Grep,WebFetch,WebSearch,NotebookEdit,Agent" \
    --disallowedTools "Bash(tsh*)" \
    "$@"
