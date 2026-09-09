#!/usr/bin/env bash
# bootstrap.sh — baked into the GNOMS installer ISO (with ui.sh inlined
# above it by iso.nix). Fetches GNOMS and hands over to the real installer.
# Kept tiny on purpose: the installer logic always comes from the repo, so
# the USB never goes stale.
#
# Which repo gets installed — three layers, easiest first:
#   1. The prompt below always lets you type any URL at install time.
#   2. DEFAULT_REPO_URL (one line, right here) is what Enter picks — change
#      it when you port the installer to your own fork.
#   3. build-iso.sh overrides that default with the building checkout's
#      `git remote get-url origin` (GNOMS_REPO_URL), so a fork's ISO already
#      defaults to the fork with zero edits.
set -euo pipefail

# ┌─────────────────── edit me to port the installer ───────────────────┐
DEFAULT_REPO_URL="https://github.com/GerhardMe/GNOMS.git"
# └─────────────────────────────────────────────────────────────────────┘
REPO_URL="${GNOMS_REPO_URL:-$DEFAULT_REPO_URL}"
BRANCH="${GNOMS_REPO_BRANCH:-}"  # empty = the remote's default branch
WORK="/tmp/gnoms"

# ISO default keymap. The chosen layout is written to KEYMAP_FILE so the
# real installer (cloned below) can use it as the default for its own
# keyboard_layout question — answered once, used twice.
DEFAULT_KEYMAP="no"
KEYMAP_FILE="/tmp/gnoms-keymap"

# On the ISO, ui.sh is inlined above this script; run straight from a
# checkout, source it from next to this file.
declare -f step >/dev/null 2>&1 || source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

# -------------------- Root --------------------
# The ISO auto-logs in as 'nixos'; re-exec through sudo instead of dying.
if [ "$(id -u)" -ne 0 ]; then
	command -v sudo &>/dev/null || die "Must run as root."
	exec sudo "$0" "$@"
fi

banner "installer"

# -------------------- Keyboard --------------------
section "Keyboard"
while true; do
	km=$(ask_def "Layout ('list' shows common ones)" "$DEFAULT_KEYMAP")
	if [ "$km" = "list" ]; then
		echo "    no us gb de fr es it se dk fi pl nl pt br cz ru jp"
		continue
	fi
	if loadkeys "$km" 2>/dev/null; then
		success "Keyboard layout: $km"
		printf '%s\n' "$km" > "$KEYMAP_FILE"
		break
	fi
	warn "Unknown layout '$km' — try again ('list' shows common layouts)."
done

# -------------------- Repo --------------------
section "Repository"
echo "  GNOMS is meant to be forked and spun. Point this at your own copy."
REPO_URL=$(ask_def "Git URL to install" "$REPO_URL")
[ -n "$BRANCH" ] && echo "    branch: $BRANCH"

step "Checking network…"
# Reach the repo's host over HTTP (any response counts; -f is off on
# purpose) instead of pinging github.com — forks may live elsewhere, and
# ICMP is often blocked.
curl -sS -o /dev/null --max-time 8 "$REPO_URL" 2>/dev/null ||
	die "Cannot reach ${REPO_URL}. Run 'nmtui' to connect to Wi-Fi, then run 'gnoms' again."
success "Network is up."

step "Fetching ${REPO_URL}${BRANCH:+ (${BRANCH})}…"
# Full clone, not shallow: the installer derives its questions from this
# copy and later moves this very copy onto the new system (~/GNOMS), so
# questions and installed repo are always the same commit.
rm -rf "$WORK"
git clone ${BRANCH:+--branch "$BRANCH"} "$REPO_URL" "$WORK" ||
	die "Failed to clone $REPO_URL"
success "GNOMS fetched."

# -------------------- Hand over --------------------
step "Launching installer…"
export GNOMS_REPO_URL="$REPO_URL"   # fallback for the installer's repo_url
export GNOMS_BOOTSTRAPPED=1         # banner already on screen
exec bash "$WORK/installer/install.sh" "$WORK"
