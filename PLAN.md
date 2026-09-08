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

## DONE (2026-09-08): boot menu / garbage collection fix
Root cause: the weekly `nix-gc` service (root, `--delete-older-than 30d`) deleted
system profile generations — including their kernels/initrds — without
regenerating grub.cfg, so GRUB entries pointing at collected store paths stayed
in the menu until the next rebuild ("broken boot entries"). Specialisations
(`rescue` + `eGPU`) triple entries per generation, which made the menu fill up
fast. Committed `9254037`:

- `reconfigure.sh`: new `cleanup()` runs **only after a successful switch**
  (`set -e` gates it): `nix-env --delete-generations +5` on system + user
  profiles (keep newest 5 regardless of age), plain `nix-collect-garbage`
  (failed builds / unreachable paths), prune dev-shell GC roots unused 200d.
- `configuration.nix`: `configurationLimit 10 → 5`; dropped `keep-outputs` /
  `keep-derivations`; weekly `nix-gc` kept as backstop but **GC-only** (plain
  `nix-collect-garbage`, never deletes generations).
- `dotfiles/fish/startup.fish`: `dev` now creates a persistent GC root via
  `nix build --no-link --out-link ~/.cache/gnoms/shells/<project>
  .#devShells.<system>.default` before `nix develop`, refreshed every run,
  silent fallback if the flake has no devShell. This is why `keep-outputs`
  could be dropped: dev shells are rooted properly (nix-direnv covers
  `.envrc` users too).

## 1. reconfigure.sh polish / eval pass (NEXT)
The script works but has known rough edges. Fix all of these, keep behavior
and the `[  ▶▶  ]` / `[  OK  ]` / `[  !!  ]` UX intact:

- **`copy`/`link` fake error handling**: on failure they log `[ !! ]` but
  return 0, so `set -e` never fires and the script continues in a broken
  state. Make them `return 1` on failure.
- **20 near-identical `copy` lines in `reload()`**: convert to a data table
  (list of `src:dest` pairs) + one loop, so adding a dotfile is one line.
- **`chmod +x "$EXE/"*`** chmods everything in `~/.local/bin` (including
  unrelated files) and errors if empty. chmod only what was linked.
- **`reload()` magic numbers**: `W=3840` and `STRIP_H=80` hardcoded — fade
  doesn't match actual screen resolution. Derive from the screen (xrandr or
  awesome-client) or at least hoist to named config at the top.
- **`save_visible_tags()`**: loops screens 1..5 hardcoded; double
  `sed | tr` parsing of `awesome-client` output is fragile. Check who
  consumes `/tmp/awesome-visible-tags` (rc.lua?) before changing the format.
- **`|| false` after the rebuild/update pipelines** is redundant under
  `set -e` + `pipefail`.
- **`error()`** prints both `ERROR:` and the `[ !! ]` prefix — redundant.
- **`hacky_fixes()`** (runs under "Applying hacky fixes…"): rename to
  something honest (e.g. `cleanup` is taken — consider `hygiene` or
  `pre_flight`), comment must say it purges stale nvim `.backup` files that
  otherwise make home-manager fail (it set `backupFileExtension = "backup"`).
  Must stay idempotent. NOTE: the name `cleanup` is now used by the
  post-rebuild maintenance function — don't collide.
- After the pass: re-run `bash -n`, then a real `rebuild` to verify.
- Update README if command surface changes (it shouldn't; `clean` was
  deliberately NOT added as a subcommand — cleanup is rebuild-gated to avoid
  reintroducing the GC/menu ordering bug).

## 2. Sync Firefox home-manager config with live Firefox (NEW)
`home.nix:179` (policies + ExtensionSettings + Preferences) has drifted from
reality: manual changes were made in Firefox itself and Firefox has updated
since the config was written. Task:

- Diff the deployed Nix config against live state:
  - `about:support` / `about:policies` for what's actually applied,
  - `~/.mozilla/firefox/<profile>/extensions.json` for installed extensions
    and their IDs (some install_urls above pin old versioned xpi files, e.g.
    Proton VPN 1.2.9, Unhook 1.6.7 — decide force_latest vs pinned),
  - `prefs.js` for manual `about:config` changes worth promoting into
    `Preferences` (with `Value`/`Status` wrappers as the existing entries do).
- Decide which manual changes should be codified vs reverted (config should
  win — that's the point of GNOMS).
- Check `languagePacks = [ "en-UK" "no" ]` — "en-UK" looks wrong; Firefox
  uses "en-GB".
- Rebuild + verify in `about:support` that policies match home.nix.

## 3. installer/install.sh is BROKEN until refactor
Still reads `personal/profile.conf` + sed-templating (both gone). Needs a full
rewrite: write/merge `user/userprofile.nix` instead of `set_key` into a conf,
copy (not template) nix files + `user/` into `/mnt/etc/nixos`.

## 4. Theme manager (epic, idea)
One shared palette source (e.g. `user/theme.*`) feeding awesome, wezterm, dunst,
rofi, fish... Currently only awesome's `bg_normal` doubles as the bar/fade
reference color.

## 5. README: true design philosophy
Reframe from "this is Gerhard's PC config" to:
**"a NixOS setup that is easy to customize even without Nix experience"** —
`/user/userprofile.nix` as the single no-Nix-knowledge-required entry point,
reconfigure as the one command, ISO installer for bare metal. README still says
`/personal`.

## 6. ISO installer (staged, untested end-to-end)
Committed: `installer/bootstrap.sh` (clones GNOMS@master, runs repo installer),
`installer/install.sh` (prompts, partitions, LUKS, swapfile + resume_offset,
generates hardware-configuration.nix), `installer/iso.nix`, flake `#iso` target.
Validated: flake evaluates. Remaining: finish `nix build ./nixos#iso`,
test-boot, README section (build / dd / boot / `sudo gnoms`) — after step 3.

## Repo quirks (context for evals)
- `nixos/hardware-configuration.nix` is untracked (machine-specific), so
  `nix eval ./nixos#...` from the repo fails ("does not exist in Git
  repository"). Evaluate from a plain copy (e.g. `/etc/nixos` or a temp dir
  with `user/` + a hardware-configuration.nix) instead. `reconfigure.sh`
  rebuilds from the synced `/etc/nixos`, which is unaffected.
