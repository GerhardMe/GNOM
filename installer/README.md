# installer/

The USB stick and the installer it runs. Not yet tested end to end.

## Files

| File | Role |
|------|------|
| `iso.nix` | The stick: minimal NixOS, NetworkManager + ModemManager, git, curl, neovim. Auto-logs in and runs `gnoms`. |
| `bootstrap.sh` | The `gnoms` command baked into the stick. Keyboard layout, repo URL, clone into RAM, hand over to `install.sh`. |
| `install.sh` | The installer. Runs from the clone, so the stick never goes stale. |
| `ui.sh` | Colors, prompts, logo banner, section headings. Shared by the scripts. |
| `build-iso.sh` | Builds the ISO with this checkout's git remote baked in. Output in `result/`, gitignored. |

## How it works

**Bootstrap.** The stick asks for a keyboard layout and shows the repo URL
it is about to clone (Enter keeps it, or type another). It clones the repo
into RAM and runs `install.sh` from there.

**Disk.** Whole disk, free space next to an existing OS, or one chosen
partition. Always GPT, an ESP at `/boot`, and a LUKS2 root with ext4. A
swapfile on the encrypted root, sized to what `configuration.nix` declares.
The stick itself is never a target. `GNOMS_STOP_AFTER_PARTITION=1` stops
here for a look.

**Questions.** All of them up front, then you can walk away:

- username, hostname, password;
- the hibernation offset, only if the repo's `resume_offset` differs from
  where this machine's swapfile landed;
- every key of `user/userprofile.nix`, with the repo's value as default
  (or "use this exact setup" to skip). Keys are read from the file, so a
  fork's custom keys are asked too;
- the program list in `user/userprograms.nix`: all of it, or none.

**Unattended.**

1. `nixos-generate-config` writes the target's `hardware-configuration.nix`.
   The only per-machine file. Never in the repo.
2. A small baseline `configuration.nix` and the first `nixos-install`. Bare
   NixOS that boots on its own; the safety net if the next step fails.
3. Dual boot only: GRUB is installed with `--no-nvram` and registered as
   its own firmware entry, so the other OS's boot order is untouched.
4. The repo is copied to `~/GNOMS` **without `.git`**, and your answers are
   written into `user/` (values replaced in place, comments kept).
5. The flake is copied to `/etc/nixos` and a second
   `nixos-install --flake` builds GNOMS. No reboot in between; the baseline
   stays selectable in GRUB.
6. Handoff: how to treat the system, the commands to `git init` `~/GNOMS`
   and push it to a repo of your own, then reboot.

If the GNOMS build fails, bare NixOS still boots. Fix, then
`cd ~/GNOMS/nixos && ./reconfigure.sh rebuild`.

## Your own stick

```bash
installer/build-iso.sh
```

The ISO defaults to the checkout's `origin`, rewritten to HTTPS. Without a
git remote it falls back to `DEFAULT_REPO_URL` at the top of
`bootstrap.sh`, and the prompt on the stick always lets you type another.

The installer also runs without the stick, from any booted NixOS as root:
`bash installer/install.sh <checkout>`. UEFI only.

## Customizing

- **Profile questions:** add a key to `user/userprofile.nix`. Strings,
  booleans and integers are asked. A hint text lives in `profile_hint`.
- **Program list:** edit `user/userprograms.nix`.
- **Baseline system:** `write_baseline_config` in `install.sh`. Keep the
  GRUB block in step with `nixos/configuration.nix`.
- **What the stick carries:** `iso.nix`. Keep it minimal; everything else
  arrives with the clone.
- **The look:** `ui.sh`. The logo is `user/logo.txt`, referenced, never
  copied.

## On purpose

- `hardware-configuration.nix` never enters the repo.
- `resume_offset` stays a literal in `configuration.nix`; the installer
  only offers to swap that one number in the copy on the new machine.
- The copy on the target has no git history. An install is never bound to
  the repo it came from.
- Dual boot is a contained instance under `/EFI/GNOMS`. `/boot` is the
  unencrypted ESP, so GRUB never reads the LUKS container.
- Two `nixos-install` passes, no first-boot service. A failure leaves a
  clean bare NixOS, not a half-configured machine.
