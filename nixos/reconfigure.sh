#!/usr/bin/env bash
set -euo pipefail

# -------------------- Colors --------------------
# Colorized output only when stdout is a real terminal; piped or redirected
# output (logs, tee) stays free of ANSI escape codes.
if [ -t 1 ]; then
	GREEN="\033[1;32m"
	PURPLE="\033[38;2;135;0;255m"
	RED="\033[1;31m"
	RESET="\033[0m"
else
	GREEN=""
	PURPLE=""
	RED=""
	RESET=""
fi

# -------------------- Paths --------------------
# The repo lives at ~/GNOMS (see README bootstrap). Everything derives from that.
REPO_ROOT="$HOME/GNOMS"
REPO_DIR="$REPO_ROOT/nixos"
TARGET_DIR="/etc/nixos"
COREDOT="$REPO_ROOT/dotfiles"
DOT="$HOME/.config"
CORESCR="$REPO_ROOT/scripts"
EXE="$HOME/.local/bin"
USER_DIR="$REPO_ROOT/user"

# -------------------- Tuning --------------------
TOP_FADE="$HOME/.cache/gnoms/top_fade.png" # consumed by dotfiles/wezterm.lua
FADE_HEIGHT=80                             # px of gradient at the screen's top edge
FADE_WIDTH_FALLBACK=3840                   # used when screen geometry can't be read
BAR_COLOR_FALLBACK="#404040"               # used when theme.lua bg_normal can't be read

# -------------------- Dotfiles --------------------
# One line each: repo source|$HOME/.config destination. Adding a dotfile = one line.
DOTFILES=(
	"$COREDOT/dunst.conf|$DOT/dunst/dunstrc"
	"$COREDOT/udiskie.yml|$DOT/udiskie/config.yml"
	"$COREDOT/rofi.rasi|$DOT/rofi/config.rasi"
	"$COREDOT/fish/prompt.fish|$DOT/fish/functions/fish_prompt.fish"
	"$COREDOT/fish/prompt_right.fish|$DOT/fish/functions/fish_right_prompt.fish"
	"$COREDOT/fish/startup.fish|$DOT/fish/config.fish"
	"$COREDOT/fish/theme.fish|$DOT/fish/conf.d/fish_frozen_theme.fish"
	"$COREDOT/awesome/main.lua|$DOT/awesome/rc.lua"
	"$COREDOT/awesome/statusbar.lua|$DOT/awesome/statusbar.lua"
	"$COREDOT/awesome/theme.lua|$DOT/awesome/theme.lua"
	"$COREDOT/wezterm.lua|$DOT/wezterm/wezterm.lua"
	"$COREDOT/cava.conf|$DOT/cava/config"
	"$COREDOT/nvim/init.lua|$DOT/nvim/init.lua"
	"$COREDOT/nvim/lua/keymaps.lua|$DOT/nvim/lua/keymaps.lua"
	"$COREDOT/nvim/lua/options.lua|$DOT/nvim/lua/options.lua"
	"$COREDOT/nvim/lua/plugins.lua|$DOT/nvim/lua/plugins.lua"
	"$COREDOT/nvim/lua/theme.lua|$DOT/nvim/lua/theme.lua"
	"$COREDOT/nvim/lua/autocmd.lua|$DOT/nvim/lua/autocmd.lua"
	"$COREDOT/qbittorrent.conf|$DOT/qBittorrent/qBittorrent.conf"
	"$COREDOT/fastfetch.jsonc|$DOT/fastfetch/config.jsonc"
)

# -------------------- Helper functions --------------------
step() { echo -e "${PURPLE}[  ▶▶  ]${RESET} $1"; }
success() { echo -e "${GREEN}[  OK  ]${RESET} $1"; }
error() { echo -e "${RED}[  !!  ]${RESET} $1" >&2; }

# This script must live in the repo, not a copy of it — refuse to run from
# anywhere else (readlink -f also handles the ~/.local/bin/reconfigure symlink).
if [ "$(readlink -f "${BASH_SOURCE[0]}")" != "$REPO_DIR/reconfigure.sh" ]; then
	error "Script is not running from $REPO_DIR"
	error "GNOMS expects the repo at ~/GNOMS: git clone https://github.com/GerhardMe/GNOMS ~/GNOMS"
	exit 1
fi

copy() {
	local src="$1" dest="$2"
	mkdir -p "$(dirname "$dest")"
	if cp -f "$src" "$dest"; then
		success "Copied $src → $dest"
	else
		error "Failed to copy $src → $dest"
		return 1
	fi
}

link() {
	local target="$1" dest="$2"
	mkdir -p "$(dirname "$dest")"
	if ln -sf "$target" "$dest"; then
		chmod +x "$dest"
		success "Linked $dest → $target"
	else
		error "Failed to link $dest → $target"
		return 1
	fi
}

kill_clients_on_workspace() {
	local tag="$1"
	awesome-client <<EOF || true
for _, c in ipairs(client.get()) do
  if c.first_tag and c.first_tag.name == "${tag}" then
    c:kill()
  end
end
EOF
}

save_visible_tags() {
	local raw
	# Single round-trip: one line per screen, "screen:tag". awesome-client
	# quotes the value and prefixes only the first line with `string "` —
	# strip that, then the quotes, then keep lines starting "N:" (tag names
	# may contain spaces; leading indentation is all that's removed).
	raw=$(awesome-client '
		local out = {}
		for s in screen do
			local t = s.selected_tag
			out[#out+1] = s.index .. ":" .. (t and t.name or "")
		end
		return table.concat(out, "\n")
	' 2>/dev/null \
		| sed 's/^[[:space:]]*string[[:space:]]*//' \
		| tr -d '"' \
		| sed -n 's/^[[:space:]]*\([0-9][0-9]*\):/\1:/p') || true
	: >/tmp/awesome-visible-tags
	if [ -n "$raw" ]; then
		printf '%s\n' "$raw" >>/tmp/awesome-visible-tags
		success "Saved tags: $(printf '%s' "$raw" | tr '\n' ' ' | sed 's/ $//')"
	else
		success "No visible tags found"
	fi
}

# -------------------- Fade --------------------
# WezTerm draws this gradient over the terminal's top edge so it blends into
# the awesome bar. Lua owns the color: read it straight out of the deployed
# theme. Needs X to ask for the real screen width.
generate_fade() {
	if ! command -v magick >/dev/null; then
		error "magick not found; skipping top fade."
		return 0
	fi
	local bar_color width
	bar_color=$(sed -n 's/.*theme.bg_normal[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$DOT/awesome/theme.lua" 2>/dev/null) || true
	bar_color="${bar_color:-$BAR_COLOR_FALLBACK}"
	width=$(awesome-client 'return screen[1].geometry.width' 2>/dev/null | sed -n 's/^[[:space:]]*double[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1) || true
	width="${width:-$FADE_WIDTH_FALLBACK}"
	mkdir -p "$(dirname "$TOP_FADE")"
	magick -size "${width}x${FADE_HEIGHT}" gradient:"${bar_color}-none" "$TOP_FADE"
	success "Top fade generated → $TOP_FADE (${width}x${FADE_HEIGHT}, ${bar_color} → transparent)"
}

# -------------------- Pre-flight --------------------
# Purges stale nvim .backup files that would otherwise make home-manager fail
# (it sets backupFileExtension = "backup", which errors if the destination
# already exists). Add new entries here as needed. Must stay idempotent.
pre_flight() {
	local stale
	stale=$(find "$DOT/nvim" -name "*.backup" 2>/dev/null) || true
	if [ -z "$stale" ]; then
		return 0
	fi
	if find "$DOT/nvim" -name "*.backup" -delete 2>/dev/null; then
		success "Cleared stale nvim .backup files"
	else
		error "Failed to clear stale nvim .backup files"
		return 1
	fi
}

# -------------------- Operations --------------------
reload() {
	step "Copying dotfiles…"
	local pair src dest
	for pair in "${DOTFILES[@]}"; do
		IFS='|' read -r src dest <<<"$pair"
		copy "$src" "$dest"
	done

	step "Applying pre-flight fixes…"
	pre_flight

	step "Creating symlinks for scripts…"
	link "$REPO_DIR/reconfigure.sh" "$EXE/reconfigure"
	link "$CORESCR/microcontroller-flash.sh" "$EXE/mcflash"
	link "$CORESCR/mode.sh" "$EXE/mode"
	link "$CORESCR/egpu.sh" "$EXE/egpu"

	# One honest gate: can we actually talk to awesome? (immune to NixOS's
	# wrapped binary breaking pgrep, and to DISPLAY being set while awesome
	# is dead — e.g. ssh -X)
	if command -v awesome-client &>/dev/null && awesome-client 'return 1' >/dev/null 2>&1; then
		generate_fade

		step "Killing programs on hidden workspaces..."
		kill_clients_on_workspace scrap
		kill_clients_on_workspace preload
		success "All programs successfully murdered"

		step "Saving visible tags per screen..."
		save_visible_tags

		step "Reloading AwesomeWM configuration..."
		# awesome.restart() tears down the D-Bus service before the client
		# gets its reply, so awesome-client exits nonzero even on success.
		awesome-client 'awesome.restart()' >/dev/null 2>&1 || true
		success "All done!"
	else
		error "No X session / awesome not running; skipping AwesomeWM steps (dotfiles and scripts still synced)."
	fi
}

# Hostname from user/userprofile.nix (line: hostname = "…";)
get_hostname() {
	local hostname
	hostname=$(sed -n 's/^[[:space:]]*hostname[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$USER_DIR/userprofile.nix")
	if [ -z "$hostname" ]; then
		error "Could not read 'hostname' from $USER_DIR/userprofile.nix"
		exit 1
	fi
	printf "%s" "$hostname"
}

# -------------------- Flake sync --------------------
# Copies the repo's flake + profile into /etc/nixos. Both rebuild and update
# call this first, so `nix flake update` always runs against the repo's
# current flake.nix — never a stale copy left from the previous run.
sync_flake() {
	step "Copying flake files into $TARGET_DIR…"
	for file in flake.nix configuration.nix home.nix flake.lock; do
		sudo cp -f "$REPO_DIR/$file" "$TARGET_DIR/$file"
	done

	step "Copying profile into $TARGET_DIR/user…"
	sudo mkdir -p "$TARGET_DIR/user"
	sudo cp -f "$USER_DIR"/userprofile.nix "$USER_DIR"/userprograms.nix "$TARGET_DIR/user/"

	sudo chown root:root "$TARGET_DIR"/{flake.nix,flake.lock,configuration.nix,home.nix} "$TARGET_DIR"/user/*.nix
	sudo chmod 644 "$TARGET_DIR"/{flake.nix,flake.lock,configuration.nix,home.nix} "$TARGET_DIR"/user/*.nix
	success "Flake files and profile updated in $TARGET_DIR"
}

# -------------------- Post-rebuild maintenance --------------------
# Runs only after a successful `nixos-rebuild switch`, in the same breath
# as the freshly regenerated GRUB menu — so the menu can never reference
# paths that generation pruning / garbage collection just removed.
cleanup() {
	step "Pruning to last 5 generations…"
	sudo nix-env -p /nix/var/nix/profiles/system --delete-generations +5
	nix-env --delete-generations +5 # own profile (home-manager generations)

	step "Collecting garbage (failed builds, unreachable paths)…"
	sudo nix-collect-garbage

	step "Pruning dev-shell roots unused for 200 days…"
	find "$HOME/.cache/gnoms/shells" -maxdepth 1 -type l -mtime +200 -delete 2>/dev/null || true
}

rebuild() {
	sudo -v # ask for the password up front, before any output
	local hostname
	hostname=$(get_hostname)

	sync_flake

	step "Building new system configuration…"
	sudo nixos-rebuild switch --flake "$TARGET_DIR#$hostname" 2>&1 | tee >(grep --color error >&2)
	success "System rebuild complete."

	cleanup
	reload
}

update() {
	sudo -v # ask for the password up front, before any output
	local hostname
	hostname=$(get_hostname)

	sync_flake

	step "Updating flake.lock in $TARGET_DIR…"
	sudo nix flake update --flake "$TARGET_DIR"

	step "Copying updated flake.lock back to $REPO_DIR…"
	sudo cp -f "$TARGET_DIR/flake.lock" "$REPO_DIR/flake.lock"
	sudo chown "$USER:users" "$REPO_DIR/flake.lock"
	success "Flake.lock updated and synced back."

	step "Building updated packages (no activation)…"
	sudo nixos-rebuild build --flake "$TARGET_DIR#$hostname" 2>&1 | tee >(grep --color error >&2)
	success "Build complete. Run 'reconfigure rebuild' to activate."
}

upgrade() {
	update
	rebuild
}

# -------------------- Entry Point --------------------
case "${1-}" in
rebuild) rebuild ;;
reload) reload ;;
update) update ;;
upgrade) upgrade ;;
*)
	echo -e "${RED}Usage: $0 {rebuild|reload|update|upgrade}${RESET}" >&2
	exit 1
	;;
esac
