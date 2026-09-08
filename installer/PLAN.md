# installer/PLAN.md — GNOMS installer implementation plan

_Status (2026-09-08): Phase 2 core shipped; everything else pending. The old
root PLAN.md is retired — its live items (fresh install.sh, ISO build,
README section) are absorbed into the phases below. The old broken
install.sh has been deleted; the installer is written fresh._


## Where we are

- `nixos/configuration.nix` + `user/userprofile.nix`: **dualboot key shipped**
  (see Phase 2). Evaluated in a sandbox for both modes.
- `installer/install.sh`: **written fresh (2026-09-08, Phase 1 scope)**.
  Three modes — whole disk (typed-path confirm, GNOMS owns everything),
  dual boot into unpartitioned free space (shares existing ESP, or creates
  one from free space if the target disk has none; host partitions never
  touched), and advanced (reformat a chosen partition). LUKS2 + argon2id,
  ext4, mapper named `luks-<luks-uuid>` (matches nixos-generate-config so
  Phase 3's generated hardware-configuration lines up), ESP mounted at
  /mnt/boot (matching Gerhard's /boot layout), swapfile on the encrypted
  root with resume_offset via filefrag. Machine-generated facts go to
  /tmp/gnoms-facts (mode, dualboot, esp/root/LUKS uuids, swap size, offset,
  keymap) for Phases 3–4. `GNOMS_STOP_AFTER_PARTITION=1` stops after disk
  prep for VM inspection. Install steps beyond disk prep are marked TODO.
- `installer/iso.nix` + flake `#iso`: evaluate fine (`nix build ./nixos#iso`
  resolves; Nix walks up to the git repo root, so `../installer/iso.nix` is
  in-tree). Not yet built/test-booted. Expected size ~1.3–1.5 GiB
  (official minimal ISO ~1.1–1.2 GiB + NM/ModemManager/git/curl/neovim).
- `installer/bootstrap.sh`: kept — the ISO's tiny `gnoms` entry point
  (clone repo at install time → run the fresh installer). Phase 0 adds the
  keyboard-layout prompt as its first step and Phase 0 makes the ISO
  auto-login (`services.getty.autologinUser = "nixos"`) with autorun.
  Decided: autorun style, keyboard defaults to `no`, first prompt offers a
  change; the chosen layout becomes the default for the installer's later
  `keyboard_layout` question (answered once, used twice).
- **Phase 0 shipped (2026-09-08):** `iso.nix` — autologin + `loginShellInit`
  autorun of `gnoms` on tty1 (exit/Ctrl-C drops to shell), ModemManager
  (`networking.modemmanager.enable` in this nixpkgs rev), updated banner;
  ISO default keymap stays `no`. `bootstrap.sh` — self-`sudo` re-exec (the
  ISO logs in as `nixos`, so no root check that would die), keyboard prompt
  first (Enter = `no`, `list` hint, `loadkeys` validation with retry), chosen
  layout written to `/tmp/gnoms-keymap` for the installer's later default.
  Verified: `bash -n` clean, prompt-loop logic simulated (bad input / list /
  Enter / EOF), full flake eval passes. Remaining: `nix build ./nixos#iso`
  + qemu boot smoke test.

Testing policy (decided 2026-09-08): **the agent writes code and does no
functional testing.** No test scaffolding, mock harnesses, or simulated
flows — ever. Static checks only while writing (bash -n, nix eval).
**Gerhard runs all testing**: qemu UEFI VMs with virtual disks for
installer flows, then real hardware for final validation.

Repo rule (decided 2026-09-08): **hardware-configuration.nix never lives
in the repo.** It is a per-machine file at `/etc/nixos` on the target,
regenerated at install time (Phase 3) — every fork gets its own. Never
add it to the repo, not even for convenience. Consequence: host-config
evals from a checkout need a `/tmp` sandbox copy with a stub
hardware-configuration.nix (static checks only, per testing policy).


## Philosophy

- The ISO is a **bootstrap**, not a desktop: a very limited set of tools, and
  installer logic that always comes from the repo (clone at runtime), never
  baked in — so the USB never goes stale.
- The target machine ends up with **bare NixOS + GNOMS, nothing else**. No
  live desktop, no extra interface.
- Encryption is **the default, not an option**. What IS optional: whether the
  installer owns the whole drive or only the space you point it at.
- This project is meant to be forked and spun. The installer must work for
  *any fork* of GNOMS, not just this repo.


## Phase 0 — Minimal ISO environment  (SHIPPED — build + qemu boot pending)

- NetworkManager + ModemManager (Wi-Fi via `nmtui`, mobile broadband) + wired
  ethernet support. Nothing more.
- Keyboard layout selection at boot/install start — prompt for it
  (`loadkeys`/console keymap) instead of baking `console.keyMap = "no"`
  (current iso.nix hardcodes it).
- `gnoms` entry command (bootstrap: fetch repo → run installer), as today.

Deliverable: `installer/iso.nix` updated; ISO builds (`nix build ./nixos#iso`)
and boots to network + prompts. qemu boot smoke test.


## Phase 1 — Partitioning + LUKS helper  (SHIPPED — VM flow test pending)

Requirements:

- **Automatic partitioning** based on Gerhard's setup (ESP at /boot + LUKS2
  ext4 root — the layout Phase 2 verified), **but scoped**: the installer
  points at a *target* — free space, a partition, or a whole disk — never
  blindly reformats a full drive unless explicitly told to.
- **LUKS2 on the root, default argon2id KDF** — exactly Gerhard's current
  scheme (`cryptsetup luksFormat --type luks2`, initrd unlock). No
  "no encryption" option; no KDF downgrades.
- Filesystem = **ext4** (hardwired in configuration.nix — installer must
  match; no opt-out).
- Existing filesystems on *other* partitions are never touched; dual-boot
  keeps the host's ESP (GNOMS's GRUB joins it, Phase 2).
- Swapfile + `resume_offset` computed here (feeds Phase 4's profile split:
  offset must NOT end up in userprofile).

Deliverable: partition/mount logic in the fresh `installer/install.sh`
(agent-side checks stop at `bash -n`; flow testing is Gerhard's, in qemu
per the testing policy).


## Phase 2 — GRUB & dual-boot  (CONFIG SHIPPED — VM-verify pending)

**Decision (2026-09-08):** Option A — contained instance. GNOMS's GRUB never
touches the boot order of an existing OS. Option C (nested GRUB) rejected:
on UEFI it is just "chainload an EFI binary", which Option A offers anyway
without coupling to the host's bootloader config. Option B (own the ESP /
NVRAM) stays the documented fallback if VM prototyping hits a wall.

**Driven by the new `userprofile.dualboot` key:**

- `dualboot = false` (Gerhard's machine): byte-identical to the old behavior —
  `canTouchEfiVariables = true`, no os-prober, no install hook. (Verified by
  eval: values unchanged, `extraInstallCommands` empty.)
- `dualboot = true` (installer sets it when it detects a dual-boot target):
  - `boot.loader.efi.canTouchEfiVariables = false` → NixOS runs grub-install
    with `--no-nvram`; the host OS's boot order is never touched.
  - NixOS still installs its GRUB to `/boot/EFI/NixOS-boot/grubx64.efi` on
    the ESP (verified in nixpkgs `install-grub.pl`: default id = distroName +
    efiSysMountPoint, `--bootloader-id` always passed — so the binary is
    written even with `--no-nvram`).
  - `boot.loader.grub.extraInstallCommands` (appended to `install-grub.sh`,
    runs after every successful grub install): copies that binary to the
    stable path `/boot/EFI/GNOMS/grubx64.efi` (id interpolated from
    `config.system.nixos.distroName` so it can't drift), then
    `efibootmgr --create-only --label GNOMS` — adds a firmware entry
    *without* reordering the boot menu. Idempotent via fixed-string guard on
    the loader path in `efibootmgr -v`. ESP disk/partition derived at runtime
    (`findmnt` → `/sys/class/block/...` → `lsblk -no PKNAME`).
  - `boot.loader.grub.useOSProber = true` so the host OS still shows up in
    GNOMS's own menu (works in both directions).

**Boot paths:** firmware boot menu lists "GNOMS" next to the host OS (default
stays the host); optional one-line chainload entry
(`chainloader /EFI/GNOMS/grubx64.efi`) can be added to the host GRUB by its
owner; from inside GNOMS, os-prober lists the other OS.

**LUKS: no compromise needed (verified on the live machine).** Kernels/initrd
live on the unencrypted ESP-mounted-at-/boot; the LUKS2 container (argon2id)
is unlocked by cryptsetup *inside the initrd*, not by GRUB. GRUB reads
nothing encrypted — the feared pbkdf2/LUKS1 downgrade never applies to this
layout. (`enableCryptodisk = true` is a no-op here — leftover, cleanup
candidate. NOTE: if anyone ever moves /boot inside LUKS, the pbkdf2
compromise becomes real: GRUB cannot do argon2.)

**VM-verify checklist before Phase 3's bootloader step** (qemu UEFI):
1. dualboot=true: install → reboot → firmware menu shows GNOMS, host entry
   still default, GNOMS boots, efibootmgr entry survives a rebuild.
2. `--create-only` idempotence: rebuild 3×, exactly one GNOMS entry.
3. extraInstallCommands runs during `nixos-install` (not just `switch`).
4. Optional: host-GRUB chainload entry into /EFI/GNOMS works.

Installer wiring (Phase 3/4): detect existing EFI entries / host OS → set
`dualboot = true` in the generated userprofile.


## Phase 3 — Baseline install, then pull the repo  (PENDING)

1. Install **bare NixOS** (baseline, no GNOMS bits, no interface) onto the
   prepared target — partitioning/LUKS/boot from Phases 1–2, boot mode from
   Phase 2's dualboot detection.
2. **Pull the repo from GitHub onto the fresh system.**
   - Repo URL must **not be hardcoded**: at ISO build time, check whether the
     build machine is a git repo and bake in its remote URL
     (`git remote get-url origin`) → a fork builds an ISO that installs
     *that fork*. No editing of installer files needed to spin your own.
   - Fallback for tarball/local builds: prompt for the URL.

Deliverable: repo-URL auto-derivation in the flake/iso build + bootstrap
logic; the fresh install.sh (partition/LUKS from Phase 1, boot mode from
Phase 2, baseline install, repo pull).


## Phase 4 — Installer questions: the profile  (PENDING — resume_offset split done)

Two paths at this point (installer has the repo checked out):

- **"Use this exact setup"** — explicitly NOT recommended, exists only so
  Gerhard can install his own machine with zero questions.
- **"Setup" (recommended)**: the installer **deletes `user/userprofile.nix`**
  from the fresh clone and **generates a new one from user inputs**. Every
  key in the final userprofile comes from the installer (plus computed
  values — including `dualboot` from Phase 2 detection).

Design guide: the userprofile contains *only* things the installer can
ask/compute. Specifically:
- **`resume_offset` OUT of userprofile — DONE (2026-09-08).** It now sits
  as a literal in configuration.nix (`boot.kernelParams`, value =
  Gerhard's current offset) — machine-generated, so never a userprofile
  key. Phase 3's installer moves it into the install-time config
  generation, computed from the swapfile it creates.
- **userprofile gained `terminal` / `editor` / `browser` / `boot_timeout`**
  (moved out of configuration.nix, 2026-09-08). The Phase 4 generator must
  emit every key userprofile carries — the askable-with-defaults set now
  includes these.
- **configuration.nix's swapDevices must drop its `size` key** — the
  installer creates the swapfile itself (Phase 1); if NixOS ever recreated
  or resized it, the offset would move and hibernation would break.

Deliverable: profile generator in install.sh + the userprofile/
configuration split refactor.


## Phase 5 — Installer questions: the programs  (PENDING)

- Some programs install regardless (everything in configuration.nix + the
  home-manager module programs). The only opt-out surface is
  `user/userprograms.nix`.
- Question (skip = keep defaults): **keep default program list or redefine.**
- Redefine = installer **generates `user/userprograms.nix` from user
  input**, but NOT free-text:
  - The user picks from a **curated subset list** that lives in its **own
    file: `installer/programs.nix`** — beside the install script and the
    generated ISO, NOT the full personal list, no arbitrary package names.
  - A package is offered only if it exists **both** in the curated subset
    (`installer/programs.nix`) and in the repo's current `user/userprograms.nix`
    (cross-check) — steels against stale/renamed nixpkgs names failing the
    initial build.

**Format of `installer/programs.nix`:** a Nix file returning a list of
`{ name = "<nixpkgs attr>"; desc = "one-line description"; }` — the
single curated source both the picker UI and the cross-check read. The
installer consumes it (and `user/userprograms.nix`) via `nix eval --json`,
so the shell script never parses Nix by hand; the cross-check is then a set
intersection of the two JSON lists.

Deliverable: `installer/programs.nix` + picker + generator.


## Phase 6 — Handoff  (PENDING — trivial once the rest lands)

- Quick intro on how to treat the system (what `reconfigure` does, what's
  managed vs. yours).
- **Tip to make one's own GitHub repo** — this project should not be used
  without one's own spin; installer prints the fork-your-own nudge as the
  final message before install kicks off.
- Start the install (full GNOMS build/switch on the target).


## Sequencing

1. ✅ Phase 2 config (dualboot key + containment hook) — shipped.
2. ✅ Phase 0 (ISO env + autorun + keyboard prompt) — shipped; build + boot test pending.
3. ✅ Phase 1 (partition/LUKS) — shipped; Gerhard VM-tests each flow.
4. Phase 2 VM-verify checklist — before the installer wires boot detection.
5. Phase 3 (baseline install + repo pull + URL derivation) — the fresh
   install.sh is written here.
6. Phase 4 + 5 (profile/programs generation; `installer/programs.nix`) —
   can be developed against an existing install before the ISO pieces are
   done.
7. Phase 6 (handoff).

Testing: per the testing policy — agent does none. Gerhard tests in qemu
UEFI with virtual disks (installer flows) and on real hardware (final).
README gets the ISO section (build / dd / boot) once the ISO is buildable
end-to-end.
