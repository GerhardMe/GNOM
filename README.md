# Gerhard's NixOS Management System (GNOMS)

    [~]❯ neofetch
                       ▐▌                     gg@gnoms
                       ██                     ------
                      ▟██▙                    OS: NixOS
                     ▟████▙                   Host: ThinkPad T480
                   ▄███▀▀███▄                 Kernel: Linux 6.12.43
                 ▄████▚███████▄               Uptime: yes
               ▄██████▞█▄▗██████▄             Packages: 5699 (nix-system), 5071 (nix-user)
           ▄▄██████████▄▄██████████▄▄         Shell: fish 4.0.2
    ▄▄▄▄████████████████████████████████▄▄▄▄  Display: > 180p
               ▜▐▐            ▌▌▛             DE: none+awesome
               ▐▐   ▞▚    ▞▚   ▌▌             WM: awesome (X11)
               ▐                ▌             Icons: Papirus-Dark [GTK]
                 ▜▄ ▄▆▀▆▆▀▆▄ ▄▛               Terminal: WezTerm
                  ▜████▄▄████▛                CPU: Intel i7-8550U @ 4.000GHz
                   ▜████████▛                 GPU: Intel UHD Graphics
                    ▜██████▛                  eGPU: NVIDIA GeForce RTX 2080
                     ▜████▛                   Memory: can't afford
                      ▜██▛
                       ▜▛                     . ݁₊ ⊹ . ݁ ⟡ ݁ . ⊹ ₊ ݁.

A flake-based NixOS manager for dotfiles, scripts, configurations and more!

## Philosophy

GNOMS is not a distro. It is not LARBS, not Omarchy, not one more
"my rice as a product" install script. Those give you a finished thing and
ask you not to look inside.

GNOMS is a **platform** — think Framework laptop, not iPhone. It is a
complete, working NixOS setup whose whole point is to be taken apart,
understood and rebuilt as yours:

- **A soft intro to Nix.** Everything is plain NixOS and home-manager,
  written to be read. One `configuration.nix`, one `home.nix`, one flake, a
  folder of dotfiles, a folder of scripts. No custom module system, no DSL,
  no generator hiding what actually gets built. When you outgrow it, you
  outgrow it into NixOS, not away from it.
- **Small enough to hold in your head.** Every file has one job and the
  root of the repo tells you where that job lives. If something is not
  obvious from the file it sits in, that is a bug.
- **Yours from the first minute.** `user/` is the part you own; the
  installer writes your answers into it and points the clone at your own
  fork. Fork first, install second. GNOMS is meant to be spun, not used
  as-is.
- **Nothing hidden behind convenience.** The installer prints what it is
  about to do, the reconfigure script is four commands you can read in one
  sitting, and the machine-specific bits stay in `/etc/nixos` where NixOS
  puts them.

If you want a desktop that just appears, use one of the projects above.
If you want to understand the desktop that appears, start here.

## Architecture

A system of 5 parts:

- **/dotfiles :** Everything rice and window manager specific.

- **/nixos :** Everything NixOS specific, and the main reconfigure script.

- **/user :** The stuff you want to change first — profile, programs, logo, wallpaper.

- **/scripts :** Any custom scripts for the system.

- **/installer :** The bootable USB stick and the installer it runs. Has its own [README](installer/README.md).

## Main script: `reconfigure.sh`

One script to rule them all:

- `reload` : Syncs config files (dotfiles, scripts), restarts AwesomeWM if possible.

- `rebuild` : Copies the Nix flake to `/etc/nixos`, runs `nixos-rebuild switch`, then reloads.

- `update` : Runs `nix flake update` to update all packages to the latest version.

- `upgrade` : Combines `update` and `rebuild`.

## Installation

Step zero, either way: **fork this repo.** The installer and the reconfigure
script both work on `~/GNOMS`, and that should be your copy from the start.

### From the USB stick (blank machine or dual boot)

Build the installer ISO from your checkout and write it to a stick:

```bash
installer/build-iso.sh
sudo dd if=installer/result/iso/*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

The stick bakes in the URL of the checkout that built it, so it installs
*your* fork. Boot it in UEFI mode; the installer starts by itself. It will:

1. ask for keyboard layout and the repo to install (Enter keeps the default),
2. set up the disk — whole drive, or free space next to an existing OS —
   always LUKS2-encrypted, with a swapfile sized for hibernation,
3. ask everything else up front: user, hostname, password, the values in
   `user/userprofile.nix`, whether to install the program list, your fork,
4. then run unattended: bare NixOS first (a safety net that boots on its
   own), the repo copied to `~/GNOMS` with your answers written in, and
   GNOMS built on top. No reboot in between.

Dual boot never touches the other OS's boot order: GNOMS gets its own entry
in the firmware boot menu. Wi-Fi on the stick: Ctrl-C, `nmtui`, `gnoms`.

Details, every file and every decision: [installer/README.md](installer/README.md).

### On a NixOS system you already have

```bash
git clone <your fork> ~/GNOMS
cd ~/GNOMS/nixos
./reconfigure.sh rebuild
```

It's that simple! Your machine keeps its own
`/etc/nixos/hardware-configuration.nix`; GNOMS only ever copies the flake
next to it.

(Want to read more? [Click me!](https://gerhard.page/projects/proj/gnoms))
