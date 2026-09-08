# GNOMS — Roadmap / Pick-up-later plan

_Last updated: 2026-09-06. Work in progress: ISO installer (see step 6)._

## 1. Refactor profile.conf → Nix-native variables
Replace the sed/`{{placeholder}}` system with real Nix.

- `personal/profile.conf` → `personal/profile.nix` (plain attrset: hostname, username,
  timezone, locale, github_name, github_email, bar_color, system_programs, user_programs).
- `flake.nix`: import it, use `nixosConfigurations.${profile.hostname}` — kills the
  quoted `"{{hostname}}"` parse hack (needed today so `nix build ./nixos#iso` works).
- `configuration.nix` / `home.nix`: every `{{key}}` → real reference
  (`profile.username`, `profile.timezone`, `profile.system_programs`, ...).
- Lua (theme.lua): support Nix templateStrings — either generate the file with
  `home.file/XDG .text = '' ... ${profile.bar_color} ... ''` or keep a template +
  `lib.replaceStrings` at eval time. No more bash sed for dotfiles.
- `reconfigure.sh`: drop parse_config/apply_template for Nix files; just copy/sync +
  rebuild. Hostname for `--flake ...#<host>` read from profile.nix (grep/import).
- `installer/install.sh`: `set_key` writes into profile.nix instead of profile.conf.

## 2. Clean up `hacky_fixes` in reconfigure.sh
Either delete it or rename to something honest (e.g. `cleanup`), with a comment
explaining the one remaining nvim `.backup` purge. Keep it idempotent.

## 3. Keyboard (+ confirm locale) in profile.nix
- Add `keyboard_layout` (today hardcoded `"no"` in configuration.nix:
  `console.keyMap` + `services.xserver.xkb.layout`).
- Locale already lives in the profile — just make sure it survives the refactor.

## 4. Untrack the personal profile
- `git rm --cached personal/profile.nix` + add to `.gitignore` (it's machine-personal).
- **Important:** a fresh clone then has no profile, so keep a tracked
  `personal/profile.nix.example` (or make the flake fail with a friendly message),
  and make the installer create profile.nix from its prompts.

## 5. README: true design philosophy
Reframe from "this is Gerhard's PC config" to:
**"a NixOS setup that is easy to customize even without Nix experience"** —
`/personal/profile.nix` as the single no-Nix-knowledge-required entry point,
reconfigure as the one command, ISO installer for bare metal.

## 6. ISO installer (IN PROGRESS — mostly built, uncommitted)
Current state (staged in git, validated, ISO build not finished):
- `installer/bootstrap.sh` — baked into ISO; clones GNOMS@master, runs repo installer.
- `installer/install.sh` — prompts (partitions, LUKS, identity), 32G swapfile +
  resume_offset, generates hardware-configuration.nix, templates into /mnt/etc/nixos,
  `nixos-install --flake`.
- `installer/iso.nix` — minimal CLI ISO, NetworkManager/nmtui, `gnoms` command.
- `flake.nix` — `nixosConfigurations.installer` + `packages.x86_64-linux.iso`.
- Validated: flake evaluates, fully-templated host config evaluates.
Remaining: finish `nix build ./nixos#iso`, test-boot or at least review ISO,
commit, README section (build / dd / boot / `sudo gnoms`).
Update: after step 1 lands, installer templates via Nix — revisit install.sh.

## 7. README: installer section
Build (`nix build ./nixos#iso`), flash (`dd ... of=/dev/sdX`), boot, connect Wi-Fi
(`nmtui`), run `sudo gnoms`. Note dual-boot + hibernation behavior.

---
Suggested order of commits: commit current installer work FIRST, then land the
refactor (steps 1–4) as its own commit after a verified `reconfigure rebuild`.
