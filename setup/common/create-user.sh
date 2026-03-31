#!/usr/bin/env bash
set -euo pipefail

# create-user.sh — Create an isolated user for a Claw platform instance
# Usage: ./create-user.sh <username> [--docker]
#
# Creates a locked-down user with:
#   - Home directory (chmod 700)
#   - ~/.config/ directory structure
#   - ~/.local/bin/ on PATH via .profile
#   - ~/.env with chmod 600 for secrets
#   - systemd lingering enabled
#   - Optional docker group membership (--docker flag)
#   - NO sudo access
#
# Idempotent: safe to re-run.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <username> [--docker]"
    echo ""
    echo "  <username>   System username to create (e.g., nancy, zlatan, ollie, izzy)"
    echo "  --docker     Add user to docker group (needed for nancy, izzy)"
    echo ""
    echo "Must run as root."
    exit 1
}

info()  { echo -e "  ${GREEN}[OK]${NC} $1"; }
skip()  { echo -e "  ${YELLOW}[SKIP]${NC} $1"; }
step()  { echo -e "  [..] $1"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    usage
fi

USERNAME="$1"
shift

ADD_DOCKER=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker)
            ADD_DOCKER=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: This script must be run as root.${NC}"
    exit 1
fi

# Validate username (alphanumeric + hyphen, 1-32 chars)
if ! [[ "$USERNAME" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
    echo -e "${RED}ERROR: Invalid username '${USERNAME}'. Must start with lowercase letter, contain only [a-z0-9-], max 32 chars.${NC}"
    exit 1
fi

echo ""
echo "=== Creating user: ${USERNAME} ==="
echo ""

# ---------------------------------------------------------------------------
# Create user
# ---------------------------------------------------------------------------
if id "$USERNAME" &>/dev/null; then
    skip "User '${USERNAME}' already exists"
else
    step "Creating user '${USERNAME}'..."
    useradd \
        --create-home \
        --shell /bin/bash \
        --comment "Claw platform user - ${USERNAME}" \
        "$USERNAME"
    info "User '${USERNAME}' created"
fi

HOME_DIR=$(eval echo "~${USERNAME}")

# ---------------------------------------------------------------------------
# Lock password (no password login — access via sudo su only)
# ---------------------------------------------------------------------------
passwd -l "$USERNAME" &>/dev/null || true
info "Password login disabled (use: sudo -u ${USERNAME} -i)"

# ---------------------------------------------------------------------------
# Home directory permissions
# ---------------------------------------------------------------------------
chmod 700 "$HOME_DIR"
info "Home directory permissions set to 700"

# ---------------------------------------------------------------------------
# Docker group membership
# ---------------------------------------------------------------------------
if $ADD_DOCKER; then
    if getent group docker &>/dev/null; then
        if id -nG "$USERNAME" | grep -qw docker; then
            skip "User '${USERNAME}' already in docker group"
        else
            usermod -aG docker "$USERNAME"
            info "Added '${USERNAME}' to docker group"
        fi
    else
        echo -e "${RED}WARNING: docker group does not exist. Install Docker first.${NC}"
    fi
else
    # Ensure user is NOT in docker group (idempotent safety)
    if id -nG "$USERNAME" 2>/dev/null | grep -qw docker; then
        gpasswd -d "$USERNAME" docker &>/dev/null || true
        echo -e "${YELLOW}[NOTE]${NC} Removed '${USERNAME}' from docker group (--docker not specified)"
    fi
    info "Docker group: not added (no --docker flag)"
fi

# ---------------------------------------------------------------------------
# Ensure NO sudo access
# ---------------------------------------------------------------------------
# Remove from sudo/wheel groups if somehow present
for group in sudo wheel; do
    if id -nG "$USERNAME" 2>/dev/null | grep -qw "$group"; then
        gpasswd -d "$USERNAME" "$group" &>/dev/null || true
        echo -e "${YELLOW}[NOTE]${NC} Removed '${USERNAME}' from ${group} group"
    fi
done
info "No sudo access (confirmed)"

# ---------------------------------------------------------------------------
# Directory structure
# ---------------------------------------------------------------------------
DIRS=(
    "${HOME_DIR}/.config"
    "${HOME_DIR}/.config/systemd"
    "${HOME_DIR}/.config/systemd/user"
    "${HOME_DIR}/.local"
    "${HOME_DIR}/.local/bin"
    "${HOME_DIR}/.local/share"
    "${HOME_DIR}/.local/state"
    "${HOME_DIR}/.cache"
)

for dir in "${DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        skip "Directory exists: ${dir#${HOME_DIR}/}"
    else
        mkdir -p "$dir"
        info "Created: ${dir#${HOME_DIR}/}"
    fi
done

# ---------------------------------------------------------------------------
# .profile — add ~/.local/bin to PATH
# ---------------------------------------------------------------------------
PROFILE="${HOME_DIR}/.profile"
MARKER="# Claw platform PATH setup"

if [[ -f "$PROFILE" ]] && grep -qF "$MARKER" "$PROFILE"; then
    # Fixup: ensure ~/bin is on PATH (missing in earlier versions)
    if ! grep -q 'HOME/bin' "$PROFILE"; then
        printf '\nif [ -d "$HOME/bin" ]; then\n    PATH="$HOME/bin:$PATH"\nfi\n' >> "$PROFILE"
        chown "${USERNAME}:${USERNAME}" "$PROFILE"
        info "Added ~/bin to PATH in .profile (upgrade)"
    else
        skip ".profile already configured"
    fi
else
    cat >> "$PROFILE" << 'PROFILE_EOF'

# Claw platform PATH setup
if [ -d "$HOME/bin" ]; then
    PATH="$HOME/bin:$PATH"
fi
if [ -d "$HOME/.local/bin" ]; then
    PATH="$HOME/.local/bin:$PATH"
fi

# Environment baseline (inlined — platform users can't read the admin home)
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_DATA_HOME="${HOME}/.local/share"
export XDG_STATE_HOME="${HOME}/.local/state"
export XDG_CACHE_HOME="${HOME}/.cache"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export CLAW_EVAL_ENV=1
export EDITOR="nano"
export DO_NOT_TRACK=1
export NEXT_TELEMETRY_DISABLED=1
[ -f "${HOME}/.cargo/env" ] && . "${HOME}/.cargo/env"
command -v mise >/dev/null 2>&1 && eval "$(mise activate bash 2>/dev/null)"

# Source secrets last
if [ -f "${HOME}/.env" ]; then
    set -a; . "${HOME}/.env"; set +a
fi
PROFILE_EOF
    info ".profile updated with PATH and environment baseline"
fi

# ---------------------------------------------------------------------------
# .env — secrets file
# ---------------------------------------------------------------------------
ENV_FILE="${HOME_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    skip ".env already exists"
    # Ensure permissions are correct even if file exists
    chmod 600 "$ENV_FILE"
    info ".env permissions verified (600)"
else
    cat > "$ENV_FILE" << ENV_EOF
# Secrets for ${USERNAME}
# This file is chmod 600 — only ${USERNAME} can read it.
# Sourced by env-common.sh on login.
#
# TELEGRAM_BOT_TOKEN=<your-bot-token-here>
# ANTHROPIC_API_KEY=<your-api-key-here>
# OPENROUTER_API_KEY=<your-openrouter-key-here>
ENV_EOF
    chmod 600 "$ENV_FILE"
    info ".env created with chmod 600"
fi

# ---------------------------------------------------------------------------
# Fix ownership (everything under home should belong to the user)
# ---------------------------------------------------------------------------
chown -R "${USERNAME}:${USERNAME}" "$HOME_DIR"
info "Ownership set to ${USERNAME}:${USERNAME}"

# ---------------------------------------------------------------------------
# Enable lingering for systemd user services
# ---------------------------------------------------------------------------
if loginctl show-user "$USERNAME" 2>/dev/null | grep -q "Linger=yes"; then
    skip "Lingering already enabled for '${USERNAME}'"
else
    loginctl enable-linger "$USERNAME"
    info "Lingering enabled (systemd user services persist after logout)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== User '${USERNAME}' ready ==="
echo "  Home:     ${HOME_DIR}"
echo "  Shell:    /bin/bash"
echo "  Docker:   $(if $ADD_DOCKER; then echo 'yes'; else echo 'no'; fi)"
echo "  Secrets:  ${ENV_FILE}"
echo "  Switch:   sudo -u ${USERNAME} -i"
echo ""
