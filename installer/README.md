# installer/ — the GNOMS installer

Everything needed to put GNOMS on a blank machine, or next to an existing
OS, from a USB stick. This document covers this directory only; the rest
of the project is described in the root README.

**Status:** written, not yet run end-to-end. Expect rough edges on the first
real install and read the "What it does" section before trusting it with a
disk you care about.

## The idea

- **The USB stick is a bootstrap, not a desktop.** It carries a minimal
  NixOS with network tools and one command, `gnoms`. That command clones
  the repo and runs the installer *from the clone*. The USB never goes
  stale: fix the installer in the repo, and every existing stick picks it
  up on the next run.
- **Any fork works, and no install is tied to upstream.** The ISO bakes in
  the URL of whatever checkout built it and the installer derives its
  questions from the repo it cloned. The copy it leaves on the new machine
  has no `.git` at all: it is yours to `git init` and push wherever you
  like (the handoff message shows how).
- **Encryption is not optional.** The root is always LUKS2 with argon2id.
  What is optional is how much of the disk GNOMS owns.
- **The target ends up with bare NixOS + GNOMS, nothing else.**
- **One user, no root password.** Root stays locked; the user is in `wheel`.

## Files

| File | What it is |
|------|------------|
| `iso.nix` | NixOS module for the installer ISO. Minimal live system: NetworkManager (`nmtui`) + ModemManager, `git`, `curl`, `neovim`, the `gnoms` command. Auto-logs in on tty1 and starts `gnoms` by itself. Exit or Ctrl-C drops to a shell. Built through the flake as `nixos#iso`. |
| `build-iso.sh` | Builds the ISO. Reads this checkout's `git remote get-url origin`, rewrites an SSH remote to HTTPS (the live ISO has no keys) and bakes it in, so a fork's stick installs the fork. Result: `installer/result/iso/*.iso`. |
| `bootstrap.sh` | The `gnoms` command on the ISO (inlined into the image at build time, together with `ui.sh`). Asks for the keyboard layout and the repo URL, clones the repo into RAM, hands over to `install.sh`. |
| `install.sh` | The installer itself. Lives in the repo, always runs from a clone. Disk prep, questions, two `nixos-install` passes, handoff. Details below. |
| `ui.sh` | Shared look for the three scripts: colors (only when stdout is a terminal), `step` / `success` / `warn` / `die`, the prompts (`ask`, `ask_def`, `confirm`, `ask_secret`), `banner` (the logo + project name) and `section` (ruled headings). Sourced, never run. |
| `result` | Symlink left by `build-iso.sh`; gitignored. |

The logo the banner prints is `user/logo.txt` at the repo root. It is
referenced, never copied: the scripts point at the repo file, the ISO ships
it at `/etc/gnoms/logo.txt` because the bootstrap runs before any clone
exists.

## Building and booting the stick

```bash
installer/build-iso.sh
sudo dd if=installer/result/iso/*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Boot the stick in UEFI mode. tty1 logs in on its own and `gnoms` starts.
No network? Ctrl-C, run `nmtui`, then `gnoms` again. Other TTYs show a
short reminder of exactly that.

`nix build ./nixos#iso` also works, but then no repo URL is baked in and the
stick falls back to the default at the top of `bootstrap.sh`.

Environment knobs for `build-iso.sh`:

| Variable | Effect |
|----------|--------|
| `GNOMS_REPO_URL` | Override the URL instead of reading the git remote. |
| `GNOMS_REPO_BRANCH` | Pin a branch. Empty means the remote's default branch. |

## Which repo gets installed

Three layers, easiest first:

1. **The prompt.** `gnoms` always shows the URL it is about to clone and
   lets you type another one. Enter keeps it.
2. **`DEFAULT_REPO_URL`** — one boxed line at the top of `bootstrap.sh`.
   Change it when you port the installer to your fork and build the ISO
   by hand.
3. **`build-iso.sh`** bakes the building checkout's `origin` over that
   default, so a stick built from your fork already points at your fork
   with zero edits.

## What `install.sh` does, in order

Everything the user is asked comes first. After the last question the
machine works on its own for a long while (two system builds).

**1. Disk.** Scans the EFI partitions for other operating systems, then
asks how to install:

- *Whole disk* — erases a drive (you type its full device name to
  confirm). GPT with an ESP and one LUKS2 root.
- *Dual boot* — takes the largest unpartitioned gap on a disk, shares the
  existing ESP (or creates one from free space if the disk has none). No
  existing partition is touched. Default when another OS was found.
- *Advanced* — reformats one chosen existing partition as the root, keeps
  the disk's ESP.

Then the LUKS passphrase, `mkfs.ext4`, mount at `/mnt` with the ESP at
`/mnt/boot`, and a swapfile at `/var/lib/swapfile` on the encrypted root.
The swapfile's default size is what `nixos/configuration.nix` declares
(`swapDevices … size = …`), because NixOS recreates the file at that size
on the first rebuild; a different choice here gets overwritten. The install
medium can never be a target.

Set `GNOMS_STOP_AFTER_PARTITION=1` to stop right here, mounted, for a look.

**2. Questions.**

- *Baseline system* — username, hostname (defaults from the repo's
  `user/userprofile.nix`) and a password.
- *Hibernation offset* — only if the `resume_offset=<n>` in the repo's
  `configuration.nix` differs from where this machine's swapfile landed.
  Explains why, offers to replace the number. Nothing else in that file is
  ever touched.
- *Profile* — either "use this exact setup" (zero questions, meant for the
  repo's owner) or one question per key of `user/userprofile.nix`, with the
  repo's value as default. Keys are read from the file with `nix eval`, so
  a fork that adds keys gets asked about them too. Username, hostname,
  keyboard layout and `dualboot` are never asked here: the first three were
  answered already, the last one is computed from the disk step.
- *Programs* — shows the lists in `user/userprograms.nix` and asks: all of
  them, or none of them (faster install, add programs later). No
  individual picking. The core system from `configuration.nix` and
  `home.nix` installs either way.

**3. Unattended.** An intro text explains what follows and that the copy
in your home will be yours to put in a repo. Then:

1. `nixos-generate-config` writes `/etc/nixos/hardware-configuration.nix`
   on the target. That is the one per-machine file. It never goes in the
   repo.
2. A **baseline configuration.nix** (GRUB, NetworkManager, the user, git,
   neovim) and the first `nixos-install`. This bare NixOS is the safety
   net: it boots on its own even if the GNOMS build fails.
3. Dual boot only: NixOS's GRUB was installed with `--no-nvram`, so the
   installer copies it to `/EFI/GNOMS/grubx64.efi` and adds a "GNOMS"
   firmware entry with `--create-only`. The other OS's boot order is never
   changed; GNOMS shows up next to it in the firmware boot menu.
4. The clone the installer runs from is **copied without its `.git`** to
   `~/GNOMS` on the target (same commit the questions came from, no second
   download, no tie to upstream) and your answers are written into it: the
   profile values are replaced in place in `user/userprofile.nix`
   (comments and custom keys survive), `user/userprograms.nix` is emptied
   if you said "none", the offset is swapped if you said yes.
5. The flake files and `user/` are copied next to the hardware config in
   `/etc/nixos`, exactly like `reconfigure rebuild` does later, and a
   second `nixos-install --flake /mnt/etc/nixos#<hostname>` builds GNOMS.
   No reboot in between: `nixos-install` is a chroot install driven from
   the stick. The baseline stays selectable in GRUB, and its config is kept
   as `/etc/nixos/configuration.baseline.nix`.
6. Handoff text: how to treat the system, and the exact commands to turn
   `~/GNOMS` into your own repo (`git init`, push to an empty remote,
   optionally add the upstream remote to pull improvements later). Then
   "unmount and reboot now?".

Machine facts collected along the way (`/tmp/gnoms-facts` on the stick,
copied to `/etc/nixos/gnoms-install-facts` on the target) are plain
`KEY=VALUE` lines, handy when something needs debugging.

If the GNOMS build fails, the installer says so and the machine still boots
into bare NixOS. Log in, fix what broke, then `cd ~/GNOMS/nixos &&
./reconfigure.sh rebuild`.

## Customizing

- **Point it at your fork:** fork the repo, build the stick from your
  checkout. That is it. For a hand-built ISO, change `DEFAULT_REPO_URL` in
  `bootstrap.sh`.
- **Ask about more profile keys:** add the key to `user/userprofile.nix`.
  The installer picks it up (strings, booleans, integers). Add a one-line
  explanation for it in `profile_hint` in `install.sh` if you like; unknown
  keys get a generic one.
- **Change the program list:** edit `user/userprograms.nix`. The installer
  shows whatever is there.
- **Change the baseline system:** `write_baseline_config` in `install.sh`
  is a small heredoc. Keep it bootable and keep the GRUB block in step with
  the `boot.loader` section of `nixos/configuration.nix`, especially the
  dual-boot handling.
- **Change what the ISO carries:** `iso.nix`. Keep it minimal; anything
  the installer needs beyond the base ISO tools goes here, everything else
  belongs in the repo and arrives with the clone.
- **Change the look:** `ui.sh`, one place for all three scripts.
- **Run the installer without the stick:** from a booted NixOS (live or
  installed), as root, `bash installer/install.sh <path-to-checkout>`.
  It requires UEFI and an unmounted `/mnt`.

## Decisions worth knowing before you change things

- **`hardware-configuration.nix` never lives in the repo.** It is
  generated on the target at install time and stays in `/etc/nixos`.
- **`resume_offset` is a plain literal in `nixos/configuration.nix`.** It
  is the physical position of the swapfile on the disk, so it is different
  per install; the installer's only involvement is offering to swap that
  one number in the copy on the new machine. It is not a profile key and
  not generated anywhere.
- **`configuration.nix` is not edited by the installer** beyond that
  optional number. The swapfile size it declares is what the installer
  creates.
- **Dual boot is a contained instance.** GNOMS's GRUB lives under
  `/EFI/GNOMS` on the shared ESP with its own firmware entry; it never
  reorders the host's boot menu. From inside GNOMS, os-prober lists the
  other OS. `/boot` is the unencrypted ESP, so GRUB never has to read the
  LUKS container and the argon2id KDF is never a problem.
- **Two `nixos-install` passes, no first-boot magic.** A first-boot
  service that runs the GNOMS build was considered and rejected: a failure
  there would strand a half-configured machine instead of a clean bare
  NixOS.
- **The profile file is rewritten in place, not regenerated,** so its
  comments and any custom-key documentation survive.
- **The copy on the target has no git history.** Deliberate: an install
  must never be bound to the repo it came from. The user makes it a repo
  of their own afterwards; the handoff prints the commands.
