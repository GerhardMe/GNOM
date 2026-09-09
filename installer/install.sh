#!/usr/bin/env bash
# install.sh — the GNOMS installer. Lives in the repo (fetched at install
# time by bootstrap.sh), so it can grow without the ISO going stale.
#
# Usage: install.sh <repo-root>    (bootstrap.sh passes its clone, /tmp/gnoms;
#                                   on a machine that already has GNOMS: ~/GNOMS)
#
# Implements: Phase 1 — partitioning + LUKS2 + swapfile.
#             Phase 3 — baseline NixOS install + repo copy onto the target.
#             Phase 4 — profile questions → user/userprofile.nix on the target.
#             Phase 5 — programs: all or none → user/userprograms.nix on the target.
#             Phase 6 — flake sync + full GNOMS build (second nixos-install
#                       pass, no reboot in between) + handoff + reboot.
#
# For inspection: set GNOMS_STOP_AFTER_PARTITION=1 to stop once the disk is
# prepared and mounted, so the result can be inspected before continuing.

set -euo pipefail

[ -n "${1:-}" ] && [ -d "$1/installer" ] ||
	{ echo "usage: $0 <repo-root>   (the GNOMS checkout to install from)" >&2; exit 1; }
REPO="$1"
FACTS="/tmp/gnoms-facts"
KEYMAP_FILE="/tmp/gnoms-keymap"
MNT="/mnt"
TARGET_NIXOS="$MNT/etc/nixos"

# Shared look (colors, prompts, banner, section) + the logo from the repo.
GNOMS_LOGO="$REPO/user/logo.txt"
source "$REPO/installer/ui.sh"

ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
ESP_DEFAULT_MB=1024
MIN_ROOT_MB=20480   # warn if root gets under 20 GiB
SWAP_MIN_MB=1024

# -------------------- Facts (machine-generated, for later phases) ----------
# KEY=VALUE lines. Phase 4 turns these into userprofile/configuration bits.
# resume_offset and dualboot must never be hand-written into userprofile.
fact_set() {	# fact_set KEY VALUE
	grep -v "^$1=" "$FACTS" 2>/dev/null > "$FACTS.tmp" || true
	mv "$FACTS.tmp" "$FACTS"
	printf '%s=%s\n' "$1" "$2" >> "$FACTS"
}
fact_get() {	# fact_get KEY  -> prints value or empty
	grep "^$1=" "$FACTS" 2>/dev/null | tail -1 | cut -d= -f2-
}

# -------------------- Environment checks --------------------
assert_root()   { [ "$(id -u)" -eq 0 ] || die "Must run as root."; }
assert_uefi() {
	[ -d /sys/firmware/efi ] ||
		die "Not booted in UEFI mode. GNOMS requires UEFI (GRUB is efi-only here)."
}

# The disk the installer itself boots from must never be a wipe target.
install_medium_disk() {
	local src disk=""
	src=$(findmnt -n -o SOURCE /iso 2>/dev/null || true)
	if [ -n "$src" ]; then
		disk=$(lsblk -no PKNAME "$src" 2>/dev/null || true)
	fi
	echo "/dev/${disk:-none}"
}

# -------------------- Disk helpers --------------------
# One line per disk:  /dev/X|SIZE_MB|MODEL|NOTES   (lsblk -P parsed via -F'"')
list_disks() {
	local med; med=$(install_medium_disk)
	lsblk -dnb -o NAME,SIZE,TYPE,RM,MODEL |
	awk -F'"' -v med="$med" '$6=="disk" {
		dev="/dev/"$2; notes="";
		if ($8=="1") notes="removable ";
		if (dev==med) notes=notes "[INSTALL MEDIUM]";
		printf "%s|%d|%s|%s\n", dev, int($4/1048576), $10, notes
	}'
}

disk_free_bytes() {	# largest free gap on a disk, in bytes (0 if none)
	parted -ms "$1" unit B print free 2>/dev/null |
	awk -F'[;:]' '$5=="free" { if ($4 > best) best = $4 } END { print best+0 }'
}

partitions_of() {	# NAME|SIZE|FSTYPE lines for a disk
	lsblk -nr -o NAME,TYPE,SIZE,FSTYPE "$1" |
	awk '$2=="part" { printf "/dev/%s|%s|%s\n", $1, $3, ($4==""?"-":$4) }'
}

# ESP partitions of a disk (GPT type c12a7328-…)
esp_on_disk() {
	local p
	for p in $(lsblk -nr -o NAME,TYPE "$1" | awk '$2=="part"{print "/dev/"$1}'); do
		[ "$(lsblk -no PARTTYPE "$p" 2>/dev/null | tr 'A-Z' 'a-z')" = "$ESP_GUID" ] && echo "$p"
	done
	return 0
}

# Create a partition in the largest free gap. 4th arg: size in MB
# (empty = rest of the gap). Prints the created device path.
create_part_in_free_space() {
	local disk="$1" code="$2" label="$3" size_mb="${4:-}" num opt
	num=$(parted -ms "$disk" unit B print free |
		awk -F'[;:]' '$1 ~ /^[0-9]+$/ { if ($1 > n) n = $1 } END { print n+1 }')
	[ -n "$num" ] || num=1
	if [ -n "$size_mb" ]; then opt="+${size_mb}M"; else opt="0"; fi
	sgdisk -n${num}:0:${opt} -t${num}:${code} -c${num}:${label} "$disk"
	partprobe "$disk"
	udevadm settle
	lsblk -nr -o NAME,TYPE "$disk" | awk -v n="$num" '$2=="part" && $1 ~ n"$" { print "/dev/"$1; exit }'
}

# -------------------- Host OS detection --------------------
# Mount every vfat partition read-only and look at /EFI/* to see what else
# lives on this machine. Result drives mode defaults and the dualboot fact.
detect_host_oses() {
	local found="" p mp d os
	for p in $(lsblk -nr -o NAME,TYPE,FSTYPE | awk '$2=="part" && $3=="vfat"{print "/dev/"$1}'); do
		mp=$(mktemp -d /tmp/gnoms-esp.XXXXXX)
		if mount -o ro "$p" "$mp" 2>/dev/null; then
			for d in "$mp"/EFI/*; do
				[ -d "$d" ] || continue
				os=$(basename "$d")
				case "$os" in
					Microsoft) os="Windows" ;;
					Boot) continue ;;
				esac
				found="$found $os"
			done
			umount "$mp"
		fi
		rmdir "$mp" 2>/dev/null || true
	done
	echo "$found" | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' '
}

# -------------------- Shared prep pieces --------------------

mapper_of() {	# luks mapper name convention must match nixos-generate-config
	echo "/dev/mapper/luks-$(blkid -s UUID -o value "$1")"
}

format_luks_root() {	# format_luks_root PART — prompts for passphrase
	local part="$1" pass pass2 uuid
	while true; do
		pass=$(ask_secret "LUKS passphrase for root (unlocks the disk on every boot):")
		pass2=$(ask_secret "Repeat:")
		[ -n "$pass" ] && [ "$pass" = "$pass2" ] && break
		warn "Passphrases empty or don't match — try again."
	done
	step "Formatting $part as LUKS2 (argon2id)…"
	printf '%s' "$pass" | cryptsetup luksFormat --type luks2 --pbkdf argon2id --batch-mode "$part" -
	uuid=$(blkid -s UUID -o value "$part")
	printf '%s' "$pass" | cryptsetup open "$part" "luks-$uuid" --key-file=-
	step "Creating ext4 root filesystem…"
	mkfs.ext4 -F -L nixos "/dev/mapper/luks-$uuid"
	fact_set luks_uuid "$uuid"
}

mount_system() {	# mount_system MAPPER ESP_PART — root first, then ESP
	local mapper="$1" esp="$2"
	step "Mounting root at $MNT, ESP at $MNT/boot…"
	mount "$mapper" "$MNT"
	mkdir -p "$MNT/boot"
	mount "$esp" "$MNT/boot"
	fact_set root_fs_uuid "$(blkid -s UUID -o value "$mapper")"
}

# Swap size configuration.nix declares (swapDevices … size = <expr>;), in MB.
# NixOS recreates the swapfile at that size on the first rebuild if it
# differs, which would move the resume_offset — so the installer defaults to
# it. Empty if the repo has no size key.
config_swap_mb() {
	local expr
	expr=$(sed -n 's/^[[:space:]]*size[[:space:]]*=[[:space:]]*\([^;]*\);.*/\1/p' \
		"$REPO/nixos/configuration.nix" 2>/dev/null | head -1)
	[[ "$expr" =~ ^[0-9\ \*\+\-\(\)]+$ ]] || return 0
	echo $(( expr ))
}

make_swap() {	# make_swap MNT — swapfile lives on the encrypted root
	local mnt="$1" ram_mb cfg_mb default_mb size_mb offset
	ram_mb=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
	cfg_mb=$(config_swap_mb)
	default_mb="${cfg_mb:-$ram_mb}"
	if [ -n "$cfg_mb" ]; then
		echo "  configuration.nix declares a ${cfg_mb} MB swapfile; NixOS recreates it at that"
		echo "  size on the first rebuild, so a different choice here is overwritten."
	fi
	[ "$default_mb" -lt "$ram_mb" ] && warn "That is less than this machine's RAM (${ram_mb} MB) — hibernation may not fit."
	while true; do
		size_mb=$(ask_def "  Swapfile size in MB" "$default_mb")
		[[ "$size_mb" =~ ^[0-9]+$ ]] && [ "$size_mb" -ge "$SWAP_MIN_MB" ] && break
		warn "Enter a number ≥ ${SWAP_MIN_MB}."
	done
	step "Creating /var/lib/swapfile (${size_mb} MB) on the new root…"
	mkdir -p "$mnt/var/lib"
	dd if=/dev/zero of="$mnt/var/lib/swapfile" bs=1M count="$size_mb" status=none
	chmod 600 "$mnt/var/lib/swapfile"
	mkswap -L swap "$mnt/var/lib/swapfile"
	offset=$(filefrag -v "$mnt/var/lib/swapfile" | awk 'NR==4 { print $4+0 }')
	fact_set swapfile_size_mb "$size_mb"
	fact_set resume_offset "$offset"
	success "Swapfile ready; resume_offset=$offset (configuration.nix hardcodes this value — update it by hand)"
}

# -------------------- Partitioning modes --------------------

prep_whole_disk() {	# GNOMS erases a whole drive and owns it
	local disk confirm esp_mb
	while true; do
		echo "  Available disks:"
		list_disks | awk -F'|' '{ printf "    %-14s %7d MB  %s %s\n", $1, $2, $4, $3 }'
		disk=$(ask_def "  Disk to erase entirely" "")
		[ -b "$disk" ] || { warn "No such block device: $disk"; continue; }
		break
	done
	[ "$disk" = "$(install_medium_disk)" ] &&
		die "$disk is the install medium itself. Pick another disk."

	echo "  Current contents of $disk:"
	partitions_of "$disk" | awk -F'|' '{ printf "    %-14s %8s  %s\n", $1, $2, $3 }'
	confirm=$(ask "  ERASE EVERYTHING on $disk — type the full device name to confirm")
	[ "$confirm" = "$disk" ] || die "Aborted."

	esp_mb=$(ask_def "  EFI System Partition size (MB)" "$ESP_DEFAULT_MB")
	step "Wiping partition table and creating ESP + encrypted root on $disk…"
	sgdisk --zap-all "$disk"
	partprobe "$disk"
	sgdisk -n1:0:+${esp_mb}M -t1:ef00 -c1:GNOMS-ESP "$disk"
	sgdisk -n2:0:0 -t2:8309 -c2:GNOMS-ROOT "$disk"
	partprobe "$disk"
	udevadm settle
	local part_esp part_root
	part_esp=$(esp_on_disk "$disk" | head -1)
	part_root=$(partitions_of "$disk" | tail -1 | cut -d'|' -f1)
	mkfs.vfat -F32 -n GNOMS-BOOT "$part_esp"
	fact_set mode whole-disk
	fact_set dualboot false
	fact_set esp_part "$part_esp"
	fact_set esp_is_new true
	format_luks_root "$part_root"
	mount_system "$(mapper_of "$part_root")" "$part_esp"
}

prep_free_space() {	# dual boot into unpartitioned space; host OS untouched
	local disk free_mb part_root esp
	while true; do
		echo "  Disks:"
		list_disks | awk -F'|' '{ printf "    %-14s %7d MB  %s %s\n", $1, $2, $4, $3 }'
		disk=$(ask_def "  Disk to install into (only free space is used)" "")
		[ -b "$disk" ] || { warn "No such block device: $disk"; continue; }
		break
	done
	[ "$disk" = "$(install_medium_disk)" ] &&
		die "$disk is the install medium itself."

	free_mb=$(( $(disk_free_bytes "$disk") / 1048576 ))
	[ "$free_mb" -ge "$MIN_ROOT_MB" ] ||
		die "Only ${free_mb} MB unpartitioned on $disk (need ≥ ${MIN_ROOT_MB} MB). Shrink the host OS first, then re-run."
	[ "$free_mb" -lt $((MIN_ROOT_MB * 2)) ] &&
		warn "Only ${free_mb} MB free — tight for NixOS + programs."

	fact_set mode dualboot
	fact_set dualboot true
	if [ -z "$(esp_on_disk "$disk")" ]; then
		warn "No EFI System Partition on $disk — creating one from its free space."
		esp=$(create_part_in_free_space "$disk" ef00 GNOMS-ESP "$ESP_DEFAULT_MB")
		mkfs.vfat -F32 -n GNOMS-BOOT "$esp"
		fact_set esp_is_new true
	else
		esp=$(esp_on_disk "$disk" | head -1)
		fact_set esp_is_new false
	fi
	fact_set esp_part "$esp"
	part_root=$(create_part_in_free_space "$disk" 8309 GNOMS-ROOT)
	format_luks_root "$part_root"
	mount_system "$(mapper_of "$part_root")" "$esp"
}

prep_existing_partition() {	# advanced: reformat a chosen partition as root
	local disk part n i parts confirm esp
	while true; do
		echo "  Disks:"
		list_disks | awk -F'|' '{ printf "    %-14s %7d MB  %s %s\n", $1, $2, $4, $3 }'
		disk=$(ask_def "  Disk holding the partition to use" "")
		[ -b "$disk" ] || { warn "No such block device: $disk"; continue; }
		break
	done
	esp=$(esp_on_disk "$disk" | head -1)
	[ -n "$esp" ] || die "No ESP on $disk. Dual-boot needs one (GNOMS's GRUB joins it)."

	echo "  Partitions on $disk:"
	i=0; parts=()
	while IFS='|' read -r p sz fs; do parts+=("$p"); i=$((i+1)); echo "    $i) $p  $sz  $fs"; done < <(partitions_of "$disk")
	n=$(ask_def "  Partition to reformat as encrypted GNOMS root (number)" "")
	[[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#parts[@]}" ] || die "Bad choice."
	part="${parts[$((n-1))]}"

	confirm=$(ask "  ERASE $part (LUKS2/ext4 over it) — type its full path to confirm")
	[ "$confirm" = "$part" ] || die "Aborted."

	fact_set mode partition
	fact_set dualboot true
	fact_set esp_part "$esp"
	fact_set esp_is_new false
	format_luks_root "$part"
	mount_system "$(mapper_of "$part")" "$esp"
}

# -------------------- Phase 3: baseline install --------------------

# Read a string key out of a userprofile.nix (line: key = "value";). Used
# for defaults only — Phase 4 does the real profile generation.
profile_get() {	# profile_get KEY -> value or empty
	sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
		"$REPO/user/userprofile.nix" 2>/dev/null | head -1
}

# Ask the few facts a bootable bare NixOS needs: user, host, password.
# Defaults come from the repo's userprofile so the repo owner just hits
# Enter; Phase 4 reuses the answers as defaults for the full profile.
ask_baseline_facts() {
	local user host pass pass2
	section "Baseline system"
	while true; do
		user=$(ask_def "  Username" "$(profile_get username)")
		[[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
		warn "Lowercase letters, digits, '-' and '_' only; must start with a letter."
	done
	while true; do
		host=$(ask_def "  Hostname" "$(profile_get hostname)")
		[[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,62})$ ]] && break
		warn "Letters, digits and '-' only."
	done
	while true; do
		pass=$(ask_secret "Password for $user (sudo via wheel; root stays locked):")
		pass2=$(ask_secret "Repeat:")
		[ -n "$pass" ] && [ "$pass" = "$pass2" ] && break
		warn "Passwords empty or don't match — try again."
	done
	fact_set username "$user"
	fact_set hostname "$host"
	# Hash never enters the facts file; it goes straight into the config.
	PASSWORD_HASH=$(hash_password "$pass")
}

hash_password() {	# hash_password PLAINTEXT -> sha-512 crypt hash (via stdin, never argv)
	if command -v mkpasswd &>/dev/null; then
		printf '%s' "$1" | mkpasswd -m sha-512 -s
	elif command -v openssl &>/dev/null; then
		printf '%s' "$1" | openssl passwd -6 -stdin
	else
		die "Neither mkpasswd nor openssl available to hash the password."
	fi
}

# system.stateVersion must match what the repo's configuration.nix carries,
# otherwise the first GNOMS rebuild flips it. Fall back to the live release.
state_version() {
	local sv
	sv=$(sed -n 's/.*system\.stateVersion[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
		"$REPO/nixos/configuration.nix" 2>/dev/null | head -1)
	[ -n "$sv" ] || sv=$(nixos-version 2>/dev/null | cut -d. -f1,2)
	echo "$sv"
}

# nixos-generate-config writes the per-machine hardware-configuration.nix
# (filesystems by UUID, the luks-<uuid> initrd device, drivers). That file
# stays in /etc/nixos forever and is never copied into the repo.
generate_hardware_config() {
	local hw="$TARGET_NIXOS/hardware-configuration.nix"
	step "Generating hardware-configuration.nix for the target…"
	nixos-generate-config --root "$MNT"
	[ -f "$hw" ] || die "nixos-generate-config produced no $hw"
	success "hardware-configuration.nix written"
}

# Baseline configuration.nix: bare NixOS that boots, gets on the network
# and has the user + git. GNOMS's own configuration.nix replaces this file
# on the first `reconfigure rebuild`; only hardware-configuration.nix stays.
# The boot block mirrors nixos/configuration.nix (Phase 2): dual boot →
# --no-nvram install so the host OS's boot order is never touched.
write_baseline_config() {
	local cfg="$TARGET_NIXOS/configuration.nix" dualboot user host keymap sv touch_efi keymap_line=""
	dualboot=$(fact_get dualboot)
	user=$(fact_get username)
	host=$(fact_get hostname)
	keymap=$(fact_get keyboard_layout)
	sv=$(state_version)
	if [ "$dualboot" = true ]; then touch_efi=false; else touch_efi=true; fi
	[ -n "$keymap" ] && keymap_line="  console.keyMap = \"${keymap}\";"
	step "Writing baseline configuration.nix (dualboot=${dualboot})…"
	cat > "$cfg" <<EOF
# Baseline NixOS written by the GNOMS installer (installer/install.sh).
# Just enough to boot, reach the network and log in. It is replaced by
# GNOMS's own configuration.nix on the first \`reconfigure rebuild\`;
# hardware-configuration.nix next to it is per-machine and stays.
{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # dualboot=${dualboot}: canTouchEfiVariables=false makes grub-install run
  # with --no-nvram; the installer registers the "GNOMS" firmware entry
  # itself (--create-only, never reorders the boot menu).
  boot.loader.systemd-boot.enable = false;
  boot.loader.efi.canTouchEfiVariables = ${touch_efi};
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    device = "nodev";
    useOSProber = ${dualboot};
  };

  # Swapfile created by the installer on the encrypted root (no size key,
  # so NixOS never recreates it).
  swapDevices = [{ device = "/var/lib/swapfile"; }];

  networking.hostName = "${host}";
  networking.networkmanager.enable = true;
${keymap_line}
  users.users.${user} = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    hashedPassword = "${PASSWORD_HASH}";
  };

  environment.systemPackages = with pkgs; [ git neovim ];

  system.stateVersion = "${sv}";
}
EOF
	chmod 600 "$cfg"	# holds the password hash
	success "Baseline configuration.nix written"
}

install_baseline() {
	step "Installing baseline NixOS onto $MNT (this downloads packages — grab a coffee)…"
	nixos-install --root "$MNT" --no-root-passwd
	success "Baseline NixOS installed"
}

# Dual boot: grub-install ran with --no-nvram, so NixOS's GRUB sits at
# /EFI/<distro>-boot on the ESP with no firmware entry pointing at it.
# Same recipe as boot.loader.grub.extraInstallCommands in
# nixos/configuration.nix (Phase 2), run once here so the bare system is
# bootable even before the first GNOMS rebuild: copy the binary to a
# stable path and add a "GNOMS" entry without reordering the boot menu.
register_gnoms_boot_entry() {
	[ "$(fact_get dualboot)" = true ] || return 0
	local esp src disk partnum
	esp=$(fact_get esp_part)
	src=$(ls "$MNT"/boot/EFI/*-boot/grubx64.efi 2>/dev/null | head -1)
	[ -n "$src" ] || die "No GRUB binary under $MNT/boot/EFI/*-boot/ — did nixos-install run grub-install?"
	step "Registering contained GNOMS boot entry (host boot order untouched)…"
	mkdir -p "$MNT/boot/EFI/GNOMS"
	cp -f "$src" "$MNT/boot/EFI/GNOMS/grubx64.efi"
	disk=$(lsblk -no PKNAME "$esp")
	partnum=$(cat "/sys/class/block/$(basename "$esp")/partition")
	if efibootmgr -v | grep -qF '\EFI\GNOMS'; then
		success "Firmware entry for \\EFI\\GNOMS already present"
	else
		efibootmgr --create-only --quiet --label GNOMS \
			--disk "/dev/$disk" --part "$partnum" --loader '\EFI\GNOMS\grubx64.efi'
		success "Firmware entry 'GNOMS' added (pick it in the boot menu)"
	fi
}

# Put the repo on the fresh system at ~/GNOMS — the path reconfigure.sh
# expects. It is a copy of the clone the installer is running from (full
# clone, made by bootstrap.sh), so the repo the questions were derived from
# and the repo that gets installed are the same commit. No second download.
# Its origin (the URL bootstrap used, or a local checkout's own remote) is
# recorded as a fact.
pull_repo() {
	local user url dest ids
	user=$(fact_get username)
	url=$(git -c safe.directory="$REPO" -C "$REPO" remote get-url origin 2>/dev/null || echo "${GNOMS_REPO_URL:-unknown}")
	fact_set repo_url "$url"
	dest="$MNT/home/$user/GNOMS"
	step "Copying repo → /home/$user/GNOMS on the target (origin: $url)…"
	rm -rf "$dest"
	mkdir -p "$(dirname "$dest")"
	cp -a "$REPO" "$dest"
	# uid:gid as the target assigned them (nixos-install created the user).
	ids=$(awk -F: -v u="$user" '$1==u { print $3":"$4 }' "$MNT/etc/passwd")
	[ -n "$ids" ] || die "User $user not found in $MNT/etc/passwd after install."
	chown -R "$ids" "$MNT/home/$user"
	success "Repo in place, owned by $user ($ids)"
}

# configuration.nix hardcodes `resume_offset=<n>` — the physical position of
# /var/lib/swapfile on the machine the repo was last installed on. This
# machine's swapfile was just created, so its offset (fact resume_offset)
# is usually different. Offer to replace the literal in the *cloned* repo
# on the target; that is the only edit, and the user commits it as part of
# their own spin.
#
# Split in two so the question sits with the other questions (the offset
# is known right after the disk step) and the edit happens once the repo
# is on the target: ask_resume_offset → fact resume_offset_old (+ _apply);
# apply_resume_offset does the sed.
ask_resume_offset() {
	local old new
	new=$(fact_get resume_offset)
	old=$(sed -n 's/.*resume_offset=\([0-9]\+\).*/\1/p' "$REPO/nixos/configuration.nix" 2>/dev/null | head -1)
	fact_set resume_offset_apply false
	if [ -z "$old" ]; then
		warn "No resume_offset=<n> literal in nixos/configuration.nix — nothing to update (this machine's value is ${new})."
		return 0
	fi
	fact_set resume_offset_old "$old"
	[ "$old" = "$new" ] && { success "resume_offset in configuration.nix already matches this machine (${old})."; return 0; }

	section "Hibernation offset"
	echo "  The repo's configuration.nix says   resume_offset=${old}"
	echo "  This machine's new swapfile sits at resume_offset=${new}"
	echo
	echo "  The offset is where the swapfile physically lands on the disk, so it"
	echo "  differs per install. Hibernation only resumes from the right one: with"
	echo "  the old value this machine would hibernate fine but boot fresh instead"
	echo "  of resuming. Replacing it changes one number in the cloned repo, which"
	echo "  you then commit to your own fork."
	if confirm "Use ${new} in nixos/configuration.nix?"; then
		fact_set resume_offset_apply true
	else
		warn "Keeping resume_offset=${old}; hibernation will not resume on this machine until it is updated."
	fi
}

apply_resume_offset() {
	[ "$(fact_get resume_offset_apply)" = true ] || return 0
	local cfg old new
	cfg="$MNT/home/$(fact_get username)/GNOMS/nixos/configuration.nix"
	old=$(fact_get resume_offset_old)
	new=$(fact_get resume_offset)
	sed -i "s/resume_offset=${old}/resume_offset=${new}/" "$cfg"
	success "configuration.nix now uses resume_offset=${new} (uncommitted change in ~/GNOMS)"
}

# -------------------- Phase 4: the profile --------------------
# Keys are derived from the repo's user/userprofile.nix, never hardcoded:
# nix evaluates the file (types + values), the file's own line order gives
# the question order. One question per key, default = the repo's value.
# Answers → facts `profile_<key>=<type>:<value>`; write_userprofile later
# swaps the values in place in the target's copy (comments, order and any
# key of a type we do not ask about stay untouched).

PROFILE_FILE="user/userprofile.nix"
# Keys the installer already knows — asked earlier or computed, never asked here.
PROFILE_FROM_FACTS="username hostname keyboard_layout dualboot"

# key<TAB>type<TAB>value per line, in file order. Only string/bool/int
# are askable; other types are listed so they can be reported as kept.
profile_read() {
	local f="$REPO/$PROFILE_FILE" evald order k
	evald=$(nix --extra-experimental-features 'nix-command flakes' eval --raw --file "$f" --apply '
		p: builtins.concatStringsSep "\n" (map (k:
			let v = p.${k}; t = builtins.typeOf v;
			in "${k}\t${t}\t" + (if t == "bool" then (if v then "true" else "false")
			                     else if t == "string" || t == "int" then toString v
			                     else "")
		) (builtins.attrNames p))') ||
		die "Could not evaluate $PROFILE_FILE with nix."
	order=$(sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p' "$f")
	for k in $order; do
		awk -F'\t' -v k="$k" '$1 == k' <<<"$evald"
	done
}

profile_hint() {	# one line of context per known key; custom keys get a generic one
	case "$1" in
		timezone)     echo "IANA name, e.g. Europe/Oslo" ;;
		locale)       echo "system language and formats, e.g. en_GB.UTF-8" ;;
		terminal)     echo "command name; exported as \$TERMINAL system-wide" ;;
		editor)       echo "command name; exported as \$EDITOR system-wide" ;;
		browser)      echo "command name; exported as \$BROWSER system-wide" ;;
		boot_timeout) echo "seconds the GRUB menu waits before booting the default entry" ;;
		github_name)  echo "git commit author name" ;;
		github_email) echo "git commit author email" ;;
		*)            echo "custom key of this fork (read as profile.$1 in its nix files)" ;;
	esac
}

# Ask one key; validation depends on the type (and a few known keys).
# Called inside $(…): only the answer goes to stdout, everything else to
# stderr (read -p already prompts on stderr).
profile_ask_key() {	# profile_ask_key KEY TYPE DEFAULT -> prints the answer
	local k="$1" t="$2" d="$3" v yn
	echo -e "    ${DIM}$(profile_hint "$k")${RESET}" >&2
	while true; do
		case "$t" in
			bool)
				yn=n; [ "$d" = true ] && yn=y
				v=$(ask_def "$k (y/n)" "$yn")
				case "$v" in
					[Yy]*|true)  echo true; return ;;
					[Nn]*|false) echo false; return ;;
				esac
				warn "Answer y or n." >&2 ;;
			int)
				v=$(ask_def "$k" "$d")
				[[ "$v" =~ ^-?[0-9]+$ ]] && { echo "$v"; return; }
				warn "Enter a whole number." >&2 ;;
			string)
				v=$(ask_def "$k" "$d")
				[ -n "$v" ] || { warn "Cannot be empty." >&2; continue; }
				if [ "$k" = timezone ] && [ -d /etc/zoneinfo ] && [ ! -e "/etc/zoneinfo/$v" ]; then
					warn "Unknown timezone '$v' (see /etc/zoneinfo)." >&2; continue
				fi
				if [ "$k" = locale ] && [[ ! "$v" =~ ^[a-z]{2,3}(_[A-Z]{2})?(\.[A-Za-z0-9-]+)?(@[a-z]+)?$ ]]; then
					warn "Does not look like a locale (e.g. en_GB.UTF-8)." >&2; continue
				fi
				echo "$v"; return ;;
		esac
	done
}

ask_profile() {
	local mode line k t d v skipped=""
	section "Profile"
	echo "  user/userprofile.nix holds the personal settings every GNOMS file reads."
	echo "    1) Setup (recommended) — go through each key; Enter keeps the repo's value"
	echo "    2) Use this exact setup — zero questions; only for the repo's own owner"
	mode=$(ask_def "Choice" "1")
	[ "$mode" = 1 ] || [ "$mode" = 2 ] || die "Bad choice."

	# Keys the installer already knows are always applied from facts —
	# in both modes — so profile and baseline never disagree.
	for k in $PROFILE_FROM_FACTS; do
		v=$(fact_get "$k")
		[ -n "$v" ] || continue
		t=string; [ "$k" = dualboot ] && t=bool
		fact_set "profile_$k" "$t:$v"
	done
	if [ "$mode" = 2 ]; then
		success "Keeping the repo's profile (username/hostname/keyboard/dualboot from this install)."
		return 0
	fi

	# Read everything first (so a nix failure dies here), then loop on fd 3 —
	# stdin stays the terminal for the prompts inside the loop.
	local data
	data=$(profile_read)
	echo
	while IFS=$'\t' read -r -u 3 k t d; do
		[ -n "$k" ] || continue
		# Known keys are skipped only when a fact actually exists for them
		# (keyboard_layout has none when run outside the ISO).
		case " $PROFILE_FROM_FACTS " in *" $k "*) [ -z "$(fact_get "$k")" ] || continue ;; esac
		case "$t" in
			string|bool|int) ;;
			*) skipped="$skipped $k($t)"; continue ;;
		esac
		v=$(profile_ask_key "$k" "$t" "$d")
		fact_set "profile_$k" "$t:$v"
	done 3<<<"$data"
	[ -z "$skipped" ] || warn "Kept as-is (not askable):${skipped}"
	success "Profile answers recorded."
}

# Escape a shell string for use inside a Nix double-quoted string.
nix_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//\$\{/\\\$\{}"; printf '"%s"' "$s"; }

# Replace `key = …;` in place in the target's userprofile.nix, one key at a
# time. Indentation is kept; a trailing comment on that line is not.
write_userprofile() {
	local user f line k tv t v
	user=$(fact_get username)
	f="$MNT/home/$user/GNOMS/$PROFILE_FILE"
	[ -f "$f" ] || die "No $f on the target — repo copy missing?"
	step "Writing profile answers into ~/GNOMS/$PROFILE_FILE…"
	local rc
	while IFS='=' read -r line tv; do
		k="${line#profile_}"
		t="${tv%%:*}"; v="${tv#*:}"
		[ "$t" = string ] && v=$(nix_str "$v")
		rc=0
		K="$k" V="$v" awk '
			!done && $0 ~ "^[[:space:]]*" ENVIRON["K"] "[[:space:]]*=" {
				match($0, /^[[:space:]]*/)
				print substr($0, 1, RLENGTH) ENVIRON["K"] " = " ENVIRON["V"] ";"
				done = 1; next
			}
			{ print }
			END { if (!done) exit 3 }
		' "$f" > "$f.tmp" || rc=$?
		if [ "$rc" -eq 3 ]; then
			# Key missing from the file (e.g. keyboard_layout on a fork that
			# dropped it): add it before the closing brace.
			warn "Key '$k' not in $PROFILE_FILE — appending it."
			sed '$ d' "$f" > "$f.tmp"; printf '  %s = %s;\n}\n' "$k" "$v" >> "$f.tmp"
		elif [ "$rc" -ne 0 ]; then
			die "awk failed rewriting $PROFILE_FILE (key $k)."
		fi
		mv "$f.tmp" "$f"
	done < <(grep '^profile_' "$FACTS")
	chown "$(stat -c %u:%g "$(dirname "$f")")" "$f"
	success "$PROFILE_FILE updated (uncommitted change in ~/GNOMS)"
}

# -------------------- Phase 5: the programs --------------------
# Everything in configuration.nix / home.nix installs regardless — that is
# the baseline. user/userprograms.nix is the only opt-out surface, and the
# choice is all-or-nothing: show the repo's list, ask "all of them" or
# "none of them (faster install)". No individual picking. Fact
# `programs_mode=all|none`; write_userprograms empties the file for none.

PROGRAMS_FILE="user/userprograms.nix"

# The list bodies of userprograms.nix as written (names, trailing comments,
# group comments), for display. Read textually: the file's own rule is one
# name per line.
show_programs() {
	local f="$REPO/$PROGRAMS_FILE" n
	n=$(sed 's/#.*//' "$f" | grep -cE '^[[:space:]]+[A-Za-z0-9_][A-Za-z0-9_.-]*[[:space:]]*$' || true)
	echo "  $PROGRAMS_FILE lists ${n} programs beyond the baseline:"
	echo
	awk '
		/^[[:space:]]*(system|user)[[:space:]]*=[[:space:]]*\[/ { inlist = 1; label = $1; next }
		inlist && /^[[:space:]]*\];/ { inlist = 0; next }
		inlist && NF { sub(/^[[:space:]]+/, ""); if ($0 ~ /^#/) print "    " $0; else print "      " $0 }
	' "$f"
	echo
	return 0
}

ask_programs() {
	local mode
	section "Programs"
	show_programs
	echo "  The core system (configuration.nix / home.nix) installs either way."
	echo "    1) All of them (Enter) — the fork owner's full setup"
	echo "    2) None of them — faster install; add programs later in $PROGRAMS_FILE"
	mode=$(ask_def "Choice" "1")
	case "$mode" in
		1) fact_set programs_mode all;  success "Installing the full program list." ;;
		2) fact_set programs_mode none; success "No extra programs — $PROGRAMS_FILE will be emptied." ;;
		*) die "Bad choice." ;;
	esac
}

# For "none": rewrite the target's userprograms.nix with empty lists. The
# header comment (it documents the module-managed programs) is kept:
# everything above the `{ pkgs, ... }:` line.
write_userprograms() {
	[ "$(fact_get programs_mode)" = none ] || return 0
	local f header
	f="$MNT/home/$(fact_get username)/GNOMS/$PROGRAMS_FILE"
	[ -f "$f" ] || die "No $f on the target — repo copy missing?"
	step "Emptying ~/GNOMS/$PROGRAMS_FILE…"
	header=$(sed -n '/^{ pkgs/q;p' "$f")
	{
		[ -n "$header" ] && printf '%s\n' "$header"
		printf '{ pkgs, ... }: with pkgs; {\n  system = [\n\n  ];\n\n  user = [\n\n  ];\n}\n'
	} > "$f.tmp"
	mv "$f.tmp" "$f"
	chown "$(stat -c %u:%g "$(dirname "$f")")" "$f"
	success "$PROGRAMS_FILE emptied (uncommitted change in ~/GNOMS)"
}

# -------------------- Phase 6: full build + handoff --------------------
# No reboot between the baseline and GNOMS: nixos-install is a chroot
# install driven from the ISO, so it simply runs a second time with the
# flake (exactly what `reconfigure rebuild` does on a running system) and
# the machine boots straight into the finished GNOMS. The baseline stays
# in GRUB's generation list as the safety net.

# Optional: the user's own fork. GNOMS is meant to be forked; if they have
# one already, origin on the target copy points at it from the start.
ask_fork() {
	local url
	section "Your fork"
	echo "  GNOMS is meant to be forked and spun, not used as-is. If you already"
	echo "  made your fork, give its URL and ~/GNOMS will push there. Enter = not yet."
	url=$(ask_def "Your fork's git URL" "")
	fact_set fork_url "$url"
}

set_fork_remote() {
	local url dest
	url=$(fact_get fork_url)
	[ -n "$url" ] || return 0
	dest="$MNT/home/$(fact_get username)/GNOMS"
	# The copy is owned by the new user; git (as root) refuses "dubious
	# ownership" without safe.directory.
	git -c safe.directory="$dest" -C "$dest" remote set-url origin "$url" && success "origin → $url"
}

# Shown once, right before the long unattended part starts.
intro_unattended() {
	local url fork
	url=$(git -c safe.directory="$REPO" -C "$REPO" remote get-url origin 2>/dev/null || echo "${GNOMS_REPO_URL:-the repo}")
	fork=$(fact_get fork_url)
	section "Installing"
	cat <<EOF
  Everything is answered — from here on nothing needs you. It takes a while
  (two system builds, mostly downloads). What happens now:

    1. A bare NixOS goes on first: it boots, has network and your user.
       That is the safety net — if the GNOMS build fails, it still boots,
       with the repo in your home to fix things from.
    2. The repo is copied to ~/GNOMS and your answers are written into
       user/userprofile.nix and user/userprograms.nix.
    3. GNOMS itself is built on top, from the flake in /etc/nixos — the same
       thing 'reconfigure rebuild' does from now on. No reboot in between:
       the machine boots straight into the finished system.

  Meanwhile, make it yours. GNOMS is meant to be forked, not used as-is:
  a fork is where your profile, programs and tweaks live, and where
  'reconfigure' pulls from on every machine you install.
EOF
	if [ -n "$fork" ]; then
		echo "  ~/GNOMS already points at your fork: $fork"
		echo "  After the first boot:   cd ~/GNOMS && git commit -am 'my machine' && git push"
	else
		echo "  Fork $url on GitHub now, then after the first boot:"
		echo "      cd ~/GNOMS && git remote set-url origin <your fork>"
		echo "      git commit -am 'my machine' && git push"
	fi
	echo "  Your profile, programs and hibernation offset are already waiting there"
	echo "  as uncommitted changes."
	echo
}

# Same as reconfigure.sh's sync_flake, against the target: the flake files
# and user/ go next to the hardware-configuration.nix that Phase 3 made.
# The baseline configuration.nix is kept as configuration.baseline.nix.
sync_flake_target() {
	local src f
	src="$MNT/home/$(fact_get username)/GNOMS"
	step "Copying the flake into $TARGET_NIXOS…"
	cp -f "$TARGET_NIXOS/configuration.nix" "$TARGET_NIXOS/configuration.baseline.nix"
	for f in flake.nix configuration.nix home.nix flake.lock; do
		cp -f "$src/nixos/$f" "$TARGET_NIXOS/$f"
	done
	mkdir -p "$TARGET_NIXOS/user"
	cp -f "$src/user/userprofile.nix" "$src/user/userprograms.nix" "$TARGET_NIXOS/user/"
	chown -R root:root "$TARGET_NIXOS"
	chmod 644 "$TARGET_NIXOS"/*.nix "$TARGET_NIXOS"/user/*.nix
	chmod 600 "$TARGET_NIXOS/configuration.baseline.nix"	# holds the password hash
	success "Flake and profile in place"
}

install_gnoms() {
	local host
	host=$(fact_get hostname)
	step "Building GNOMS (nixos-install --flake $TARGET_NIXOS#$host) — the long one…"
	if nixos-install --root "$MNT" --flake "$TARGET_NIXOS#$host" --no-root-passwd; then
		fact_set gnoms_installed true
		success "GNOMS built and installed"
	else
		fact_set gnoms_installed false
		warn "The GNOMS build failed. The bare NixOS still boots (it is the GRUB default"
		warn "generation). Log in as $(fact_get username), fix what broke, then:"
		warn "    cd ~/GNOMS/nixos && ./reconfigure.sh rebuild"
	fi
}

handoff() {
	local user host
	user=$(fact_get username); host=$(fact_get hostname)
	if [ "$(fact_get gnoms_installed)" = true ]; then
		section "Done — GNOMS is installed on $host"
	else
		section "Done — bare NixOS installed on $host (GNOMS build failed, see above)"
	fi
	cat <<EOF
  How to treat this system:

    ~/GNOMS is the system. Edit there — never ~/.config, never /etc/nixos.
      reconfigure reload    sync dotfiles + scripts, restart AwesomeWM
      reconfigure rebuild   copy the flake to /etc/nixos, nixos-rebuild switch, reload
      reconfigure update    update flake inputs (packages) without activating
      reconfigure upgrade   update, then rebuild
    user/     yours: profile, programs, logo, wallpaper
    nixos/ dotfiles/ scripts/   the managed system — fork it, then change it
    /etc/nixos/hardware-configuration.nix   this machine's; never goes in the repo

  First things after the first boot, as $user:
    1. cd ~/GNOMS && git status      — your answers sit there uncommitted
    2. commit and push them to your fork (see above if you have none yet)

EOF
}

finish() {
	cp -f "$FACTS" "$TARGET_NIXOS/gnoms-install-facts"	# for post-install debugging
	if confirm "Unmount and reboot into the new system now?"; then
		step "Unmounting…"
		umount -R "$MNT"
		cryptsetup close "luks-$(fact_get luks_uuid)" || true
		success "Rebooting. Remove the USB stick when the screen goes dark."
		reboot
	else
		echo "  Still mounted at $MNT for a look around. When done:"
		echo "      umount -R $MNT && cryptsetup close luks-$(fact_get luks_uuid) && reboot"
	fi
}

# -------------------- Main --------------------

assert_root
assert_uefi
mountpoint -q "$MNT" && die "$MNT is already mounted (a previous run?). umount -R $MNT first."
rm -f "$FACTS"	# never inherit answers from an earlier, aborted run

[ -n "${GNOMS_BOOTSTRAPPED:-}" ] || banner "installer"
section "Disk setup"

# Keyboard may have been set by bootstrap.sh on the ISO; apply as default.
if [ -r "$KEYMAP_FILE" ]; then
	km=$(cat "$KEYMAP_FILE")
	if loadkeys "$km" 2>/dev/null; then
		success "Keyboard layout: $km"
		fact_set keyboard_layout "$km"
	fi
fi

step "Scanning for existing operating systems…"
HOST_OSES=$(detect_host_oses)
if [ -n "$HOST_OSES" ]; then
	echo "  Found: ${HOST_OSES}"
else
	echo "  None found on any EFI partition."
fi

echo
echo "  How should GNOMS be installed?"
echo "    1) Whole disk   — GNOMS erases an entire drive and owns it"
echo "    2) Dual boot    — GNOMS takes unpartitioned free space, sharing the ESP"
echo "    3) Advanced     — pick an existing partition to reformat (dual boot)"
mode=$(ask_def "  Choice" "$([ -n "$HOST_OSES" ] && echo 2 || echo 1)")

case "$mode" in
	1) prep_whole_disk ;;
	2) prep_free_space ;;
	3) prep_existing_partition ;;
	*) die "Bad choice." ;;
esac

make_swap "$MNT"

echo
success "Disk prepared:"
echo "    $(fact_get mode) | root: $(fact_get root_fs_uuid) | LUKS: $(fact_get luks_uuid)"
echo "    ESP: $(fact_get esp_part) (new: $(fact_get esp_is_new)) | dualboot: $(fact_get dualboot)"
echo "    swap: $(fact_get swapfile_size_mb) MB at offset $(fact_get resume_offset)"

if [ "${GNOMS_STOP_AFTER_PARTITION:-0}" = "1" ]; then
	success "GNOMS_STOP_AFTER_PARTITION set — stopping here for inspection."
	exit 0
fi

# -------------------- Questions (everything the user is asked) --------------------
# All remaining questions come before the long unattended part, so the
# user answers once and walks away. Answers go to $FACTS; the generated
# files are written into the target's copy of the repo further down.
ask_baseline_facts
ask_resume_offset
ask_profile
ask_programs
ask_fork

# -------------------- Unattended: install + repo + GNOMS --------------------
intro_unattended
generate_hardware_config
write_baseline_config
install_baseline
register_gnoms_boot_entry
pull_repo
set_fork_remote
apply_resume_offset
write_userprofile
write_userprograms
sync_flake_target
install_gnoms

echo
origin=$(fact_get fork_url); origin=${origin:-$(fact_get repo_url)}
success "Summary:"
echo "    host: $(fact_get hostname) | user: $(fact_get username) | dualboot: $(fact_get dualboot)"
echo "    repo: $(fact_get repo_url) → /home/$(fact_get username)/GNOMS (origin: $origin)"
echo "    per-machine config: /etc/nixos/hardware-configuration.nix"
handoff
finish
