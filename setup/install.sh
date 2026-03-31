#!/usr/bin/env bash
set -euo pipefail

# install.sh — Create users and install Claw platforms
#
# Usage:
#   sudo ./install.sh nanoclaw --as nancy
#   sudo ./install.sh zeroclaw                    # Uses default name "zlatan"
#   sudo ./install.sh nanoclaw zeroclaw           # Two platforms
#   sudo ./install.sh                             # All 4
#   sudo ./install.sh --list                      # Show status
#   sudo ./install.sh --dry-run nanoclaw          # Preview
#
# User names must start with the same letter as the platform:
#   nanoclaw → n*    zeroclaw → z*    openclaw → o*    ironclaw → i*

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="${SCRIPT_DIR}/common"
PLATFORMS_DIR="${SCRIPT_DIR}/platforms"
STATE_FILE="${SCRIPT_DIR}/../.platform-users"
DRY_RUN=false
LIST_ONLY=false
ERRORS=0

# ── Platform registry ────────────────────────────────────────────────────────

ALL_PLATFORMS=(nanoclaw zeroclaw openclaw ironclaw)

declare -A PLATFORM_DISPLAY=(
    [nanoclaw]="NanoClaw"  [zeroclaw]="ZeroClaw"
    [openclaw]="OpenClaw"  [ironclaw]="IronClaw"
)

declare -A PLATFORM_LETTER=(
    [nanoclaw]="n"  [zeroclaw]="z"  [openclaw]="o"  [ironclaw]="i"
)

declare -A PLATFORM_DEFAULT_USER=(
    [nanoclaw]="nancy"  [zeroclaw]="zlatan"  [openclaw]="ollie"  [ironclaw]="izzy"
)

declare -A PLATFORM_DOCKER=(
    [nanoclaw]="yes"  [zeroclaw]="no"  [openclaw]="no"  [ironclaw]="yes"
)

# ── State file helpers ───────────────────────────────────────────────────────

load_user_for() {
    local platform="$1"
    if [[ -f "$STATE_FILE" ]]; then
        grep -m1 "^${platform}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true
    fi
}

save_user_for() {
    local platform="$1" username="$2"
    if [[ -f "$STATE_FILE" ]]; then
        grep -v "^${platform}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    echo "${platform}=${username}" >> "$STATE_FILE"
}

resolve_username() {
    local platform="$1" explicit="${2:-}" letter="${PLATFORM_LETTER[$1]}"
    if [[ -n "$explicit" ]]; then
        if [[ "${explicit:0:1}" != "$letter" ]]; then
            echo -e "${RED}ERROR: Name for ${PLATFORM_DISPLAY[$platform]} must start with '${letter}'${NC}" >&2
            return 1
        fi
        echo "$explicit"
        return 0
    fi
    local saved; saved="$(load_user_for "$platform")"
    if [[ -n "$saved" ]]; then echo "$saved"; return 0; fi
    echo "${PLATFORM_DEFAULT_USER[$platform]}"
}

# ── Helpers ──────────────────────────────────────────────────────────────────

banner() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""
}

# ── PostgreSQL for IronClaw (Docker container) ───────────────────────────────

setup_ironclaw_postgres() {
    local pg_container="ironclaw-pg"
    local pg_image="pgvector/pgvector:pg15"

    if docker ps --format '{{.Names}}' | grep -qw "$pg_container"; then
        echo -e "  ${GREEN}[OK]${NC} PostgreSQL container already running"
        return 0
    fi

    if docker ps -a --format '{{.Names}}' | grep -qw "$pg_container"; then
        echo -e "  ${BOLD}[START]${NC} Starting stopped PostgreSQL container..."
        docker start "$pg_container"
    else
        echo -e "  ${BOLD}[CREATE]${NC} Creating PostgreSQL container..."
        docker pull "$pg_image"
        docker run -d \
            --name "$pg_container" \
            --restart unless-stopped \
            -e POSTGRES_DB=ironclaw \
            -e POSTGRES_USER=ironclaw \
            -e POSTGRES_PASSWORD="${IRONCLAW_PG_PASSWORD:?Set IRONCLAW_PG_PASSWORD before running}" \
            -p "127.0.0.1:5433:5432" \
            "$pg_image" >/dev/null
    fi

    # Wait for ready
    echo -e "  ${BOLD}[WAIT]${NC} Waiting for PostgreSQL..."
    local retries=0
    until docker exec "$pg_container" pg_isready -U ironclaw -d ironclaw &>/dev/null; do
        retries=$((retries + 1))
        if (( retries >= 30 )); then
            echo -e "  ${RED}[ERROR]${NC} PostgreSQL did not become ready"
            return 1
        fi
        sleep 1
    done

    # Enable pgvector
    docker exec "$pg_container" psql -U ironclaw -d ironclaw \
        -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1

    echo -e "  ${GREEN}[OK]${NC} PostgreSQL running on 127.0.0.1:5433 (pgvector enabled)"
}

# ── Status check ─────────────────────────────────────────────────────────────

check_platform_status() {
    local platform="$1"
    local display="${PLATFORM_DISPLAY[$platform]}"
    local user; user="$(load_user_for "$platform")"
    [[ -z "$user" ]] && user="${PLATFORM_DEFAULT_USER[$platform]}"

    if ! id "$user" &>/dev/null; then
        echo -e "  ${RED}[NOT DEPLOYED]${NC} ${display} — no user '${user}'"
        return
    fi

    local user_home; user_home="$(eval echo "~${user}")"
    local artifact=""

    case "$platform" in
        nanoclaw)
            [[ -d "${user_home}/nanoclaw/.git" ]] && artifact="repo cloned" || artifact="repo missing"
            ;;
        zeroclaw)
            [[ -x "${user_home}/bin/zeroclaw" ]] && artifact="binary installed" || artifact="binary missing"
            ;;
        openclaw)
            # nvm is loaded by .bashrc which is skipped in non-interactive shells — source it explicitly
            su - "${user}" -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" 2>/dev/null; command -v openclaw' &>/dev/null 2>&1 && artifact="openclaw available" || artifact="openclaw not in PATH"
            ;;
        ironclaw)
            local parts=()
            [[ -x "${user_home}/bin/ironclaw" ]] && parts+=("binary installed") || parts+=("binary missing")
            docker ps -q -f name=ironclaw-pg 2>/dev/null | grep -q . && parts+=("pg running") || parts+=("pg stopped")
            artifact="${parts[*]}"
            ;;
    esac

    local svc_status="no service"
    if [[ -f "${user_home}/.config/systemd/user/${platform}.service" ]]; then
        su - "${user}" -c "systemctl --user is-active ${platform}.service" &>/dev/null 2>&1 && svc_status="running" || svc_status="stopped"
    fi

    local docker_note=""
    if id -nG "$user" 2>/dev/null | grep -qw docker; then docker_note=" | docker: yes"; fi

    local color="${GREEN}"
    [[ "$artifact" == *"missing"* ]] && color="${YELLOW}"
    echo -e "  ${color}[${user}]${NC} ${display} — ${artifact} | service: ${svc_status}${docker_note}"
}

# ── Argument parsing ─────────────────────────────────────────────────────────

TARGETS=()
declare -A TARGET_USERS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true;  shift ;;
        --list|-l)  LIST_ONLY=true; shift ;;
        --as)
            if [[ ${#TARGETS[@]} -eq 0 ]]; then
                echo -e "${RED}--as must follow a platform name${NC}"; exit 1
            fi
            TARGET_USERS["${TARGETS[-1]}"]="${2:?--as requires a name}"
            shift 2
            ;;
        -h|--help)
            cat <<'EOF'
Usage: sudo ./install.sh [PLATFORM [--as NAME]]... [OPTIONS]

Platforms:
  nanoclaw    NanoClaw  (Anthropic, Docker, Node.js)     name starts with 'n'
  zeroclaw    ZeroClaw  (OpenRouter, Landlock)            name starts with 'z'
  openclaw    OpenClaw  (Multi-provider, Node.js)         name starts with 'o'
  ironclaw    IronClaw  (Multi-provider, WASM, libsql)     name starts with 'i'

Options:
  --as NAME     Set the Linux username for the preceding platform
  --dry-run     Preview all steps without making changes
  --list, -l    Show current status of all platforms
  -h, --help    Show this help
EOF
            exit 0
            ;;
        nanoclaw|zeroclaw|openclaw|ironclaw)
            TARGETS+=("$1"); shift ;;
        *)
            echo -e "${RED}Unknown: $1${NC}"; exit 1 ;;
    esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    TARGETS=("${ALL_PLATFORMS[@]}")
fi

# ── --list mode ──────────────────────────────────────────────────────────────

if $LIST_ONLY; then
    banner "Platform Status"
    for platform in "${ALL_PLATFORMS[@]}"; do
        check_platform_status "$platform"
    done
    echo ""
    exit 0
fi

# ── Root check ───────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: Must run as root.${NC}"
    echo "Usage: sudo $0 [PLATFORM...] [--dry-run]"
    exit 1
fi

# ── Resolve usernames ────────────────────────────────────────────────────────

declare -A RESOLVED=()
for platform in "${TARGETS[@]}"; do
    explicit="${TARGET_USERS[$platform]:-}"
    if ! username="$(resolve_username "$platform" "$explicit")"; then
        exit 1
    fi
    RESOLVED[$platform]="$username"
done

echo ""
echo -e "${BOLD}  Deploy Plan${NC}"
echo ""
for platform in "${TARGETS[@]}"; do
    echo -e "    ${PLATFORM_DISPLAY[$platform]}  →  user: ${CYAN}${RESOLVED[$platform]}${NC}"
done
echo ""

# ── Phase 1: Host Dependencies (once for all platforms) ──────────────────────

banner "Phase 1: Host Dependencies"

if $DRY_RUN; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC} Would install host deps: docker, node, git, curl, psql"
else
    host_ok=true

    # ── Distro detection ─────────────────────────────────────────────────
    # Returns: "arch" | "debian" | "unknown"
    # Covers Arch-based: arch, manjaro, endeavouros, cachyos, garuda, etc.
    # Covers Debian-based: debian, ubuntu, linuxmint, pop, etc.
    detect_distro() {
        if [[ ! -r /etc/os-release ]]; then echo "unknown"; return; fi
        local id id_like
        id="$(. /etc/os-release; echo "${ID:-unknown}")"
        id_like="$(. /etc/os-release; echo "${ID_LIKE:-}")"
        # Artix is Arch-based (pacman) but uses non-systemd init (OpenRC/runit).
        # Later phases rely on systemctl/loginctl — classify as unknown so we
        # don't silently break on a non-systemd system.
        if [[ "$id" == "artix" ]]; then echo "unknown"; return; fi
        case "$id" in
            arch|manjaro|endeavouros|cachyos|garuda)
                echo "arch"; return ;;
            debian|ubuntu|linuxmint|pop|elementary|kali|raspbian)
                echo "debian"; return ;;
        esac
        # Fallback: check ID_LIKE (e.g. "arch" or "debian ubuntu")
        # Skip artix via ID_LIKE too (it sets ID_LIKE=arch but is non-systemd)
        if [[ "$id_like" == *"arch"* && "$id" != "artix" ]]; then echo "arch"; return; fi
        if [[ "$id_like" == *"debian"* || "$id_like" == *"ubuntu"* ]]; then
            echo "debian"; return
        fi
        echo "unknown"
    }

    DISTRO="$(detect_distro)"

    # ── Omarchy detection ───────────────────────────────────────────────
    # Omarchy manages packages via omarchy-update (which runs migrations
    # alongside pacman). Running pacman directly risks missing config
    # migrations and conflicts with mise-managed runtimes (node, etc).
    OMARCHY=false
    if command -v omarchy-update &>/dev/null || [[ -d /home/*/.local/share/omarchy ]] 2>/dev/null; then
        OMARCHY=true
    fi

    echo -e "  ${CYAN}[DISTRO]${NC} ${DISTRO}$(${OMARCHY} && echo ' (Omarchy detected)')"

    # ── Debian: repair broken dpkg state before any apt calls ────────────
    if [[ "$DISTRO" == "debian" ]]; then
        repair_apt() {
            local attempt
            for attempt in 1 2 3; do
                local stuck
                stuck="$(dpkg -l 2>/dev/null | awk '/^.[FHU]/{print $2}')"
                if [[ -n "$stuck" ]]; then
                    echo -e "  ${CYAN}[FIX]${NC} Clearing broken packages (round ${attempt})..."
                    for pkg in $stuck; do
                        for s in postinst prerm postrm preinst; do
                            [[ -f "/var/lib/dpkg/info/${pkg}.${s}" ]] && printf '#!/bin/sh\nexit 0\n' > "/var/lib/dpkg/info/${pkg}.${s}"
                        done
                    done
                    dpkg --configure -a 2>/dev/null || true
                fi
                if DEBIAN_FRONTEND=noninteractive apt-get -f install -y -qq 2>/dev/null; then
                    return 0
                fi
            done
            echo -e "  ${YELLOW}[WARN]${NC} Could not fully repair apt — continuing anyway"
        }
        if ! apt-get install --dry-run coreutils &>/dev/null; then
            repair_apt
        fi
        apt-get update -qq 2>/dev/null || true
    fi

    # ── Systemd tools: required for Phase 2 on all distros ──────────────
    # Phase 2 (create-user.sh) calls loginctl (lingering) and systemctl
    # (user services). Check unconditionally — containers, WSL, and
    # non-systemd variants of any distro can report a known ID but still
    # lack these tools, leading to cryptic failures later.
    if ! command -v systemctl &>/dev/null || ! command -v loginctl &>/dev/null; then
        echo -e "  ${RED}[FAIL]${NC} systemd tools not found (systemctl/loginctl required by this installer)"
        echo -e "         Run on a system with systemd (Ubuntu, Debian, Arch) or ensure these tools are present."
        host_ok=false
    elif [[ "$DISTRO" == "unknown" ]]; then
        echo -e "  ${YELLOW}[WARN]${NC} Unrecognised distro — systemd found; continuing if tools are already installed"
        echo -e "         Phase 2+ may still fail if package managers or paths differ."
    fi

    # ── Arch: full sync + upgrade to avoid partial-upgrade breakage ─────
    # pacman -Sy alone (without -u) is dangerous on Arch rolling — new
    # package metadata + old binaries = partial-upgrade state.
    # Surface the error rather than swallowing it: a failed upgrade leaves
    # the host in an undefined state that will cause unpredictable failures.
    if [[ "$DISTRO" == "arch" ]]; then
        if $OMARCHY; then
            echo -e "  ${YELLOW}[SKIP]${NC} Skipping pacman -Syu — Omarchy detected"
            echo -e "         Use ${BOLD}omarchy-update${NC} to upgrade system packages safely"
        elif ! pacman -Syu --noconfirm; then
            echo -e "  ${YELLOW}[WARN]${NC} pacman -Syu failed — host may be in a partial-upgrade state"
            host_ok=false
        fi
    fi

    # ── Step 1: Install missing host packages ────────────────────────────

    # Docker
    # Only fail hard if at least one target platform actually requires Docker.
    # ZeroClaw and OpenClaw don't need it; NanoClaw and IronClaw do.
    # Build an explicit list of docker-requiring targets for accurate messages.
    docker_required=false
    docker_targets=()
    for _p in "${TARGETS[@]}"; do
        if [[ "${PLATFORM_DOCKER[$_p]:-no}" == "yes" ]]; then
            docker_required=true
            docker_targets+=("$_p")
        fi
    done

    if command -v docker &>/dev/null && docker info &>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    elif command -v docker &>/dev/null; then
        echo -e "  ${CYAN}[FIX]${NC} Docker not running — starting..."
        systemctl enable --now docker 2>/dev/null || true
        if docker info &>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC} Docker started"
        elif $docker_required; then
            echo -e "  ${RED}[FAIL]${NC} Docker won't start (required for: ${docker_targets[*]})"
            host_ok=false
        else
            echo -e "  ${YELLOW}[WARN]${NC} Docker installed but not running — OK (not required for: ${docker_targets[*]})"
        fi
    else
        echo -e "  ${CYAN}[INSTALL]${NC} Docker..."
        case "$DISTRO" in
            arch)
                # On Arch, the package is 'docker' (not docker.io).
                # Arch ships both iptables-legacy and iptables-nft; Docker needs nft
                # (legacy requires kernel modules not present on most Arch kernels).
                pacman -S --noconfirm --needed docker
                # Switch iptables to the nft backend — required on most Arch kernels
                # (legacy backend needs kernel modules Arch doesn't load by default).
                # Resolve via command -v to avoid dangling symlinks if a binary is missing.
                for _pair in "iptables:iptables-nft" "iptables-save:iptables-nft-save" "iptables-restore:iptables-nft-restore" "ip6tables:ip6tables-nft"; do
                    _dest="/usr/bin/${_pair%%:*}"
                    _src="$(command -v "${_pair##*:}" 2>/dev/null || true)"
                    if [[ -n "$_src" ]]; then
                        ln -sf "$_src" "$_dest"
                    else
                        echo -e "  ${YELLOW}[WARN]${NC} ${_pair##*:} not found — skipping ${_dest} symlink"
                    fi
                done
                systemctl enable --now docker 2>/dev/null || true
                ;;
            debian)
                apt-get install -y -qq --no-install-recommends docker.io
                systemctl enable --now docker
                ;;
            *)
                echo -e "  ${YELLOW}[WARN]${NC} Unknown distro — install Docker manually then re-run"
                if $docker_required; then host_ok=false; fi
                ;;
        esac
        # Check CLI presence first — "not installed" and "daemon not running"
        # are distinct failure modes; conflating them gives misleading output.
        if ! command -v docker &>/dev/null; then
            echo -e "  ${RED}[FAIL]${NC} Docker not installed"
            if $docker_required; then host_ok=false; fi
        elif docker info &>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC} Docker installed and running"
        elif $docker_required; then
            echo -e "  ${RED}[FAIL]${NC} Docker daemon not running (required for: ${docker_targets[*]})"
            host_ok=false
        else
            echo -e "  ${YELLOW}[WARN]${NC} Docker installed, daemon not running — OK (not required for: ${docker_targets[*]})"
        fi
    fi

    # Node.js
    # On Omarchy, platform scripts install node per-user via mise (the
    # Omarchy-native version manager). Don't install system nodejs/npm —
    # it conflicts with mise and breaks pacman -Syu if npm install -g is
    # ever used. On plain Arch/Debian, install system-wide as before.
    if $OMARCHY; then
        if command -v node &>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC} Node.js $(node --version) (mise-managed — skipping system install)"
        else
            echo -e "  ${YELLOW}[SKIP]${NC} Node.js — Omarchy detected; platform scripts install node per-user via mise"
        fi
    elif command -v node &>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} Node.js $(node --version)"
    else
        echo -e "  ${CYAN}[INSTALL]${NC} Node.js..."
        case "$DISTRO" in
            arch)
                # Arch ships Node.js in the official repos — no external repo needed
                # (version may be newer than the LTS pinned on Debian)
                pacman -S --noconfirm --needed nodejs npm
                ;;
            debian)
                apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg
                mkdir -p /etc/apt/keyrings
                if [[ ! -f /etc/apt/keyrings/nodesource.gpg ]]; then
                    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
                        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
                fi
                echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
                    > /etc/apt/sources.list.d/nodesource.list
                apt-get update -qq 2>/dev/null || true
                apt-get install -y -qq --no-install-recommends nodejs
                ;;
            *)
                echo -e "  ${YELLOW}[WARN]${NC} Unknown distro — install Node.js 22+ manually then re-run"
                host_ok=false
                ;;
        esac
        command -v node &>/dev/null && echo -e "  ${GREEN}[OK]${NC} Node.js $(node --version)" \
            || { echo -e "  ${RED}[FAIL]${NC} Node.js install failed"; host_ok=false; }
    fi

    # git, curl — essential
    for pkg in git curl; do
        if command -v "$pkg" &>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC} ${pkg}"
        else
            echo -e "  ${CYAN}[INSTALL]${NC} ${pkg}..."
            case "$DISTRO" in
                arch)   pacman -S --noconfirm --needed "$pkg" ;;
                debian) apt-get install -y -qq --no-install-recommends "$pkg" ;;
                *)      echo -e "  ${YELLOW}[WARN]${NC} Unknown distro — install ${pkg} manually" ;;
            esac
            command -v "$pkg" &>/dev/null && echo -e "  ${GREEN}[OK]${NC} ${pkg}" \
                || { echo -e "  ${RED}[FAIL]${NC} ${pkg} install failed"; host_ok=false; }
        fi
    done

    # psql — optional, for IronClaw DB verification
    if command -v psql &>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} psql $(psql --version | awk '{print $3}')"
    else
        echo -e "  ${CYAN}[INSTALL]${NC} postgresql client..."
        case "$DISTRO" in
            arch)
                # On Arch, psql is bundled in the full 'postgresql' package
                # (postgresql-libs only provides libpq). Skip on Omarchy to
                # avoid installing a full DB server for an optional CLI tool;
                # docker exec is the fallback for DB verification.
                if $OMARCHY; then
                    echo -e "  ${YELLOW}[SKIP]${NC} psql — skipping full postgresql package on Omarchy (docker exec will be used)"
                else
                    pacman -S --noconfirm --needed postgresql 2>/dev/null \
                        && echo -e "  ${GREEN}[OK]${NC} psql installed" \
                        || echo -e "  ${YELLOW}[WARN]${NC} psql install failed (optional — docker exec will be used)"
                fi
                ;;
            debian)
                apt-get install -y -qq --no-install-recommends postgresql-client 2>/dev/null \
                    && echo -e "  ${GREEN}[OK]${NC} psql installed" \
                    || echo -e "  ${YELLOW}[WARN]${NC} psql install failed (optional — docker exec will be used)"
                ;;
            *)
                echo -e "  ${YELLOW}[WARN]${NC} Unknown distro — psql optional, skipping"
                ;;
        esac
    fi

    # ── Step 2: Distro-agnostic checks ───────────────────────────────────

    # Disk space
    AVAIL_GB=$(( $(df --output=avail / | tail -1 | tr -d ' ') / 1024 / 1024 ))
    if (( AVAIL_GB >= 5 )); then
        echo -e "  ${GREEN}[OK]${NC} ${AVAIL_GB}GB disk available"
    else
        echo -e "  ${RED}[FAIL]${NC} Only ${AVAIL_GB}GB — need 5GB+"; host_ok=false
    fi

    # Kernel / Landlock (info only)
    KVER="$(uname -r)"; KMAJ="${KVER%%.*}"; KMIN="${KVER#*.}"; KMIN="${KMIN%%.*}"
    if (( KMAJ > 6 || (KMAJ == 6 && KMIN >= 17) )); then
        echo -e "  ${GREEN}[OK]${NC} Kernel ${KVER} (Landlock V5)"
    elif (( KMAJ > 5 || (KMAJ == 5 && KMIN >= 13) )); then
        echo -e "  ${GREEN}[OK]${NC} Kernel ${KVER} (Landlock basic)"
    else
        echo -e "  ${YELLOW}[WARN]${NC} Kernel ${KVER} — no Landlock (ZeroClaw will use fallback)"
    fi

    if ! $host_ok; then
        echo ""
        echo -e "${RED}${BOLD}Host dependency setup failed. Fix errors above.${NC}"
        exit 1
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}Host ready.${NC}"
fi

# ── Phase 2: Create Users ───────────────────────────────────────────────────

banner "Phase 2: Create Users"

for platform in "${TARGETS[@]}"; do
    user="${RESOLVED[$platform]}"
    needs_docker="${PLATFORM_DOCKER[$platform]}"

    if $DRY_RUN; then
        echo -e "  ${YELLOW}[DRY-RUN]${NC} Would create user: ${user} (docker: ${needs_docker})"
    else
        local_args=("$user")
        [[ "$needs_docker" == "yes" ]] && local_args+=("--docker")
        bash "${COMMON_DIR}/create-user.sh" "${local_args[@]}"
        save_user_for "$platform" "$user"
    fi
done

# ── Phase 3: Per-platform setup ─────────────────────────────────────────────

banner "Phase 3: Platform Setup"

# Collect manual steps to print at the end
MANUAL_STEPS=()

for platform in "${TARGETS[@]}"; do
    user="${RESOLVED[$platform]}"
    display="${PLATFORM_DISPLAY[$platform]}"

    echo ""
    echo -e "  ${BOLD}--- ${display} → ${user} ---${NC}"

    if $DRY_RUN; then
        echo -e "  ${YELLOW}[DRY-RUN]${NC} Would run: platforms/${platform}.sh as ${user}"
        continue
    fi

    # IronClaw: optionally set up PostgreSQL (libsql is the default now)
    # Set IRONCLAW_USE_POSTGRES=1 to enable PostgreSQL via Docker
    if [[ "$platform" == "ironclaw" ]] && [[ "${IRONCLAW_USE_POSTGRES:-}" == "1" ]]; then
        setup_ironclaw_postgres
    elif [[ "$platform" == "ironclaw" ]]; then
        echo -e "  ${GREEN}[OK]${NC} Using libsql (zero-config) — set IRONCLAW_USE_POSTGRES=1 for PostgreSQL"
    fi

    # Copy platform script to user's home (they can't traverse the admin home)
    user_home="$(eval echo "~${user}")"
    cp "${PLATFORMS_DIR}/${platform}.sh" "${user_home}/.platform-setup.sh"
    chown "${user}:${user}" "${user_home}/.platform-setup.sh"
    chmod 700 "${user_home}/.platform-setup.sh"

    echo -e "  ${BOLD}[RUN]${NC} Installing ${display}..."
    if su - "${user}" -c "bash ~/.platform-setup.sh" 2>&1; then
        rm -f "${user_home}/.platform-setup.sh"
        echo -e "  ${GREEN}[DONE]${NC} ${display} installed"
    else
        rm -f "${user_home}/.platform-setup.sh"
        echo -e "  ${RED}[ERROR]${NC} ${display} install failed"
        ERRORS=$((ERRORS + 1))
    fi
done

# ── Summary ──────────────────────────────────────────────────────────────────

banner "Summary"

if $DRY_RUN; then
    echo -e "  ${YELLOW}DRY RUN COMPLETE${NC}"
    echo ""
    exit 0
fi

for platform in "${TARGETS[@]}"; do
    check_platform_status "$platform"
done

echo ""

if (( ERRORS > 0 )); then
    echo -e "${RED}${BOLD}COMPLETED WITH ${ERRORS} ERROR(S)${NC}"
    exit 1
fi

echo -e "${GREEN}${BOLD}INSTALL COMPLETE${NC}"
echo ""

# ── Manual steps summary ────────────────────────────────────────────────────

echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  Manual Steps Required${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

for platform in "${TARGETS[@]}"; do
    user="${RESOLVED[$platform]}"
    display="${PLATFORM_DISPLAY[$platform]}"

    case "$platform" in
        zeroclaw)
            echo -e "  ${GREEN}${display} (${user}): No manual steps — fully automated!${NC}"
            echo "    Start: sudo -u ${user} -i bash -c 'systemctl --user enable --now zeroclaw'"
            echo ""
            ;;
        openclaw)
            echo -e "  ${YELLOW}${display} (${user}): Run interactive onboard${NC}"
            echo "    sudo -u ${user} -i"
            echo "    openclaw onboard"
            echo "    # After onboard: systemctl --user enable --now openclaw"
            echo ""
            ;;
        nanoclaw)
            echo -e "  ${YELLOW}${display} (${user}): Run Claude Code interactively${NC}"
            echo "    # Set auth first (subscription or API key):"
            echo "    #   claude setup-token  → CLAUDE_CODE_OAUTH_TOKEN in ~/.env"
            echo "    #   OR: ANTHROPIC_API_KEY=sk-ant-... in ~/.env"
            echo "    sudo -u ${user} -i"
            echo "    cd ~/nanoclaw && claude"
            echo "    /setup"
            echo "    /add-telegram"
            echo "    # After setup: systemctl --user enable --now nanoclaw"
            echo ""
            ;;
        ironclaw)
            echo -e "  ${GREEN}${display} (${user}): No interactive steps — env vars handle config${NC}"
            echo "    # Ensure ~/.env has ANTHROPIC_API_KEY or OPENROUTER_API_KEY"
            echo "    Start: sudo -u ${user} -i bash -c 'systemctl --user enable --now ironclaw'"
            echo ""
            ;;
    esac
done

echo "  Telegram setup: ${SCRIPT_DIR}/telegram-setup.md"
echo "  Status: sudo $0 --list"
echo ""
