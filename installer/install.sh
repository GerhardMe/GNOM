#!/usr/bin/env bash
# install.sh — the real GNOMS installer.
# Never run from the USB copy: bootstrap.sh clones GNOMS to /tmp/gnoms and
# runs THIS script from that fresh clone, so installer logic always matches
# the config it installs. Pulls GNOMS from master.
#
# Flow: preflight → manual partitioning (guided prompts) → optional LUKS →
# mount → 32 GB swapfile + resume_offset → clone GNOMS to target →
# generate hardware-configuration.nix → template flake into /mnt/etc/nixos →
# nixos-install.
set -euo pipefail

# -------------------- Paths / constants --------------------
SOURCE_REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_URL="https://github.com/GerhardMe/GNOMS.git"
BRANCH="master"
MNT="/mnt"
ETC_NIXOS="$MNT/etc/nixos"
PROFILE="$SOURCE_REPO/personal/profile.conf"
MAPPER="cryptroot"
SWAP_SIZE_MIB=$((32 * 1024)) # 32 GiB — MUST match swapDevices size in nixos/configuration.nix

# -------------------- Colors --------------------
GREEN="\033[1;32m"
PURPLE="\033[38;2;135;0;255m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
RESET="\033[0m"

step() { echo -e "${PURPLE}[  ▶▶  ]${RESET} $1"; }
success() { echo -e "${GREEN}[  OK  ]${RESET} $1"; }
warn() { echo -e "${YELLOW}[  ⚠   ]${RESET} $1"; }
error() { echo -e "${RED}[  !!  ]${RESET} $1" >&2; }
die() { error "$1"; exit 1; }

trap 'error "Installation failed. /mnt is left mounted so you can inspect the damage."; exit 1' ERR

# -------------------- Profile parser (same logic as reconfigure.sh) --------------------
declare -A CONFIG

parse_config() {
	local in_block=""
	local block_content=""

	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "${line// /}" ]] && continue

		if [[ -n "$in_block" ]] && [[ "$line" =~ ^[[:space:]]*\}[[:space:]]*$ ]]; then
			CONFIG["$in_block"]="$block_content"
			in_block=""
			continue
		fi

		if [[ -n "$in_block" ]]; then
			local trimmed="${line#"${line%%[![:space:]]*}"}"
			block_content+="${trimmed}"$'\n'
			continue
		fi

		if [[ "$line" =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*\{[[:space:]]*$ ]]; then
			in_block="${BASH_REMATCH[1]}"
			block_content=""
			continue
		fi

		if [[ "$line" =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
			local value="${BASH_REMATCH[2]}"
			[[ "$value" == "{" ]] && continue
			CONFIG["${BASH_REMATCH[1]}"]="$value"
		fi
	done <"$PROFILE"
}

# set_key <key> <value> — update or append a key in profile.conf
set_key() {
	local key="$1" value="$2"
	if grep -qE "^${key}[[:space:]]*=" "$PROFILE"; then
		sed -i "s|^${key}[[:space:]]*=.*|${key} = ${value}|" "$PROFILE"
	else
		printf '\n%s = %s\n' "$key" "$value" >>"$PROFILE"
	fi
}

# apply_template <input> <output> — replace all {{key}} patterns (same logic as reconfigure.sh)
apply_template() {
	local input="$1"
	local output="$2"

	cp "$input" "$output"

	for key in "${!CONFIG[@]}"; do
		local value="${CONFIG[$key]}"
		value="${value//\\/\\\\}"
		value="${value//&/\\&}"
		value="${value//$'\n'/\\n}"
		sed -i "s|{{${key}}}|${value}|g" "$output"
	done
}

# -------------------- Prompts --------------------
ask() { # ask <prompt> <default> — echoes answer
	local prompt="$1" default="${2-}" answer
	read -rp "$(echo -e "${PURPLE}?${RESET} ${prompt} [$default]: ")" answer
	echo "${answer:-$default}"
}

ask_yn() { # ask_yn <prompt> <default y|N>
	local prompt="$1" default="${2:-N}" answer
	read -rp "$(echo -e "${PURPLE}?${RESET} ${prompt} $( [ "$default" = y ] && echo '[Y/n]' || echo '[y/N]' )"): " answer
	answer="${answer:-$default}"
	[[ "$answer" =~ ^[Yy] ]]
}

validate_blockdev() {
	[[ -b "$1" ]] || die "'$1' is not a block device. (Check with lsblk)"
}

banner() {
	echo -e "${PURPLE}"
	cat <<'EOF'
   ██████╗ ███╗   ██╗ ██████╗ ███╗   ███╗ ███████╗
  ██╔════╝ ████╗  ██║██╔═══██╗████╗ ████║ ██╔════╝
  ██║  ███╗██╔██╗ ██║██║   ██║██╔████╔██║ ███████╗
  ██║   ██║██║╚██╗██║██║   ██║██║╚██╔╝██║ ╚════██║
  ╚██████╔╝██║ ╚████║╚██████╔╝██║ ╚═╝ ██║ ███████║
   ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝ ╚═╝     ╚═╝ ╚══════╝
                     — installer —
EOF
	echo -e "${RESET}"
}

# ============================== 1. Preflight ==============================
preflight() {
	banner

	[ "$(id -u)" -eq 0 ] || die "Must run as root."
	command -v nixos-install &>/dev/null || die "This does not look like a NixOS installer environment."
	ping -c1 -W3 github.com &>/dev/null || die "No network. Run 'nmtui' to connect to Wi-Fi, then retry."

	parse_config

	step "Defaults from profile.conf:"
	echo -e "    hostname : ${CONFIG[hostname]}"
	echo -e "    username : ${CONFIG[username]}"
	echo -e "    timezone : ${CONFIG[timezone]}"
	echo -e "    locale   : ${CONFIG[locale]}"

	step "Current disks:"
	lsblk -e 7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS

	warn "This will DESTROY all data on the partition you choose as root."
	warn "Dual-boot: partition manually in another TTY (alt+F2) BEFORE continuing —"
	warn "the installer never touches the EFI partition, so Windows/other entries survive."
	ask_yn "Ready to continue?" || die "Aborted."
}

# ============================== 2. Partitioning guidance ==============================
partition_guidance() {
	step "Manual partitioning cheat-sheet (run in another TTY if you like):"
	cat <<'EOF'

    gdisk /dev/nvme0n1          # or fdisk / parted / cfdisk

    Fresh disk:
      1) EFI partition : 512M, type ef00  → mkfs.fat -F32 /dev/nvme0n1p1
      2) Root partition: rest, type 8304 (or 8309 for LUKS)

    Dual-boot (Windows already installed):
      1) Shrink the Windows partition (from Windows Disk Management, or ntfsresize)
      2) Create root partition: rest, type 8304
      3) Reuse the existing EFI partition — do NOT format it

    The root partition may be small (60G+ recommended); 32G of it is swap.
EOF
	ask_yn "Partitioning is done?" || die "Aborted. Partition now, then run again."
}

# ============================== 3. Questions ==============================
questions() {
	step "Questions — Enter accepts the default."

	ROOT_PART=$(ask "Root partition (e.g. /dev/nvme0n1p5)" "")
	validate_blockdev "$ROOT_PART"

	ESP_PART=$(ask "EFI System Partition (e.g. /dev/nvme0n1p1)" "")
	validate_blockdev "$ESP_PART"
	[[ "$ESP_PART" != "$ROOT_PART" ]] || die "ESP and root must be different partitions."
	[[ -n "$(lsblk -no FSTYPE "$ESP_PART")" ]] ||
		warn "ESP has no filesystem — format it with 'mkfs.fat -F32 $ESP_PART' first."

	if ask_yn "Wipe and reformat the root partition? (N only if re-running on an already prepared root)"; then
		FORMAT_ROOT=y
	else
		FORMAT_ROOT=n
	fi

	if ask_yn "Encrypt the root partition with LUKS?"; then
		ENCRYPT=y
	else
		ENCRYPT=n
	fi

	if [ "$FORMAT_ROOT" = y ] && [ "$ENCRYPT" = n ]; then
		warn "ROOT DATA ON $ROOT_PART WILL BE ERASED."
		ask_yn "Last chance — really format $ROOT_PART?" || die "Aborted."
	fi

	USERNAME=$(ask "Username" "${CONFIG[username]}")
	HOSTNAME=$(ask "Hostname" "${CONFIG[hostname]}")
	TIMEZONE=$(ask "Timezone" "${CONFIG[timezone]}")
	LOCALE=$(ask "Locale" "${CONFIG[locale]}")

	[ "$FORMAT_ROOT" = y ] && [ "$ENCRYPT" = y ] && {
		warn "$ROOT_PART WILL BE LUKS-FORMATTED — ALL DATA ERASED."
		ask_yn "Final check — really encrypt and format $ROOT_PART?" || die "Aborted."
	}
}

# ============================== 4. Mount ==============================
do_mount() {
	step "Unlocking / formatting root…"

	if [ "$ENCRYPT" = y ]; then
		if [ -e "/dev/mapper/$MAPPER" ]; then
			step "/dev/mapper/$MAPPER already open — reusing (re-run detected)."
		else
			if [ "$FORMAT_ROOT" = y ]; then
				cryptsetup luksFormat --type luks2 "$ROOT_PART"
			fi
			cryptsetup open "$ROOT_PART" "$MAPPER"
		fi
		ROOT_DEV="/dev/mapper/$MAPPER"
	else
		ROOT_DEV="$ROOT_PART"
		[ "$FORMAT_ROOT" = y ] && mkfs.ext4 -F "$ROOT_DEV"
	fi

	mkdir -p "$MNT"
	mount "$ROOT_DEV" "$MNT"
	step "Mounting ESP at $MNT/boot (never formatted)…"
	mkdir -p "$MNT/boot"
	mount "$ESP_PART" "$MNT/boot"
	success "Root and ESP mounted."
}

# ============================== 5. Swap ==============================
do_swap() {
	step "Creating ${SWAP_SIZE_MIB}M swapfile (matches configuration.nix) — this takes a minute…"
	mkdir -p "$MNT/var/lib"
	rm -f "$MNT/var/lib/swapfile"
	dd if=/dev/zero of="$MNT/var/lib/swapfile" bs=1M count="$SWAP_SIZE_MIB" status=progress
	chmod 600 "$MNT/var/lib/swapfile"
	mkswap "$MNT/var/lib/swapfile"

	RESUME_OFFSET=$(filefrag -v "$MNT/var/lib/swapfile" | awk 'NR==4 {print $4+0}')
	[ -n "$RESUME_OFFSET" ] && [ "$RESUME_OFFSET" != 0 ] ||
		die "Could not determine resume_offset (got '$RESUME_OFFSET')."
	success "Swapfile created. resume_offset = $RESUME_OFFSET"
}

# ============================== 6. Repo + hardware config ==============================
do_repo() {
	step "Cloning GNOMS (${BRANCH}) into target…"
	TARGET_REPO="$MNT/home/$USERNAME/GNOMS"
	rm -rf "$TARGET_REPO"
	git clone --branch "$BRANCH" "$REPO_URL" "$TARGET_REPO" ||
		die "Failed to clone $REPO_URL into target."
	success "GNOMS cloned → $TARGET_REPO"

	step "Generating hardware-configuration.nix from the target…"
	nixos-generate-config --root "$MNT"
	[ -f "$MNT/etc/nixos/hardware-configuration.nix" ] ||
		die "nixos-generate-config did not produce hardware-configuration.nix."

	step "Installing generated hardware config into the repo clone…"
	cp "$MNT/etc/nixos/hardware-configuration.nix" "$TARGET_REPO/nixos/hardware-configuration.nix"

	# Keep only what the repo needs; remove the rest of the generated boilerplate.
	# (hardware-configuration.nix stays in $ETC_NIXOS — configuration.nix imports it.)
	rm -f "$MNT/etc/nixos/configuration.nix" "$MNT/etc/nixos/flake.nix"

	step "Writing install answers into the clone's profile.conf…"
	PROFILE="$TARGET_REPO/personal/profile.conf"
	set_key hostname "$HOSTNAME"
	set_key username "$USERNAME"
	set_key timezone "$TIMEZONE"
	set_key locale "$LOCALE"
	set_key resume_offset "$RESUME_OFFSET"
	parse_config
	success "profile.conf updated."
}

# ============================== 7. Template into /mnt/etc/nixos ==============================
do_template() {
	step "Templating flake files into $ETC_NIXOS…"
	mkdir -p "$ETC_NIXOS"
	for file in flake.nix configuration.nix home.nix; do
		apply_template "$SOURCE_REPO/nixos/$file" "$ETC_NIXOS/$file"
	done
	cp -f "$SOURCE_REPO/nixos/flake.lock" "$ETC_NIXOS/flake.lock"
	success "Flake files templated and in place."
}

# ============================== 8. Install ==============================
do_install() {
	step "Running nixos-install (grab a coffee)…"
	nixos-install --flake "$ETC_NIXOS#$HOSTNAME"

	step "Setting user password…"
	nixos-enter --root "$MNT" -c "passwd $USERNAME"

	step "Fixing ownership of the repo clone…"
	nixos-enter --root "$MNT" -c "chown -R $USERNAME:users /home/$USERNAME/GNOMS"

	success "GNOMS installed!"
	cat <<EOF

  ${GREEN}All done.${RESET}

    - Remove the USB stick and reboot:   reboot
    - Log in as $USERNAME (password set above).
    - The flake lives in /etc/nixos, the repo in ~/GNOMS.
    - Manage the system with:            reconfigure rebuild
    - Windows/other OSes appear in the GRUB menu (os-prober).
    - Hibernation uses the swapfile with resume_offset=$RESUME_OFFSET (already configured).

  ${YELLOW}NOTE:${RESET} the root password is whatever you set during nixos-install.
EOF

	if ask_yn "Reboot now?"; then
		umount -R "$MNT" || true
		cryptsetup close "$MAPPER" 2>/dev/null || true
		reboot
	fi
}

# ============================== Main ==============================
preflight
partition_guidance
questions
do_mount
do_swap
do_repo
do_template
do_install
