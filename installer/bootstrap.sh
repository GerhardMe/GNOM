#!/usr/bin/env bash
# bootstrap.sh — baked into the GNOMS installer ISO.
# Fetches the latest GNOMS from master and hands over to the real installer.
# Kept tiny on purpose: the installer logic always comes from the repo,
# so the USB never goes stale.
set -euo pipefail

REPO_URL="https://github.com/GerhardMe/GNOMS.git"
BRANCH="master"
WORK="/tmp/gnoms"

# -------------------- Colors --------------------
GREEN="\033[1;32m"
PURPLE="\033[38;2;135;0;255m"
RED="\033[1;31m"
RESET="\033[0m"

step() { echo -e "${PURPLE}[  ▶▶  ]${RESET} $1"; }
success() { echo -e "${GREEN}[  OK  ]${RESET} $1"; }
die() { echo -e "${RED}[  !!  ]${RESET} $1" >&2; exit 1; }

echo -e "${PURPLE}"
cat <<'EOF'
   ██████╗ ███╗   ██╗ ██████╗ ███╗   ███╗ ███████╗
  ██╔════╝ ████╗  ██║██╔═══██╗████╗ ████║ ██╔════╝
  ██║  ███╗██╔██╗ ██║██║   ██║██╔████╔██║ ███████╗
  ██║   ██║██║╚██╗██║██║   ██║██║╚██╔╝██║ ╚════██║
  ╚██████╔╝██║ ╚████║╚██████╔╝██║ ╚═╝ ██║ ███████║
   ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝ ╚═╝     ╚═╝ ╚══════╝
        Gerhard's NixOS Management System — installer
EOF
echo -e "${RESET}"

[ "$(id -u)" -eq 0 ] || die "Must run as root. (On the ISO: the 'nixos' user has passwordless sudo — just run: gnoms)"

step "Checking network…"
ping -c1 -W3 github.com &>/dev/null ||
	die "No network. Run 'nmtui' to connect to Wi-Fi, then run 'gnoms' again."
success "Network is up."

step "Fetching latest GNOMS (${BRANCH})…"
rm -rf "$WORK"
git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$WORK" ||
	die "Failed to clone $REPO_URL"
success "GNOMS fetched."

step "Launching installer…"
exec sudo bash "$WORK/installer/install.sh" "$WORK"
