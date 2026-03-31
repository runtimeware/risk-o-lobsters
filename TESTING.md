# Testing Guide — Risk of Lobsters

This guide explains how to test the setup scripts using disposable virtual machines (VMs).
You don't need to understand the technical details — just follow the steps.

---

## What Are We Testing?

When you run `./setup.sh`, it installs AI agent platforms onto your Linux machine.
The setup scripts detect which Linux distro you're using and install the right packages.

This guide shows how to test that in a **safe, throwaway VM** — so you can verify
things work before touching a real machine.

---

## Prerequisites

You need:
- **Vagrant** installed (`vagrant --version` should work)
- **A VM provider** — one of:
  - `libvirt` (Linux — recommended)
  - Parallels (Mac Apple Silicon)
  - VirtualBox (fallback)

---

## Test 1: Ubuntu / Debian

Tests that the original Debian/Ubuntu install path still works correctly.

### Steps

```bash
# 1. Go to the Ubuntu test folder
cd tests/ubuntu

# 2. Start the VM (downloads ~1GB Ubuntu image first time)
vagrant up --provider=libvirt

# 3. Run the full install inside the VM
vagrant ssh -c "sudo bash /project/setup/install.sh zeroclaw --as zlatan"

# 4. Check the result — should say "INSTALL COMPLETE"

# 5. Tear down the VM when done
vagrant destroy -f
```

### Expected result

```
[DISTRO] debian
[OK]     Docker installed and running
[OK]     Node.js v22.22.0
[OK]     git
[OK]     curl
[OK]     psql installed
[OK]     Host ready.
...
[OK]     User 'zlatan' created
...
[DONE]   ZeroClaw installed
INSTALL COMPLETE
```

---

## Test 2: Arch Linux

Tests the new Arch Linux install path added in this PR.

> **Note:** The test VM uses an older kernel that prevents Docker's networking
> stack from loading. On real Arch hardware, Docker works fine. The test VM
> correctly installs the Docker package and shows a warning (not an error)
> when targeting ZeroClaw, which doesn't need Docker.

### Steps

```bash
# 1. Go to the project root (where Vagrantfile lives)
cd /path/to/risk-o-lobsters

# 2. Start the Arch VM
#    First run downloads the box (~700MB) and updates the system (~5 min)
vagrant up --provider=libvirt

# 3. Run the full install inside the VM
vagrant ssh -c "sudo bash /project/setup/install.sh zeroclaw --as zlatan"

# 4. Check the result — should say "INSTALL COMPLETE"

# 5. Tear down the VM
vagrant destroy -f
```

### Expected result

```
[DISTRO] arch
[WARN]   Docker installed but not running — OK (not required for: zeroclaw)
[OK]     Node.js v25.8.2
[OK]     git
[OK]     curl
[OK]     psql installed
[OK]     Host ready.
...
[OK]     User 'zlatan' created
...
[DONE]   ZeroClaw installed
INSTALL COMPLETE
```

---

## Test Results (Verified 2026-03-28)

Both tests were run on `galway` (Ubuntu 24.04 host, libvirt provider).

### Ubuntu 24.04 ✅

| Check | Result |
|-------|--------|
| Distro detection | `debian` ✅ |
| Docker (`docker.io`) | 28.2.2 ✅ |
| Node.js (nodesource) | v22.22.0 ✅ |
| git | 2.43.0 ✅ |
| curl | 8.5.0 ✅ |
| psql (`postgresql-client`) | 16.13 ✅ |
| User creation | ✅ |
| ZeroClaw install | 0.6.5 ✅ |
| ZeroClaw service | running ✅ |
| Doctor summary | 19 ok, 3 warnings, 1 error (daemon not running — expected, no API key) |

### Arch Linux 6.8.7 ✅

| Check | Result |
|-------|--------|
| Distro detection | `arch` ✅ |
| Docker (`docker`) | 29.3.1 installed ✅ (daemon blocked by VM kernel — expected, see note above) |
| iptables-nft symlinks | ✅ |
| Node.js (official repos) | v25.8.2 ✅ |
| npm | 11.12.1 ✅ |
| git | 2.53.0 ✅ |
| curl | 8.19.0 ✅ |
| psql (`postgresql`) | 18.3 ✅ |
| User creation | ✅ |
| ZeroClaw install | 0.6.5 ✅ |
| ZeroClaw service | installed (stopped — no API key) ✅ |
| Doctor summary | 13 ok, 4 warnings, 1 error (daemon not running — expected, no API key) |

---

## Omarchy (Arch + mise) Compatibility

Omarchy is an opinionated Arch Linux desktop that manages runtimes via
[mise](https://mise.jdx.dev/) and packages via `omarchy-update`. The setup
scripts detect Omarchy automatically and adjust their behavior:

| Area | Plain Arch | Omarchy |
|------|-----------|---------|
| **System upgrade** | `pacman -Syu --noconfirm` | Skipped — use `omarchy-update` |
| **Node.js / npm** | `pacman -S nodejs npm` | Skipped — platform scripts install per-user via mise |
| **PostgreSQL (psql)** | `pacman -S postgresql` (full server) | Skipped — `docker exec` fallback used |
| **Docker, git, curl** | Installed if missing | Same (already present on Omarchy) |

### Why not pacman for Node.js?

- Omarchy deliberately uses mise, not pacman, for runtimes
- `pacman -S npm` creates a system-wide npm that conflicts with mise
- If anyone runs `npm install -g` with the pacman npm, it writes files
  outside pacman's tracking and **breaks future `pacman -Syu`**
- Platform users (nancy, ollie) get their own mise-managed node — clean
  teardown when `userdel -r` removes their home directory

### Detection

Omarchy is detected when `omarchy-update` is on PATH or
`~/.local/share/omarchy/` exists for any user. When detected, `install.sh`
prints `[DISTRO] arch (Omarchy detected)`.

---

## Supported Linux Distros

The setup scripts now support:

| Family | Distros |
|--------|---------|
| **Debian/Ubuntu** | Ubuntu, Debian, Linux Mint, Pop!_OS, elementary OS, Kali |
| **Arch** | Arch Linux, Manjaro, EndeavourOS, CachyOS, Garuda |
| **Arch + Omarchy** | Full support with mise-based node isolation |

Any distro that declares itself Arch-based via `/etc/os-release` is supported.

---

## What Doesn't Change

- **`create-user.sh`** — works identically on all distros (uses standard Linux tools: `useradd`, `systemctl`, `loginctl`). On systems with mise, it also activates mise in the user's `.profile`.
- **Platform scripts** (`platforms/*.sh`) — all distro-agnostic; they use per-user version managers (`mise`, `fnm`, `nvm`, `curl`) that don't depend on the system package manager

---

## Troubleshooting

**VM won't boot:**
```bash
vagrant up --debug 2>&1 | tail -30
```

**Stale Arch box / GPG errors:**
The Vagrantfile handles this automatically (disables signature checking to
pull a fresh `archlinux-keyring`, then re-enables it before the full upgrade).
If it still fails, try: `vagrant destroy -f && vagrant up`

**Wrong provider used:**
```bash
vagrant up --provider=libvirt   # Linux
vagrant up --provider=parallels # Mac Apple Silicon
vagrant up --provider=virtualbox # Fallback
```
