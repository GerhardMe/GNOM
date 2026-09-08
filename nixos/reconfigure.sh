#!/usr/bin/env bash
set -euo pipefail

# -------------------- Colors --------------------
GREEN="\033[1;32m"
PURPLE="\033[38;2;135;0;255m"
RED="\033[1;31m"
RESET="\033[0m"

# -------------------- Paths --------------------
REPO_DIR="$HOME/GNOMS/nixos"
TARGET_DIR="/etc/nixos"
COREDOT="$HOME/GNOMS/dotfiles"
DOT="$HOME/.config"
CORESCR="$HOME/GNOMS/scripts"
EXE="$HOME/.local/bin"
USER_DIR="$HOME/GNOMS/user"

# -------------------- Helper functions --------------------
step() { echo -e "${PURPLE}[  ▶▶  ]${RESET} $1"; }
success() { echo -e "${GREEN}[  OK  ]${RESET} $1"; }
error() { echo -e "${RED}[  !!  ]${RESET} $1"; }

copy() {
	local src="$1" dest="$2"
	mkdir -p "$(dirname "$dest")"
	if cp -f "$src" "$dest"; then
		success "Copied $src → $dest"
	else
		error "ERROR: failed to copy $src → $dest" >&2
	fi
}

link() {
	local target="$1" dest="$2"
	mkdir -p "$(dirname "$dest")"
	if ln -sf "$target" "$dest"; then
		success "Linked $dest → $target"
	else
		error "ERROR: failed to link $dest → $target" >&2
	fi
}

kill_clients_on_workspace() {
	local tag="$1"
	awesome-client <<EOF
for _, c in ipairs(client.get()) do
  if c.first_tag and c.first_tag.name == "${tag}" then
    c:kill()
  end
end
EOF
}

save_visible_tags() {
	: >/tmp/awesome-visible-tags
	for screen in $(seq 1 5); do
		raw_output=$(awesome-client "return (screen[${screen}] and screen[${screen}].selected_tag and screen[${screen}].selected_tag.name) or ''" 2>/dev/null)
		tag=$(printf "%s" "$raw_output" | sed -n 's/.*"\(.*\)".*/\1/p')
		tag=$(printf "%s" "$tag" | tr -d '"\n ')
		if [ -n "$tag" ]; then
			echo "${screen}:${tag}" >>/tmp/awesome-visible-tags
		fi
	done
}

# -------------------- Hacky Fixes --------------------
# Surgical per-binary patches that can't be solved cleanly in Nix.
# Add new entries here as needed. All fixes must be idempotent.
hacky_fixes() {
	# home-manager fails if a .backup file already exists at the backup destination
	find "$DOT/nvim" -name "*.backup" -delete 2>/dev/null && success "Cleared stale nvim .backup files"
}

# -------------------- Operations --------------------
reload() {
	step "Generating terminal top-edge fade…"
	TOP_FADE="$HOME/.cache/gnoms/top_fade.png"
	# Lua owns the color: read it straight out of the deployed theme
	BAR_COLOR=$(sed -n 's/.*theme.bg_normal[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$DOT/awesome/theme.lua")
	BAR_COLOR="${BAR_COLOR:-#404040}"
	STRIP_H=80
	W=3840
	mkdir -p "$(dirname "$TOP_FADE")"

	magick -size "${W}x${STRIP_H}" gradient:"${BAR_COLOR}-none" "$TOP_FADE"
	success "Top fade generated → $TOP_FADE (${BAR_COLOR} → transparent)"

	step "Copying dotfiles…"
	copy "$COREDOT/dunst.conf" "$DOT/dunst/dunstrc"
	copy "$COREDOT/udiskie.yml" "$DOT/udiskie/config.yml"
	copy "$COREDOT/rofi.rasi" "$DOT/rofi/config.rasi"
	copy "$COREDOT/fish/prompt.fish" "$DOT/fish/functions/fish_prompt.fish"
	copy "$COREDOT/fish/prompt_right.fish" "$DOT/fish/functions/fish_right_prompt.fish"
	copy "$COREDOT/fish/startup.fish" "$DOT/fish/config.fish"
	copy "$COREDOT/fish/theme.fish" "$DOT/fish/conf.d/fish_frozen_theme.fish"
	copy "$COREDOT/awesome/main.lua" "$DOT/awesome/rc.lua"
	copy "$COREDOT/awesome/statusbar.lua" "$DOT/awesome/statusbar.lua"
	copy "$COREDOT/awesome/theme.lua" "$DOT/awesome/theme.lua"
	copy "$COREDOT/wezterm.lua" "$DOT/wezterm/wezterm.lua"
	copy "$COREDOT/cava.conf" "$DOT/cava/config"
	copy "$COREDOT/nvim/init.lua" "$DOT/nvim/init.lua"
	copy "$COREDOT/nvim/lua/keymaps.lua" "$DOT/nvim/lua/keymaps.lua"
	copy "$COREDOT/nvim/lua/options.lua" "$DOT/nvim/lua/options.lua"
	copy "$COREDOT/nvim/lua/plugins.lua" "$DOT/nvim/lua/plugins.lua"
	copy "$COREDOT/nvim/lua/theme.lua" "$DOT/nvim/lua/theme.lua"
	copy "$COREDOT/nvim/lua/autocmd.lua" "$DOT/nvim/lua/autocmd.lua"
	copy "$COREDOT/qbittorrent.conf" "$DOT/qBittorrent/qBittorrent.conf"
	copy "$COREDOT/fastfetch.jsonc" "$DOT/fastfetch/config.jsonc"

	step "Applying hacky fixes…"
	hacky_fixes

	step "Creating symlinks for scripts…"
	link "$REPO_DIR/reconfigure.sh" "$EXE/reconfigure"
	link "$CORESCR/microcontroller-flash.sh" "$EXE/mcflash"
	link "$CORESCR/mode.sh" "$EXE/mode"
	link "$CORESCR/egpu.sh" "$EXE/egpu"
	chmod +x "$EXE/"*

	if [ -n "${DISPLAY-}" ] && command -v awesome-client &>/dev/null; then
		step "Killing programs on hidden workspaces..."
		kill_clients_on_workspace scrap
		kill_clients_on_workspace preload
		success "All programs successfully murdered"

		step "Saving visible tags per screen..."
		save_visible_tags

		step "Reloading AwesomeWM configuration..."
		success "\033[1;32mAll done!"
		awesome-client 'awesome.restart()' >/dev/null 2>&1
	else
		error "Not in an X session or awesome-client not found; skipping AwesomeWM reload."
	fi
}

# Hostname from user/userprofile.nix (line: hostname = "…";)
get_hostname() {
	sed -n 's/^[[:space:]]*hostname[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$USER_DIR/userprofile.nix"
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

	step "Building new system configuration…"
	sudo nixos-rebuild switch --flake "$TARGET_DIR#$(get_hostname)" 2>&1 | tee >(grep --color error >&2) || false
	success "System rebuild complete."

	cleanup
	reload
}

update() {
	sudo -v # ask for the password up front, before any output

	step "Updating flake.lock in $TARGET_DIR…"
	sudo nix flake update --flake "$TARGET_DIR"

	step "Copying updated flake.lock back to $REPO_DIR…"
	sudo cp -f "$TARGET_DIR/flake.lock" "$REPO_DIR/flake.lock"
	sudo chown "$USER:users" "$REPO_DIR/flake.lock"
	success "Flake.lock updated and synced back."

	step "Building updated packages (no activation)…"
	sudo nixos-rebuild build --flake "$TARGET_DIR#$(get_hostname)" 2>&1 | tee >(grep --color error >&2) || false
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
