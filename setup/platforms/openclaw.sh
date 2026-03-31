#!/usr/bin/env bash
set -euo pipefail

# openclaw.sh — Install OpenClaw (interactive onboard required)
#
# OpenClaw is an npm package. Install is automated, but `openclaw onboard`
# is an interactive wizard that CANNOT be scripted.
#
# SECURITY: Must be v2026.2.2+ (CVE-2026-25253 RCE patch).
#
# Uses fnm (preferred) or nvm for Node.js version management.
# Systemd service uses absolute paths to avoid nvm/fnm PATH breakage.
#
# Usage: Run as the OpenClaw user (e.g., ollie). Not root.

REQUIRED_VERSION="2026.2.2"
# shellcheck disable=SC2034
ENV_FILE="${HOME}/.env"  # Referenced in docs/instructions, sourced by .profile

# ── Helpers ──────────────────────────────────────────────────────────────────

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$1"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$1"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$1"; }
fatal() { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$1" >&2; exit 1; }

version_gte() {
    # Returns 0 if $1 >= $2 (semver-ish)
    printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1 | grep -qx "$2"
}

# ── Setup Node.js ────────────────────────────────────────────────────────────

setup_node() {
    # 1. Already available (prior run, system install, or pre-activated mise)
    if command -v node &>/dev/null && command -v npm &>/dev/null; then
        local node_major
        node_major="$(node --version | sed 's/v\([0-9]*\).*/\1/')"
        if (( node_major >= 20 )); then
            ok "Node.js $(node --version) + npm $(npm --version)"
            ok "npm prefix: $(npm prefix -g)"
            return 0
        fi
    fi

    # 2. Prefer mise (Omarchy-native, per-user, clean teardown on userdel -r)
    if command -v mise &>/dev/null || [[ -x /usr/bin/mise ]]; then
        info "Installing Node.js LTS via mise..."
        local mise_bin
        mise_bin="$(command -v mise 2>/dev/null || echo /usr/bin/mise)"

        # Add shims to PATH first (works even if activate fails)
        local mise_shims="${HOME}/.local/share/mise/shims"
        [[ -d "$mise_shims" ]] && export PATH="${mise_shims}:${PATH}"

        eval "$("$mise_bin" activate bash 2>/dev/null)" || true
        "$mise_bin" use --global node@lts 2>&1

        # Re-add shims (install may have created the dir)
        [[ -d "$mise_shims" ]] && export PATH="${mise_shims}:${PATH}"
        eval "$("$mise_bin" activate bash 2>/dev/null)" || true

        if command -v node &>/dev/null && command -v npm &>/dev/null; then
            ok "Node.js $(node --version) + npm $(npm --version) (via mise)"
            ok "npm prefix: $(npm prefix -g)"
            return 0
        fi
        warn "mise installed node but node/npm still not in PATH"
        fatal "Fix: add ${mise_shims} to PATH or check 'mise doctor'"
    fi

    # 3. fnm (faster than nvm, no unbound var issues)
    if command -v fnm &>/dev/null; then
        info "Using fnm for Node.js management"
        eval "$(fnm env --shell bash 2>/dev/null)" || true

        if ! fnm ls 2>/dev/null | grep -q 'lts'; then
            info "Installing Node.js LTS via fnm..."
            fnm install --lts
        fi
        fnm use --lts 2>/dev/null || fnm use default 2>/dev/null || true

        if command -v node &>/dev/null; then
            ok "Node.js $(node --version) via fnm"
            ok "npm prefix: $(npm prefix -g)"
            return 0
        fi
    fi

    # 4. Fallback: nvm
    # Pin to ~/.nvm explicitly — don't inherit env or let XDG_CONFIG_HOME redirect
    # nvm's installer uses XDG_CONFIG_HOME if NVM_DIR is unset, which would put
    # nvm in ~/.config/nvm instead. We mkdir first so the installer doesn't bail
    # on "NVM_DIR set but doesn't exist".
    export NVM_DIR="$HOME/.nvm"
    mkdir -p "$NVM_DIR"

    if [[ ! -s "${NVM_DIR}/nvm.sh" ]]; then
        info "Installing nvm..."
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    fi

    set +u
    [[ -s "${NVM_DIR}/nvm.sh" ]] && . "${NVM_DIR}/nvm.sh"

    if ! command -v nvm &>/dev/null; then
        set -u
        fatal "No Node.js version manager available (tried mise, fnm, nvm)"
    fi

    if ! nvm ls --no-colors lts/* &>/dev/null; then
        info "Installing Node.js LTS via nvm..."
        nvm install --lts
    fi
    nvm use --lts
    set -u

    if ! command -v npm &>/dev/null; then
        fatal "npm not available after node installation"
    fi

    ok "Node.js $(node --version) | npm $(npm --version)"
    ok "npm prefix: $(npm prefix -g)"
}

# ── Install OpenClaw ─────────────────────────────────────────────────────────

install_openclaw() {
    info "Installing openclaw via npm..."
    npm install -g openclaw

    if ! command -v openclaw &>/dev/null; then
        # Check common locations
        for dir in "$(npm prefix -g)/bin" "${HOME}/.local/bin"; do
            if [[ -x "${dir}/openclaw" ]]; then
                export PATH="${dir}:${PATH}"
                break
            fi
        done
    fi

    if ! command -v openclaw &>/dev/null; then
        fatal "openclaw not found after install"
    fi

    ok "openclaw installed: $(command -v openclaw)"
}

# ── Version check (CVE-2026-25253) ──────────────────────────────────────────

check_version() {
    local installed_version
    installed_version="$(openclaw --version 2>/dev/null | grep -oP '\d{4}\.\d+\.\d+' | head -1)"

    if [[ -z "$installed_version" ]]; then
        warn "Could not determine openclaw version — verify manually"
        return 0
    fi

    if ! version_gte "$installed_version" "$REQUIRED_VERSION"; then
        fatal "Version ${installed_version} < ${REQUIRED_VERSION} — CVE-2026-25253 UNPATCHED!"
    fi

    ok "Version ${installed_version} >= ${REQUIRED_VERSION} (CVE-2026-25253 patched)"
}

# ── Systemd service ─────────────────────────────────────────────────────────

install_service() {
    local svc_dir="${HOME}/.config/systemd/user"
    mkdir -p "$svc_dir"

    # Get ABSOLUTE paths (survives nvm/fnm/mise version changes if pinned)
    local openclaw_bin node_bin_dir
    openclaw_bin="$(command -v openclaw)"
    node_bin_dir="$(dirname "$(command -v node)")"

    # Include mise shims in PATH for mise-managed node
    local svc_path="${node_bin_dir}:%h/.local/share/mise/shims:%h/.local/bin:/usr/local/bin:/usr/bin:/bin"

    cat > "${svc_dir}/openclaw.service" <<EOF
[Unit]
Description=OpenClaw AI Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${openclaw_bin}
Restart=on-failure
RestartSec=10
EnvironmentFile=%h/.env
Environment=PATH=${svc_path}
Environment=NODE_ENV=production

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.config/openclaw %h/.local/share/openclaw %h/.openclaw
PrivateTmp=true

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload 2>/dev/null || true
    ok "Systemd service installed"
    warn "Note: If you upgrade Node.js, re-run this script to update ExecStart path"
}

# ── Health check ─────────────────────────────────────────────────────────────

verify() {
    info "Running verification..."

    if command -v openclaw &>/dev/null; then
        ok "openclaw in PATH: $(command -v openclaw)"
    else
        warn "openclaw not in PATH"
    fi

    if [[ -f "${HOME}/.config/systemd/user/openclaw.service" ]]; then
        ok "Systemd service file present"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo ""
    info "Setting up OpenClaw for user: $(whoami)"
    echo ""

    setup_node
    install_openclaw
    check_version
    install_service
    verify

    local user
    user="$(whoami)"

    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  OpenClaw — INTERACTIVE ONBOARDING REQUIRED"
    echo "════════════════════════════════════════════════════"
    echo ""
    echo "  The 'openclaw onboard' wizard is interactive and"
    echo "  cannot be scripted. Run it manually:"
    echo ""
    echo "    sudo -u ${user} -i"
    echo "    openclaw onboard"
    echo ""
    echo "  The wizard handles:"
    echo "    - Channel pairing (Telegram DM pairing code)"
    echo "    - Provider selection (Anthropic, OpenRouter)"
    echo "    - Config file generation (53+ config files)"
    echo ""
    echo "  After onboarding:"
    echo "    systemctl --user enable --now openclaw"
    echo "    journalctl --user -u openclaw -f"
    echo ""
    echo "  Ensure ~/.env has:"
    echo "    ANTHROPIC_API_KEY=sk-ant-..."
    echo "    OPENROUTER_API_KEY=sk-or-..."
    echo "    TELEGRAM_BOT_TOKEN=<from @BotFather>"
    echo ""
}

main "$@"
