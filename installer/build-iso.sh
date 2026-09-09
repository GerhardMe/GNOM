#!/usr/bin/env bash
# build-iso.sh — build the GNOMS installer ISO with *this* repo baked in.
#
# The ISO's `gnoms` command clones a repo at install time. Which repo is not
# hardcoded anywhere: this script reads the checkout's `git remote get-url
# origin`, rewrites an SSH remote to HTTPS (the live ISO has no keys), and
# hands it to iso.nix via GNOMS_REPO_URL (`nix build --impure`). A fork
# therefore builds an ISO that installs the fork, with zero edits.
#
# Usage:  installer/build-iso.sh                (auto-derive URL)
#         GNOMS_REPO_URL=https://… installer/build-iso.sh      (override)
#         GNOMS_REPO_BRANCH=dev installer/build-iso.sh  (pin a branch; default:
#                                                        the remote's default)
# Result: installer/result/iso/*.iso  (symlink; `result` is gitignored)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT="$ROOT/installer/result"

GNOMS_LOGO="$ROOT/user/logo.txt"
source "$ROOT/installer/ui.sh"
banner "ISO build"

# git@host:owner/repo.git → https://host/owner/repo.git ; ssh://git@host/… → https://host/…
to_https() {
	local u="$1"
	case "$u" in
		git@*:*)      u="${u#git@}"; u="https://${u/:/\/}" ;;
		ssh://git@*)  u="https://${u#ssh://git@}" ;;
		ssh://*)      u="https://${u#ssh://}"; u="${u/\/\/*@/\/\/}" ;;
	esac
	echo "$u"
}

url="${GNOMS_REPO_URL:-}"
if [ -z "$url" ]; then
	url=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
fi
if [ -n "$url" ]; then
	url=$(to_https "$url")
	success "Repo baked into the ISO: $url${GNOMS_REPO_BRANCH:+ (branch ${GNOMS_REPO_BRANCH})}"
else
	warn "Not a git checkout with an 'origin' remote and GNOMS_REPO_URL unset —"
	warn "the ISO will ask for the repo URL at install time."
fi

step "Building ISO (nix build --impure ${ROOT}/nixos#iso)…"
GNOMS_REPO_URL="$url" GNOMS_REPO_BRANCH="${GNOMS_REPO_BRANCH:-}" \
	nix build --impure "$ROOT/nixos#iso" -o "$OUT"

iso=$(ls "$OUT"/iso/*.iso | head -1)
success "ISO ready: $iso ($(du -h "$iso" | cut -f1))"
echo "  Write it:  sudo dd if=$iso of=/dev/sdX bs=4M status=progress oflag=sync"
