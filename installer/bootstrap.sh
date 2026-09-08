#!/usr/bin/env bash
# bootstrap.sh — baked into the GNOMS installer ISO.
# Fetches the latest GNOMS from master and hands over to the real installer.
# Kept tiny on purpose: the installer logic always comes from the repo,
# so the USB never goes stale.
set -euo pipefail

REPO_URL="https://github.com/GerhardMe/GNOMS.git"
BRANCH="master"
WORK="/tmp/gnoms"

# ISO default keymap. The chosen layout is written to KEYMAP_FILE so the
# real installer (cloned below) can use it as the default for its own
# keyboard_layout question — answered once, used twice.
DEFAULT_KEYMAP="no"
KEYMAP_FILE="/tmp/gnoms-keymap"

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

# -------------------- Root --------------------
# The ISO auto-logs in as 'nixos'; re-exec through sudo instead of dying.
if [ "$(id -u)" -ne 0 ]; then
	command -v sudo &>/dev/null || die "Must run as root."
	exec sudo "$0" "$@"
fi

# -------------------- Keyboard --------------------
step "Keyboard layout (current default: ${DEFAULT_KEYMAP})"
while true; do
	read -r -p "Layout (Enter = ${DEFAULT_KEYMAP}, 'list' for common ones): " km || km=""
	km="${km:-$DEFAULT_KEYMAP}"
	if [ "$km" = "list" ]; then
		echo "Common: no us gb de fr es it se dk fi pl nl pt br cz ru jp"
		continue
	fi
	if loadkeys "$km" 2>/dev/null; then
		success "Keyboard layout: $km"
		printf '%s\n' "$km" > "$KEYMAP_FILE"
		break
	fi
	echo -e "${RED}Unknown layout '$km'.${RESET} Try again ('list' shows common layouts)."
done

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
