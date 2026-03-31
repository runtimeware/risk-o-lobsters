#!/usr/bin/env bash
set -euo pipefail

# nanoclaw.sh — Install NanoClaw (interactive Claude Code setup required)
#
# NanoClaw is a fork-based platform. The /setup and /add-telegram skills
# require an interactive Claude Code session. There is NO headless alternative.
#
# This script handles: clone, npm install, build, Docker image, mount allowlist,
# systemd service. Human must: run claude → /setup → /add-telegram.
#
# Auth: Claude subscription (CLAUDE_CODE_OAUTH_TOKEN) or API key (ANTHROPIC_API_KEY).
# The credential proxy (port 3001) injects creds at host boundary — containers
# never see real secrets.
#
# Dependencies: Node.js 20+, Docker Engine, gcc/make (for better-sqlite3).
#
# Usage: Run as the NanoClaw user (e.g., nancy). Not root.

REPO_URL="https://github.com/qwibitai/nanoclaw.git"
INSTALL_DIR="${HOME}/nanoclaw"
CONFIG_DIR="${HOME}/.config/nanoclaw"
# shellcheck disable=SC2034
ENV_FILE="${HOME}/.env"  # Referenced in docs/instructions, sourced by .profile

# ── Helpers ──────────────────────────────────────────────────────────────────

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fatal() { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

# ── Setup Node.js via mise (preferred), falling back to system ───────────────

setup_node() {
    # 1. If node+npm already available (system install, or mise already set up)
    if command -v node &>/dev/null && command -v npm &>/dev/null; then
        local node_major
        node_major="$(node --version | sed 's/v\([0-9]*\).*/\1/')"
        if (( node_major >= 20 )); then
            ok "Node.js $(node --version) + npm $(npm --version)"
            return 0
        fi
    fi

    # 2. Try mise (Omarchy-native, per-user, clean teardown on userdel -r)
    if command -v mise &>/dev/null || [[ -x /usr/bin/mise ]]; then
        info "Installing Node.js LTS via mise..."
        local mise_bin
        mise_bin="$(command -v mise 2>/dev/null || echo /usr/bin/mise)"

        # Activate mise in current shell
        eval "$("$mise_bin" activate bash 2>/dev/null)" || true

        # Install node LTS
        "$mise_bin" use --global node@lts 2>&1

        # Re-activate to pick up the new install
        eval "$("$mise_bin" activate bash 2>/dev/null)" || true

        if command -v node &>/dev/null && command -v npm &>/dev/null; then
            ok "Node.js $(node --version) + npm $(npm --version) (via mise)"
            return 0
        fi
        warn "mise install succeeded but node/npm not in PATH"
    fi

    # 3. Fallback: system node exists but npm is missing (bare Arch nodejs pkg)
    if command -v node &>/dev/null && ! command -v npm &>/dev/null; then
        fatal "Node.js found but npm is missing — install npm (pacman -S npm) or mise (mise use node@lts)"
    fi

    fatal "Node.js 20+ not found — install via mise (mise use --global node@lts) or system package manager"
}

# ── Pre-flight ───────────────────────────────────────────────────────────────

preflight() {
    info "Checking prerequisites..."

    # Node.js + npm (installs via mise if needed)
    setup_node

    # Docker
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        ok "Docker accessible"
    else
        fatal "Docker not accessible — is $(whoami) in the docker group?"
    fi

    # git
    if command -v git &>/dev/null; then
        ok "git available"
    else
        fatal "git not found"
    fi

    # Build tools for better-sqlite3 native module
    if command -v gcc &>/dev/null && command -v make &>/dev/null; then
        ok "Build tools (gcc + make) available"
    else
        fatal "gcc and make required for better-sqlite3 — install build-essential"
    fi
}

# ── Clone / update repo ─────────────────────────────────────────────────────

clone_repo() {
    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        info "NanoClaw repo exists — pulling latest..."
        git -C "${INSTALL_DIR}" pull --ff-only 2>&1 || warn "Pull failed — using existing version"
        ok "Repo updated"
    else
        info "Cloning NanoClaw..."
        git clone "${REPO_URL}" "${INSTALL_DIR}"
        ok "Repo cloned to ${INSTALL_DIR}"
    fi
}

# ── npm install + build ──────────────────────────────────────────────────────

npm_setup() {
    info "Running npm install..."
    (cd "${INSTALL_DIR}" && npm install 2>&1)

    # Verify better-sqlite3 loaded (native module)
    if (cd "${INSTALL_DIR}" && node -e "require('better-sqlite3')" 2>/dev/null); then
        ok "npm install complete (better-sqlite3 verified)"
    else
        fatal "better-sqlite3 failed to load — check build-essential is installed"
    fi

    # Build TypeScript → JavaScript
    info "Building TypeScript..."
    if (cd "${INSTALL_DIR}" && npm run build 2>&1); then
        ok "TypeScript build complete"
    else
        warn "TypeScript build failed — will fall back to tsx at runtime"
    fi
}

# ── Build Docker image ───────────────────────────────────────────────────────

build_docker_image() {
    info "Building NanoClaw agent Docker image..."

    local build_script="${INSTALL_DIR}/container/build.sh"
    local dockerfile="${INSTALL_DIR}/container/Dockerfile"

    if [[ -f "$build_script" ]]; then
        if (cd "${INSTALL_DIR}/container" && bash build.sh 2>&1); then
            ok "Docker image built (nanoclaw-agent:latest)"
            return 0
        fi
    fi

    # Fallback: build directly
    if [[ -f "$dockerfile" ]]; then
        if docker build -t nanoclaw-agent:latest "${INSTALL_DIR}/container" 2>&1; then
            ok "Docker image built (nanoclaw-agent:latest)"
            return 0
        fi
    fi

    warn "Docker image build failed — will need to build manually later"
    warn "  cd ~/nanoclaw/container && bash build.sh"
}

# ── Mount allowlist ──────────────────────────────────────────────────────────

create_mount_allowlist() {
    mkdir -p "${CONFIG_DIR}"
    local allowlist="${CONFIG_DIR}/mount-allowlist.json"

    if [[ -f "$allowlist" ]]; then
        ok "Mount allowlist already exists"
        return
    fi

    info "Creating mount allowlist..."
    cat > "$allowlist" <<'JSON'
{
  "allowedRoots": [
    { "path": "~/projects", "allowReadWrite": true, "description": "Development projects" },
    { "path": "~/repos", "allowReadWrite": true, "description": "Git repositories" }
  ],
  "blockedPatterns": ["password", "secret", "token", "credential"],
  "nonMainReadOnly": true
}
JSON
    ok "Mount allowlist created at ${allowlist}"
}

# ── Systemd service ─────────────────────────────────────────────────────────

install_service() {
    local svc_dir="${HOME}/.config/systemd/user"
    mkdir -p "$svc_dir"

    # Determine the best way to start NanoClaw
    local exec_start
    if [[ -f "${INSTALL_DIR}/dist/index.js" ]]; then
        # Prefer compiled JS (no tsx dependency at runtime)
        exec_start="$(command -v node) ${INSTALL_DIR}/dist/index.js"
    else
        # Fallback to tsx (needs to be in PATH)
        local npx_path
        npx_path="$(command -v npx 2>/dev/null || echo '/usr/bin/npx')"
        exec_start="${npx_path} tsx ${INSTALL_DIR}/src/index.ts"
    fi

    # Find node's bin dir for PATH (may be mise-managed or system)
    local node_bin_dir
    node_bin_dir="$(dirname "$(command -v node)")"

    # Build PATH that includes mise shims if mise is managing node
    local svc_path="${node_bin_dir}:%h/.local/share/mise/shims:%h/.local/bin:/usr/local/bin:/usr/bin:/bin"

    cat > "${svc_dir}/nanoclaw.service" <<EOF
[Unit]
Description=NanoClaw AI Agent
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${exec_start}
Restart=on-failure
RestartSec=10
EnvironmentFile=%h/.env
Environment=PATH=${svc_path}
Environment=NODE_ENV=production

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=%h

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload 2>/dev/null || true
    ok "Systemd service installed (ExecStart: ${exec_start})"
}

# ── Health check ─────────────────────────────────────────────────────────────

verify() {
    info "Running verification..."

    # Repo present
    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        ok "Repo: ${INSTALL_DIR}"
    else
        warn "Repo not found"
    fi

    # node_modules present
    if [[ -d "${INSTALL_DIR}/node_modules" ]]; then
        ok "node_modules installed"
    else
        warn "node_modules missing"
    fi

    # Build output
    if [[ -f "${INSTALL_DIR}/dist/index.js" ]]; then
        ok "Build: dist/index.js present"
    else
        warn "Build: dist/index.js missing (will use tsx)"
    fi

    # Docker image
    if docker image inspect nanoclaw-agent:latest &>/dev/null; then
        ok "Docker image: nanoclaw-agent:latest"
    else
        warn "Docker image not built yet"
    fi

    # Mount allowlist
    if [[ -f "${CONFIG_DIR}/mount-allowlist.json" ]]; then
        ok "Mount allowlist present"
    fi

    # Service file
    if [[ -f "${HOME}/.config/systemd/user/nanoclaw.service" ]]; then
        ok "Systemd service file present"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo ""
    info "Setting up NanoClaw for user: $(whoami)"
    echo ""

    preflight
    clone_repo
    npm_setup
    build_docker_image
    create_mount_allowlist
    install_service
    verify

    local user
    user="$(whoami)"

    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  NanoClaw — INTERACTIVE SETUP REQUIRED"
    echo "════════════════════════════════════════════════════"
    echo ""
    echo "  Automated steps complete. Now run Claude Code"
    echo "  interactively to finish setup."
    echo ""
    echo "  Step 1: Set auth in ~/.env"
    echo "    # Option A — Claude subscription (Pro/Max):"
    echo "    #   In another terminal: claude setup-token"
    echo "    #   Copy token, add to ~/.env:"
    echo "    CLAUDE_CODE_OAUTH_TOKEN=<token>"
    echo ""
    echo "    # Option B — API key:"
    echo "    ANTHROPIC_API_KEY=sk-ant-..."
    echo ""
    echo "  Step 2: Run Claude Code"
    echo "    sudo -u ${user} -i"
    echo "    cd ~/nanoclaw"
    echo "    claude"
    echo "    # Inside Claude Code:"
    echo "    /setup"
    echo ""
    echo "  Step 3: Add Telegram channel"
    echo "    # Still inside Claude Code:"
    echo "    /add-telegram"
    echo "    # You'll need: bot token from @BotFather"
    echo "    # Send /chatid to bot to get chat ID"
    echo ""
    echo "  Step 4: Start the service"
    echo "    systemctl --user enable --now nanoclaw"
    echo "    journalctl --user -u nanoclaw -f"
    echo ""
    echo "  Note: Credential proxy runs on port 3001."
    echo "  Containers never see real API keys."
    echo ""
}

main "$@"
