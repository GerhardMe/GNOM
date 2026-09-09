#!/usr/bin/env bash
# ui.sh — the shared look of the GNOMS installer scripts (bootstrap.sh,
# install.sh, build-iso.sh). Sourced, never run. Colors are TTY-gated like
# reconfigure.sh, so logs stay free of escape codes.
#
# The logo is user/logo.txt — referenced, never copied:
#   • install.sh / build-iso.sh set GNOMS_LOGO=<repo>/user/logo.txt
#   • the ISO ships it at /etc/gnoms/logo.txt (iso.nix), because bootstrap
#     runs before the repo exists on the machine.

if [ -t 1 ]; then
	GREEN="\033[1;32m"
	PURPLE="\033[38;2;135;0;255m"
	RED="\033[1;31m"
	YELLOW="\033[1;33m"
	BOLD="\033[1m"
	DIM="\033[2m"
	RESET="\033[0m"
else
	GREEN=""; PURPLE=""; RED=""; YELLOW=""; BOLD=""; DIM=""; RESET=""
fi

GNOMS_LOGO="${GNOMS_LOGO:-/etc/gnoms/logo.txt}"

# -------------------- Messages --------------------
step()    { echo -e "${PURPLE}[  ▶▶  ]${RESET} $1"; }
success() { echo -e "${GREEN}[  OK  ]${RESET} $1"; }
warn()    { echo -e "${YELLOW}[ WARN ]${RESET} $1"; }
die()     { echo -e "${RED}[  !!  ]${RESET} $1" >&2; exit 1; }

# -------------------- Prompts --------------------
# Every question looks the same:   ? Question [default]:
# Leading whitespace in the question is dropped so callers may indent freely.
_q() { local p="$1"; p="${p#"${p%%[![:space:]]*}"}"; echo -e "  ${PURPLE}?${RESET} ${p}"; }

ask()     { local v; read -r -p "$(_q "$1") " v; echo "$v"; }
ask_def() {	# ask_def QUESTION DEFAULT — an empty default shows no brackets
	local v d=""
	[ -n "$2" ] && d=" $(echo -e "${DIM}[$2]${RESET}")"
	read -r -p "$(_q "$1")${d}: " v
	echo "${v:-$2}"
}
confirm() { local a; read -r -p "$(_q "$1") [y/N]: " a; [[ "$a" =~ ^[Yy] ]]; }
ask_secret() { local v; read -r -s -p "$(_q "$1") " v; echo >&2; echo "$v"; }

# -------------------- Headings --------------------
# banner [subtitle] — the logo plus the project name, once at the start.
banner() {
	echo -e "${PURPLE}"
	[ -r "$GNOMS_LOGO" ] && cat "$GNOMS_LOGO"
	echo
	echo -e "${BOLD}            G N O M S${RESET}${PURPLE}   Gerhard's NixOS Management System${RESET}"
	[ -n "${1:-}" ] && echo -e "${DIM}            ${1}${RESET}"
	echo
}

# section "Title" — a ruled heading between stages.
section() {
	local t=" $1 " pad
	pad=$(printf '%*s' $(( 62 - ${#t} )) '')
	echo
	echo -e "${PURPLE}──${BOLD}${t}${RESET}${PURPLE}${pad// /─}${RESET}"
	echo
}
