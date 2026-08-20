#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="claude-code"
CONTAINER_NAME="claude-code-$(date +%s)"

# ── Parse flags ─────────────────────────────────────────────────
# Usage: run.sh [--ssh] [--aws] [--docker] [--bluetooth] [--pi] [workspace] [-- agent args...]
# Unknown flags (starting with -) are forwarded to the agent (claude or pi).
FORWARD_SSH=false
FORWARD_AWS=false
FORWARD_DOCKER=false
FORWARD_BLUETOOTH=false
PI_MODE=false
CLAUDE_ARGS=()
past_double_dash=false

for arg in "$@"; do
    if $past_double_dash; then
        CLAUDE_ARGS+=("$arg")
        continue
    fi
    case "$arg" in
        --ssh) FORWARD_SSH=true ;;
        --aws) FORWARD_AWS=true ;;
        --docker) FORWARD_DOCKER=true ;;
        --bluetooth) FORWARD_BLUETOOTH=true ;;
        --pi)  PI_MODE=true ;;
        --)   past_double_dash=true ;;
        -*)   CLAUDE_ARGS+=("$arg") ;;
        *)
            CLAUDE_ARGS+=("$arg")
            ;;
    esac
done

# pi uses AWS Bedrock as its backend, so AWS credentials must be forwarded.
if [ "$PI_MODE" = true ] && [ "$FORWARD_AWS" != true ]; then
    echo "❌ --pi requires --aws (pi uses AWS Bedrock as its backend)" >&2
    exit 1
fi

WORKSPACE="${WORKSPACE:-.}"  # Default to current directory

# ── Build the image ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The Teleport tsh client binary is required at build time (see Dockerfile).
# It is large and not tracked in git, so it must be downloaded separately.
if [ ! -f "$SCRIPT_DIR/tsh-linux-amd64" ]; then
    echo "⚠️  Missing tsh-linux-amd64 in $SCRIPT_DIR" >&2
    echo "⚠️  Download the Teleport tsh client (linux-amd64) and place it there as 'tsh-linux-amd64' before running." >&2
    echo "⚠️  Download our tsh version from https://gitlab.rossum.cloud/deployments/teleport/-/releases" >&2
    exit 1
fi

# Site-specific build settings (e.g. GLAB_HOST, GLAB_CLIENT_ID) live in the
# untracked local.env next to this script; see README.
GLAB_HOST=""
GLAB_CLIENT_ID=""
if [ -f "$SCRIPT_DIR/local.env" ]; then
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/local.env"
fi

echo "🔨 Building Claude Code Docker image..."
docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" \
    --build-arg GLAB_HOST="$GLAB_HOST" \
    --build-arg GLAB_CLIENT_ID="$GLAB_CLIENT_ID" \
    "$SCRIPT_DIR"

# ── Prepare persistent config directory ──────────────────────────
# OAuth tokens are stored in ~/.claude. We persist this on the host
# so you only need to log in once across container restarts.
CLAUDE_CONFIG_DIR="${HOME}/.claude-code-docker"
CLAUDE_CONFIG_JSON="${HOME}/.claude-code-docker.json"
mkdir -p "$CLAUDE_CONFIG_DIR"
touch "$CLAUDE_CONFIG_JSON"

# pi stores its settings and sessions in ~/.pi
PI_CONFIG_DIR="${HOME}/.pi-docker"
mkdir -p "$PI_CONFIG_DIR"

ABSOLUTE_WORKSPACE="$(cd "$WORKSPACE" && pwd)"

echo "📂 Mounting workspace: $ABSOLUTE_WORKSPACE"
echo "🔑 OAuth credentials stored in: $CLAUDE_CONFIG_DIR"
echo "🆔 Running as UID=$(id -u) GID=$(id -g)"

# ── AWS credentials forwarding ─────────────────────────────────
AWS_DOCKER_ARGS=()
AWS_TMPDIR=""
if [ "$FORWARD_AWS" = true ]; then
    AWS_CONFIG_DIR="${HOME}/.aws"
    if [ -d "$AWS_CONFIG_DIR" ]; then
        # Copy with dereferenced symlinks so links to host paths work inside the container
        AWS_TMPDIR=$(mktemp -d)
        cp -rL "$AWS_CONFIG_DIR" "$AWS_TMPDIR/.aws"
        AWS_DOCKER_ARGS+=(-v "$AWS_TMPDIR/.aws":/home/coder/.aws)
        echo "☁️  AWS credentials forwarding: enabled (~/.aws copied and mounted)"
    fi
    # Forward AWS environment variables if set (e.g. for SSO / temporary credentials)
    for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_REGION AWS_REGION AWS_PROFILE; do
        if [ -n "${!var:-}" ]; then
            AWS_DOCKER_ARGS+=(-e "$var=${!var}")
        fi
    done
fi

# ── Git configuration (always forwarded) ───────────────────────
GIT_DOCKER_ARGS=()
GIT_TMPDIR=""
if [ -f "${HOME}/.gitconfig" ] || [ -d "${HOME}/.config/git" ]; then
    GIT_TMPDIR=$(mktemp -d)
    if [ -f "${HOME}/.gitconfig" ]; then
        cp -L "${HOME}/.gitconfig" "$GIT_TMPDIR/.gitconfig"
        GIT_DOCKER_ARGS+=(-v "$GIT_TMPDIR/.gitconfig":/home/coder/.gitconfig)
    fi
    if [ -d "${HOME}/.config/git" ]; then
        mkdir -p "$GIT_TMPDIR/.config"
        cp -rL "${HOME}/.config/git" "$GIT_TMPDIR/.config/git"
        GIT_DOCKER_ARGS+=(-v "$GIT_TMPDIR/.config/git":/home/coder/.config/git)
    fi
    echo "📝 Git configuration forwarding: enabled (temp rw copy mounted)"
fi

# ── SSH agent forwarding ────────────────────────────────────────
SSH_DOCKER_ARGS=()
SSH_TMPDIR=""
if [ "$FORWARD_SSH" = true ]; then
    if [ -n "${SSH_AUTH_SOCK:-}" ]; then
        SSH_DOCKER_ARGS+=(-v "$SSH_AUTH_SOCK":/tmp/ssh-agent.sock)
        SSH_DOCKER_ARGS+=(-e SSH_AUTH_SOCK=/tmp/ssh-agent.sock)
        echo "🔐 SSH agent forwarding: enabled"
    else
        echo "⚠️  --ssh was passed but SSH_AUTH_SOCK is not set. Skipping SSH forwarding."
    fi
    # Mount a rw temp copy of known_hosts so the container can update it
    if [ -f "${HOME}/.ssh/known_hosts" ]; then
        SSH_TMPDIR=$(mktemp -d)
        cp -L "${HOME}/.ssh/known_hosts" "$SSH_TMPDIR/known_hosts"
        SSH_DOCKER_ARGS+=(-v "$SSH_TMPDIR/known_hosts":/home/coder/.ssh/known_hosts)
        echo "🔐 SSH known_hosts forwarding: enabled (temp rw copy mounted)"
    fi
fi

# ── Docker socket forwarding ───────────────────────────────────
DOCKER_DOCKER_ARGS=()
if [ "$FORWARD_DOCKER" = true ]; then
    DOCKER_HOST_VAL="${DOCKER_HOST:-}"
    DOCKER_SOCK="${DOCKER_HOST_VAL#unix://}"
    [ "$DOCKER_SOCK" = "$DOCKER_HOST_VAL" ] && DOCKER_SOCK=""
    DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"
    if [ -S "$DOCKER_SOCK" ]; then
        DOCKER_DOCKER_ARGS+=(-v "$DOCKER_SOCK":/var/run/docker.sock)
        echo "🐳 Docker socket forwarding: enabled ($DOCKER_SOCK → /var/run/docker.sock)"
    else
        echo "⚠️  --docker was passed but $DOCKER_SOCK is not a socket. Skipping Docker forwarding."
    fi
fi

# ── Bluetooth (host BlueZ stack) ───────────────────────────────
# The host runs bluetoothd; apps reach it over the system D-Bus socket.
# Raw HCI/L2CAP sockets (BLE scan, hcitool, gatttool, pybluez) need
# NET_RAW (open the socket) + NET_ADMIN (manage the adapter). The HCI
# subsystem is bound to the network namespace, which is already shared
# via the always-on --network host below.
BLUETOOTH_DOCKER_ARGS=()
if [ "$FORWARD_BLUETOOTH" = true ]; then
    BLUETOOTH_DOCKER_ARGS+=(--cap-add=NET_ADMIN --cap-add=NET_RAW)
    DBUS_SYS_SOCK="/run/dbus/system_bus_socket"
    if [ -S "$DBUS_SYS_SOCK" ]; then
        BLUETOOTH_DOCKER_ARGS+=(-v "$DBUS_SYS_SOCK":/run/dbus/system_bus_socket)
        echo "📶 Bluetooth forwarding: enabled (NET_ADMIN+NET_RAW, system D-Bus mounted)"
    else
        echo "⚠️  --bluetooth: $DBUS_SYS_SOCK not found; capabilities added but bluetoothd is unreachable over D-Bus."
    fi
fi

# ── Host browser opener ─────────────────────────────────────────
# Random per-run password; daemon binds 127.0.0.1 on an OS-assigned port.
# The container talks to it through the shared host network namespace.
HOST_BROWSER_PASS=$(openssl rand -hex 24)
HOST_BROWSER_PORTFILE=$(mktemp)
HOST_BROWSER_PID=""
HOST_BROWSER_PASS="$HOST_BROWSER_PASS" \
    python3 "$SCRIPT_DIR/host-browser-opener.py" "$HOST_BROWSER_PORTFILE" \
    >/dev/null &
HOST_BROWSER_PID=$!

HOST_BROWSER_PORT=""
for _ in $(seq 1 50); do
    if [ -s "$HOST_BROWSER_PORTFILE" ]; then
        HOST_BROWSER_PORT=$(cat "$HOST_BROWSER_PORTFILE")
        break
    fi
    sleep 0.1
done
rm -f "$HOST_BROWSER_PORTFILE"

if [ -z "$HOST_BROWSER_PORT" ]; then
    echo "❌ Failed to start host browser opener daemon" >&2
    kill "$HOST_BROWSER_PID" 2>/dev/null || true
    exit 1
fi
HOST_BROWSER_URL="http://127.0.0.1:${HOST_BROWSER_PORT}/"
echo "🌐 Host browser opener: listening on $HOST_BROWSER_URL"

# ── Cleanup temporary files on exit ────────────────────────────
cleanup() {
    [ -n "$AWS_TMPDIR" ] && rm -rf "$AWS_TMPDIR"
    [ -n "$GIT_TMPDIR" ] && rm -rf "$GIT_TMPDIR"
    [ -n "$SSH_TMPDIR" ] && rm -rf "$SSH_TMPDIR"
    [ -n "$HOST_BROWSER_PID" ] && kill "$HOST_BROWSER_PID" 2>/dev/null || true
}
trap cleanup EXIT

if [ "$PI_MODE" = true ]; then
    echo "🥧 Starting pi (Bedrock backend, Claude Opus 4.7)..."
    AGENT_CMD=(pi --provider amazon-bedrock --model eu.anthropic.claude-opus-4-7)
else
    echo "🚀 Starting Claude Code..."
    AGENT_CMD=(claude --allowedTools "Bash,Edit,Read,Write,Glob,Grep,NotebookEdit,Agent,WebFetch,WebSearch,AskUserQuestion,CronCreate,CronDelete,CronList,EnterPlanMode,ExitPlanMode,EnterWorktree,ExitWorktree,Monitor,PushNotification,RemoteTrigger,ScheduleWakeup,Skill,TaskCreate,TaskGet,TaskList,TaskOutput,TaskStop,TaskUpdate,ToolSearch")
fi
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
    -e HOST_BROWSER_URL="$HOST_BROWSER_URL" \
    -e HOST_BROWSER_PASS="$HOST_BROWSER_PASS" \
    "${GIT_DOCKER_ARGS[@]+"${GIT_DOCKER_ARGS[@]}"}" \
    "${SSH_DOCKER_ARGS[@]+"${SSH_DOCKER_ARGS[@]}"}" \
    "${AWS_DOCKER_ARGS[@]+"${AWS_DOCKER_ARGS[@]}"}" \
    "${DOCKER_DOCKER_ARGS[@]+"${DOCKER_DOCKER_ARGS[@]}"}" \
    "${BLUETOOTH_DOCKER_ARGS[@]+"${BLUETOOTH_DOCKER_ARGS[@]}"}" \
    -v "$ABSOLUTE_WORKSPACE":/home/coder/workspace \
    -v "$CLAUDE_CONFIG_DIR":/home/coder/.claude \
    -v "$CLAUDE_CONFIG_JSON":/home/coder/.claude.json \
    -v "$PI_CONFIG_DIR":/home/coder/.pi \
    "$IMAGE_NAME" "${AGENT_CMD[@]}" \
    "${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}"
