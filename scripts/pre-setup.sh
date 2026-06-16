#!/usr/bin/env bash
# pre-setup.sh - verify workshop prerequisites and (best-effort) install
# anything missing before ./scripts/setup.sh runs.
#
# What it checks (in order):
#   1. OS detection (macOS, Linux distro, or WSL2)
#   2. git
#   3. curl  (needed by the Docker install path on Linux)
#   4. Docker engine + daemon reachable + user permission
#   5. docker compose v2 plugin
#   6. Disk space (~10 GB free recommended)
#   7. RAM       (8 GB recommended)
#
# Auto-install scope:
#   * Linux  - git/curl via apt|dnf|pacman; Docker via the official
#              convenience script (https://get.docker.com)
#   * macOS  - git via Homebrew; Docker Desktop via Homebrew cask (if
#              Homebrew exists; otherwise prints manual instructions)
#
# Requires sudo on Linux for installs. Asks before running sudo.
# Pass --yes / -y to skip prompts (useful for CI / classroom imaging).
#
# Re-runnable: every step is idempotent. Run it again any time.

# NOTE: no `-e` here - we want to keep checking even after one item fails.
set -uo pipefail

# ---------------------------------------------------------------------------
# Colors (graceful fallback on non-TTY).
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  RED=$(tput setaf 1);  GREEN=$(tput setaf 2);  YELLOW=$(tput setaf 3)
  CYAN=$(tput setaf 6); BOLD=$(tput bold);      RESET=$(tput sgr0)
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; RESET=""
fi

FAILS=0
WARNS=0
ASSUMED_YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUMED_YES=1

ok()    { printf "  ${GREEN}[ OK ]${RESET} %s\n" "$1"; }
fail()  { printf "  ${RED}[FAIL]${RESET} %s\n" "$1"; FAILS=$((FAILS + 1)); }
warn()  { printf "  ${YELLOW}[WARN]${RESET} %s\n" "$1"; WARNS=$((WARNS + 1)); }
info()  { printf "  ${CYAN}[INFO]${RESET} %s\n" "$1"; }
hr()    { printf "\n${BOLD}%s${RESET}\n" "$1"; }

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# Ask y/n. bash 3.2 compatible (no ${var,,}).
ask() {
  [[ $ASSUMED_YES -eq 1 ]] && return 0
  local ans
  read -r -p "  $1 [y/N] " ans </dev/tty
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Detect OS into one of: macos, wsl, linux:<id>, unknown
detect_os() {
  if [[ "${OSTYPE:-}" == "darwin"* ]]; then
    echo "macos"
  elif [[ -f /proc/version ]] && grep -qi microsoft /proc/version; then
    echo "wsl"
  elif [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "linux:${ID:-unknown}"
  else
    echo "unknown"
  fi
}

# Install a single named package on Linux via the distro's package manager.
install_linux_pkg() {
  local pkg="$1"
  case "$DISTRO" in
    ubuntu|debian|linuxmint|pop)
      sudo apt-get update -qq && sudo apt-get install -y "$pkg" ;;
    fedora|rhel|centos|rocky|almalinux)
      sudo dnf install -y "$pkg" ;;
    arch|manjaro|endeavouros)
      sudo pacman -S --noconfirm "$pkg" ;;
    *)
      fail "Auto-install for distro '$DISTRO' not supported. Install '$pkg' manually."
      return 1 ;;
  esac
}

install_docker_linux() {
  info "Installing Docker via the official convenience script..."
  curl -fsSL https://get.docker.com | sudo sh
  sudo systemctl enable --now docker 2>/dev/null || true
  sudo usermod -aG docker "$USER"
  warn "Added '$USER' to the 'docker' group. You MUST log out and back in"
  warn "(or run 'newgrp docker' in a new shell) before running setup.sh."
}

install_docker_mac() {
  if have brew; then
    info "Installing Docker Desktop via Homebrew..."
    brew install --cask docker
    warn "Now open /Applications/Docker.app, accept the privileges prompt,"
    warn "and wait for the whale icon in the menu bar before running setup.sh."
  else
    fail "Homebrew is not installed. Either:"
    fail "  1. Install Homebrew first:  https://brew.sh"
    fail "  2. Or download Docker Desktop manually:"
    fail "     https://www.docker.com/products/docker-desktop"
  fi
}

# ---------------------------------------------------------------------------
# 1. OS detection
# ---------------------------------------------------------------------------
hr "Workshop pre-setup checks"

OS=$(detect_os)
DISTRO="${OS#linux:}"
info "Detected OS: ${OS}"

case "$OS" in
  macos|linux:*|wsl) ;;
  *)
    fail "Unsupported OS. This script targets macOS, Linux, and WSL2 only."
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# 2. git
# ---------------------------------------------------------------------------
hr "git"
if have git; then
  ok "git installed ($(git --version))"
else
  fail "git not found"
  if ask "Install git now?"; then
    case "$OS" in
      macos)        have brew && brew install git || fail "Install Homebrew first: https://brew.sh" ;;
      linux:*|wsl)  install_linux_pkg git ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# 3. curl (Linux only; macOS ships with it; Docker install needs it on Linux)
# ---------------------------------------------------------------------------
if [[ "$OS" =~ ^(linux:|wsl) ]]; then
  hr "curl"
  if have curl; then
    ok "curl installed"
  else
    fail "curl not found"
    if ask "Install curl now?"; then
      install_linux_pkg curl
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. Docker engine
# ---------------------------------------------------------------------------
hr "Docker"
if have docker; then
  ok "docker installed ($(docker --version))"
  if docker info >/dev/null 2>&1; then
    ok "docker daemon reachable + user has permission"
  else
    fail "docker daemon not reachable (or user not in 'docker' group)"
    case "$OS" in
      linux:*|wsl)
        warn "Start the daemon:        sudo systemctl start docker"
        warn "Add yourself to group:   sudo usermod -aG docker \$USER"
        warn "Then log out and back in (or 'newgrp docker' in a new shell)." ;;
      macos)
        warn "Open Docker Desktop from /Applications and wait for it to finish starting." ;;
    esac
  fi
else
  fail "docker not found"
  if ask "Install Docker now?"; then
    case "$OS" in
      macos)        install_docker_mac ;;
      linux:*|wsl)  install_docker_linux ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# 5. docker compose v2
# ---------------------------------------------------------------------------
hr "docker compose v2"
if docker compose version >/dev/null 2>&1; then
  ok "docker compose v2 available ($(docker compose version | head -n1))"
else
  fail "'docker compose' v2 plugin not found (the script uses 'docker compose', not 'docker-compose')"
  case "$OS" in
    macos)
      warn "Reinstall Docker Desktop - v2 is built in." ;;
    linux:ubuntu|linux:debian|linux:linuxmint|linux:pop|wsl)
      if ask "Install docker-compose-plugin via apt?"; then
        sudo apt-get update -qq && sudo apt-get install -y docker-compose-plugin
      fi ;;
    linux:fedora|linux:rhel|linux:centos|linux:rocky|linux:almalinux)
      if ask "Install docker-compose-plugin via dnf?"; then
        sudo dnf install -y docker-compose-plugin
      fi ;;
    linux:arch|linux:manjaro|linux:endeavouros)
      warn "Docker on Arch typically bundles compose v2. Try: sudo pacman -S docker-compose" ;;
    *)
      warn "Install the v2 plugin per https://docs.docker.com/compose/install/" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 6. Disk space (POSIX df works the same on macOS BSD and Linux GNU).
# ---------------------------------------------------------------------------
hr "Disk space"
if free_kb=$(df -P -k . 2>/dev/null | awk 'NR==2 {print $4}'); then
  free_gb=$(( free_kb / 1024 / 1024 ))
  if [[ "$free_gb" -ge 10 ]]; then
    ok "${free_gb} GB free in $(pwd)"
  else
    warn "Only ${free_gb} GB free; workshop needs ~10 GB (5 GB images + 5 GB model)"
  fi
else
  warn "Could not measure free disk space."
fi

# ---------------------------------------------------------------------------
# 7. RAM
# ---------------------------------------------------------------------------
hr "RAM"
case "$OS" in
  macos)
    total_ram_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 )) ;;
  linux:*|wsl)
    total_ram_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0) ;;
  *)
    total_ram_gb=0 ;;
esac

if [[ "$total_ram_gb" -ge 8 ]]; then
  ok "RAM: ${total_ram_gb} GB"
elif [[ "$total_ram_gb" -gt 0 ]]; then
  warn "Only ${total_ram_gb} GB RAM; workshop needs at least 8 GB (16 GB comfortable)"
else
  warn "Could not measure RAM."
fi

# ---------------------------------------------------------------------------
# Final summary.
# ---------------------------------------------------------------------------
echo
hr "Summary"
if [[ $FAILS -eq 0 ]]; then
  ok  "All prerequisites met."
  if [[ $WARNS -gt 0 ]]; then
    warn "${WARNS} warning(s) above - workshop will run, but read them."
  fi
  cat <<EOF

  ${BOLD}Next step:${RESET}  ./scripts/setup.sh

EOF
  exit 0
else
  fail "${FAILS} prerequisite(s) still missing."
  cat <<EOF

  Fix the [${RED}FAIL${RESET}] items above, then re-run:
      ${BOLD}./scripts/pre-setup.sh${RESET}

  (Re-run is safe: every check is idempotent.)

EOF
  exit 1
fi
