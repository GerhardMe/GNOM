# GNOMS — Roadmap / Pick-up-later plan

_Last updated: 2026-09-08._

## DONE (2026-09-08): profile refactor
`personal/profile.conf` templating is gone. Now: `user/userprofile.nix` (pure data,
incl. `keyboard_layout`) + `user/userprograms.nix` (`{ pkgs }: with pkgs;` with
`system`/`user` lists). `flake.nix` keys `nixosConfigurations` by
`profile.hostname`; `configuration.nix`/`home.nix` reference `profile.*` via a
`pathExists ./user or ../user` shim (works both in the repo and a synced
`/etc/nixos`). `reconfigure.sh` lost `parse_config`/`apply_template`; rebuild
plain-copies files + `user/` into `/etc/nixos`, hostname via grep.
Lua owns its bar color (`theme.lua` hardcoded; reconfigure/mode-set grep
`bg_normal` from it).

## 1. Clean up `hacky_fixes` in reconfigure.sh (NEXT)
Either delete it or rename to something honest (e.g. `cleanup`), with a comment
explaining the one remaining nvim `.backup` purge. Keep it idempotent.

## 2. installer/install.sh is BROKEN until refactor
Still reads `personal/profile.conf` + sed-templating (both gone). Needs a full
rewrite: write/merge `user/userprofile.nix` instead of `set_key` into a conf,
copy (not template) nix files + `user/` into `/mnt/etc/nixos`.

## 3. Theme manager (epic, idea)
One shared palette source (e.g. `user/theme.*`) feeding awesome, wezterm, dunst,
rofi, fish... Currently only awesome's `bg_normal` doubles as the bar/fade
reference color.

## 4. README: true design philosophy
Reframe from "this is Gerhard's PC config" to:
**"a NixOS setup that is easy to customize even without Nix experience"** —
`/user/userprofile.nix` as the single no-Nix-knowledge-required entry point,
reconfigure as the one command, ISO installer for bare metal. README still says
`/personal`.

## 5. ISO installer (staged, untested end-to-end)
Committed: `installer/bootstrap.sh` (clones GNOMS@master, runs repo installer),
`installer/install.sh` (prompts, partitions, LUKS, swapfile + resume_offset,
generates hardware-configuration.nix), `installer/iso.nix`, flake `#iso` target.
Validated: flake evaluates. Remaining: finish `nix build ./nixos#iso`,
test-boot, README section (build / dd / boot / `sudo gnoms`) — after step 2.
