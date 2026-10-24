#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="claude-code"
CONTAINER_NAME="claude-code-$(date +%s)"

# ── Parse flags ─────────────────────────────────────────────────
# Usage: run.sh [--ssh] [--aws] [--bedrock] [--docker] [--bluetooth] [--pi]
#               [--memory SIZE] [workspace] [-- agent args...]
# --memory SIZE caps the container's RAM (docker size syntax, e.g. 8g; default
# 4g, swap included); --memory unlimited removes the cap.
# Unknown flags (starting with -) are forwarded to the agent (claude or pi).
# --pi starts pi with the default model from its settings (~/.pi-docker); pick
# another with /model inside pi (Ctrl+S saves it as the default), or pass e.g.
# `--pi -- --model cursor/composer-2`.
# Bedrock models additionally need --aws.
# --bedrock forces Claude Code onto AWS Bedrock instead of the Anthropic login
# (requires --aws). Region, models etc. come from the untracked bedrock.env next
# to this script (see bedrock.env.example).
# Env: WORKSPACE=<dir> picks the workspace (default: cwd);
#      ALLOW_UNSAFE_WORKSPACE_PATH=1 skips the workspace path collision check.
FORWARD_SSH=false
FORWARD_AWS=false
USE_BEDROCK=false
FORWARD_DOCKER=false
FORWARD_BLUETOOTH=false
PI_MODE=false
MEMORY_LIMIT="4g"
CLAUDE_ARGS=()
past_double_dash=false

while [ $# -gt 0 ]; do
    arg="$1"
    shift
    if $past_double_dash; then
        CLAUDE_ARGS+=("$arg")
        continue
    fi
    case "$arg" in
        --ssh) FORWARD_SSH=true ;;
        --aws) FORWARD_AWS=true ;;
        --bedrock) USE_BEDROCK=true ;;
        --docker) FORWARD_DOCKER=true ;;
        --bluetooth) FORWARD_BLUETOOTH=true ;;
        --pi)  PI_MODE=true ;;
        --memory=*) MEMORY_LIMIT="${arg#--memory=}" ;;
        --memory)
            if [ $# -eq 0 ]; then
                echo "❌ --memory requires a size (e.g. 8g) or 'unlimited'" >&2
                exit 1
            fi
            MEMORY_LIMIT="$1"
            shift
            ;;
        --)   past_double_dash=true ;;
        -*)   CLAUDE_ARGS+=("$arg") ;;
        *)
            CLAUDE_ARGS+=("$arg")
            ;;
    esac
done

if [ "$USE_BEDROCK" = true ] && [ "$PI_MODE" = true ]; then
    echo "❌ --bedrock is for Claude Code; for pi pass --aws and pick a Bedrock model with /model" >&2
    exit 1
fi
if [ "$USE_BEDROCK" = true ] && [ "$FORWARD_AWS" != true ]; then
    echo "❌ --bedrock requires --aws to forward the AWS credentials" >&2
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

# The workspace is mounted at the *same* path inside the container as on the
# host, so paths printed inside the container are valid outside it too.
echo "📂 Mounting workspace: $ABSOLUTE_WORKSPACE (same path inside the container)"
echo "🔑 OAuth credentials stored in: $CLAUDE_CONFIG_DIR"
echo "🆔 Running as UID=$(id -u) GID=$(id -g)"

# ── Workspace path collision check ─────────────────────────────
# Because the workspace is mounted at its host path, that path could collide
# with a directory the image already ships (/usr, /etc, /home/coder, ...). The
# mount would shadow the image's own files and break the container — for /usr
# even before the entrypoint can run. Ask the image itself instead of keeping a
# list of paths in sync here: a non-empty target inside the image is a conflict.
if [ "${ALLOW_UNSAFE_WORKSPACE_PATH:-}" != "1" ]; then
    if IMAGE_PATH_CONTENTS=$(docker run --rm --entrypoint sh \
            -e CHECK_PATH="$ABSOLUTE_WORKSPACE" "$IMAGE_NAME" \
            -c 'ls -A "$CHECK_PATH" 2>/dev/null | head -5 | tr "\n" " "'); then
        if [ -n "$IMAGE_PATH_CONTENTS" ]; then
            echo "❌ Refusing to mount the workspace at $ABSOLUTE_WORKSPACE" >&2
            echo "❌ That path already exists in the container image and is not empty:" >&2
            echo "❌   $IMAGE_PATH_CONTENTS" >&2
            echo "❌ Mounting the workspace there would hide the image's own files and" >&2
            echo "❌ break the container. Start the agent from a different directory, or" >&2
            echo "❌ set ALLOW_UNSAFE_WORKSPACE_PATH=1 to mount it anyway." >&2
            exit 1
        fi
    else
        echo "⚠️  Could not check $ABSOLUTE_WORKSPACE against the image; continuing." >&2
    fi
fi

# ── Memory limit ───────────────────────────────────────────────
# --memory-swap equal to --memory means no swap on top of the RAM cap.
MEMORY_DOCKER_ARGS=()
if [ "$MEMORY_LIMIT" = "unlimited" ]; then
    echo "🧠 Memory limit: none"
else
    if [ -z "$MEMORY_LIMIT" ]; then
        echo "❌ --memory requires a size (e.g. 8g) or 'unlimited'" >&2
        exit 1
    fi
    MEMORY_DOCKER_ARGS+=(--memory "$MEMORY_LIMIT" --memory-swap "$MEMORY_LIMIT")
    echo "🧠 Memory limit: $MEMORY_LIMIT (no extra swap)"
fi

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

# ── Bedrock (Claude Code) ──────────────────────────────────────
# The Bedrock settings (region, profile, models) live in the untracked
# bedrock.env, passed as a docker env-file. Variables forwarded by --aws above
# take precedence over it (docker applies -e after --env-file).
BEDROCK_DOCKER_ARGS=()
if [ "$USE_BEDROCK" = true ]; then
    BEDROCK_ENV_FILE="$SCRIPT_DIR/bedrock.env"
    if [ ! -f "$BEDROCK_ENV_FILE" ]; then
        echo "❌ --bedrock needs $BEDROCK_ENV_FILE (copy bedrock.env.example and edit it)" >&2
        exit 1
    fi
    BEDROCK_DOCKER_ARGS+=(-e CLAUDE_CODE_USE_BEDROCK=1 --env-file "$BEDROCK_ENV_FILE")
    echo "🪨 Claude Code on Bedrock: enabled (settings from $BEDROCK_ENV_FILE)"
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

# ── Host bridge (browser + clipboard) ───────────────────────────
# Random per-run password; daemon binds 127.0.0.1 on an OS-assigned port.
# The container talks to it through the shared host network namespace.
HOST_BRIDGE_PASS=$(openssl rand -hex 24)
HOST_BRIDGE_PORTFILE=$(mktemp)
HOST_BRIDGE_PID=""
HOST_BRIDGE_PASS="$HOST_BRIDGE_PASS" \
    python3 "$SCRIPT_DIR/host-bridge.py" "$HOST_BRIDGE_PORTFILE" \
    >/dev/null &
HOST_BRIDGE_PID=$!

HOST_BRIDGE_PORT=""
for _ in $(seq 1 50); do
    if [ -s "$HOST_BRIDGE_PORTFILE" ]; then
        HOST_BRIDGE_PORT=$(cat "$HOST_BRIDGE_PORTFILE")
        break
    fi
    sleep 0.1
done
rm -f "$HOST_BRIDGE_PORTFILE"

if [ -z "$HOST_BRIDGE_PORT" ]; then
    echo "❌ Failed to start host bridge daemon" >&2
    kill "$HOST_BRIDGE_PID" 2>/dev/null || true
    exit 1
fi
HOST_BRIDGE_URL="http://127.0.0.1:${HOST_BRIDGE_PORT}/"
echo "🌐 Host bridge: listening on $HOST_BRIDGE_URL"

# Clipboard writes from the container need a clipboard tool on the *host*.
if command -v wl-copy >/dev/null 2>&1 || command -v xclip >/dev/null 2>&1 \
        || command -v xsel >/dev/null 2>&1; then
    echo "📋 Host clipboard bridge: enabled (container writes only)"
    # HTML copies also carry plain text only if host-bridge.py --hold-clipboard
    # can run: an X display (XWayland is fine) and GTK 4 for Python.
    GTK4_CHECK='import gi; gi.require_version("Gtk", "4.0"); from gi.repository import Gtk'
    if [ -n "${DISPLAY:-}" ] && { python3 -c "$GTK4_CHECK" 2>/dev/null \
            || /usr/bin/python3 -c "$GTK4_CHECK" 2>/dev/null; }; then
        echo "📋 HTML copies: HTML + plain-text alternative (GTK 4)"
    else
        echo "⚠️  HTML copies will be HTML-only (pasting into a terminal gives raw markup)."
        echo "⚠️  Install python3-gobject and gtk4 on the host (and have \$DISPLAY / XWayland) to add plain text."
    fi
else
    echo "⚠️  No wl-copy/xclip/xsel on the host — clipboard bridge will be unavailable."
    echo "⚠️  Install wl-clipboard (Wayland) or xclip/xsel (X11) to enable it."
fi

# ── Cleanup temporary files on exit ────────────────────────────
cleanup() {
    [ -n "$AWS_TMPDIR" ] && rm -rf "$AWS_TMPDIR"
    [ -n "$GIT_TMPDIR" ] && rm -rf "$GIT_TMPDIR"
    [ -n "$SSH_TMPDIR" ] && rm -rf "$SSH_TMPDIR"
    [ -n "$HOST_BRIDGE_PID" ] && kill "$HOST_BRIDGE_PID" 2>/dev/null || true
}
trap cleanup EXIT

if [ "$PI_MODE" = true ]; then
    # No --provider/--model: pi uses the default from its settings.json, which
    # Ctrl+S in the /model picker saves (Cursor, Bedrock, ...).
    echo "🥧 Starting pi (default model from ${PI_CONFIG_DIR}/agent/settings.json)..."
    if [ "$FORWARD_AWS" != true ]; then
        echo "   Bedrock models need --aws; Cursor models need /login cursor once."
    fi
    AGENT_CMD=(pi)
else
    echo "🚀 Starting Claude Code..."
    AGENT_CMD=(claude --allowedTools "Bash,Edit,Read,Write,Glob,Grep,NotebookEdit,Agent,WebFetch,WebSearch,AskUserQuestion,CronCreate,CronDelete,CronList,EnterPlanMode,ExitPlanMode,EnterWorktree,ExitWorktree,Monitor,PushNotification,RemoteTrigger,ScheduleWakeup,Skill,TaskCreate,TaskGet,TaskList,TaskOutput,TaskStop,TaskUpdate,ToolSearch")
fi
echo ""
if [ "$USE_BEDROCK" = true ]; then
    echo "   Using the forwarded AWS credentials (run aws sso login on the host first if needed)."
else
    echo "   On first run you'll be prompted to authenticate via browser."
    echo "   Credentials are persisted so you won't need to log in again."
fi
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
    -e HOST_BRIDGE_URL="$HOST_BRIDGE_URL" \
    -e HOST_BRIDGE_PASS="$HOST_BRIDGE_PASS" \
    -e WORKSPACE_DIR="$ABSOLUTE_WORKSPACE" \
    -w "$ABSOLUTE_WORKSPACE" \
    "${GIT_DOCKER_ARGS[@]+"${GIT_DOCKER_ARGS[@]}"}" \
    "${SSH_DOCKER_ARGS[@]+"${SSH_DOCKER_ARGS[@]}"}" \
    "${AWS_DOCKER_ARGS[@]+"${AWS_DOCKER_ARGS[@]}"}" \
    "${BEDROCK_DOCKER_ARGS[@]+"${BEDROCK_DOCKER_ARGS[@]}"}" \
    "${DOCKER_DOCKER_ARGS[@]+"${DOCKER_DOCKER_ARGS[@]}"}" \
    "${BLUETOOTH_DOCKER_ARGS[@]+"${BLUETOOTH_DOCKER_ARGS[@]}"}" \
    "${MEMORY_DOCKER_ARGS[@]+"${MEMORY_DOCKER_ARGS[@]}"}" \
    -v "$ABSOLUTE_WORKSPACE":"$ABSOLUTE_WORKSPACE" \
    -v "$CLAUDE_CONFIG_DIR":/home/coder/.claude \
    -v "$CLAUDE_CONFIG_JSON":/home/coder/.claude.json \
    -v "$PI_CONFIG_DIR":/home/coder/.pi \
    "$IMAGE_NAME" "${AGENT_CMD[@]}" \
    "${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}"
