#!/usr/bin/env bash
# install.sh — the GNOMS installer. Lives in the repo (fetched at install
# time by bootstrap.sh), so it can grow without the ISO going stale.
#
# Usage: install.sh [repo-root]    (bootstrap.sh passes the clone path)
#
# Implements: Phase 1 — partitioning + LUKS2 + swapfile/resume_offset.
# Phases 3-6 (baseline install, repo pull, profile/programs questions,
# handoff) slot in at the marked TODOs.
#
# VM testing: set GNOMS_STOP_AFTER_PARTITION=1 to stop once the disk is
# prepared and mounted, so the result can be inspected before continuing.

set -euo pipefail

REPO="${1:-}"
FACTS="/tmp/gnoms-facts"
KEYMAP_FILE="/tmp/gnoms-keymap"
MNT="/mnt"

ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
ESP_DEFAULT_MB=1024
MIN_ROOT_MB=20480   # warn if root gets under 20 GiB
SWAP_MIN_MB=1024

# -------------------- Colors / output --------------------
GREEN="\033[1;32m"
PURPLE="\033[38;2;135;0;255m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
RESET="\033[0m"

step()    { echo -e "${PURPLE}[  ▶▶  ]${RESET} $1"; }
success() { echo -e "${GREEN}[  OK  ]${RESET} $1"; }
warn()    { echo -e "${YELLOW}[ WARN ]${RESET} $1"; }
die()     { echo -e "${RED}[  !!  ]${RESET} $1" >&2; exit 1; }

ask()      { local v; read -r -p "$1" v; echo "$v"; }
ask_def()  { local v; read -r -p "$1 [$2]: " v; echo "${v:-$2}"; }
confirm()  { local a; read -r -p "$1 [y/N]: " a; [[ "$a" =~ ^[Yy] ]]; }

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
		read -r -s -p "  LUKS passphrase for root (unlocks the disk on every boot): " pass; echo
		read -r -s -p "  Repeat: " pass2; echo
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

make_swap() {	# make_swap MNT — swapfile lives on the encrypted root
	local mnt="$1" ram_mb size_mb offset
	ram_mb=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
	while true; do
		size_mb=$(ask_def "  Swapfile size in MB (must be ≥ RAM for hibernation)" "$ram_mb")
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
	success "Swapfile ready; resume_offset=$offset"
	# Phase 4 note: configuration.nix's swapDevices must drop its `size` key
	# so NixOS never recreates/resizes the file (that would move the offset).
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

# -------------------- Main --------------------

assert_root
assert_uefi

echo -e "${PURPLE}  ── GNOMS installer — disk setup ──${RESET}"

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

# TODO Phase 3: baseline NixOS install (nixos-install with generated config),
#               repo pull onto the target, repo-URL derivation.
# TODO Phase 4: profile questions → generate user/userprofile.nix.
# TODO Phase 5: programs question → generate user/userprograms.nix.
# TODO Phase 6: handoff message + kick off full build/switch.
die "Disk setup complete, but install steps (Phase 3+) are not implemented yet."
