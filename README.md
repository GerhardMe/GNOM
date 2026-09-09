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

## What this is

GNOMS is a complete NixOS laptop setup, written to be read from top
to bottom and rebuilt as your own. It is a **platform, not a distro** — a
Framework laptop, not an iPhone. Take it apart and make it your own. Replace the dotfiles, keep the scripts, or the other way around. When you have
understood GNOMS you have understood NixOS.

## What you get for free

Setting these up is where most people fall off Nix. Here you get them preconfigured and working.

- **[NixOS](https://nixos.org/manual/nixos/stable/)** — the whole
  operating system is declared in `nixos/configuration.nix`: packages,
  services, users, boot. Change the file, run `reconfigure rebuild`, and
  the system becomes exactly that. Every previous version stays in the boot
  menu, so a bad change is one reboot away from undone. Find packages and
  options at [search.nixos.org](https://search.nixos.org).
- **[Flakes](https://wiki.nixos.org/wiki/Flakes)** — `nixos/flake.nix` pins
  the exact version of nixpkgs and home-manager the system is built from
  (`flake.lock`). Two machines with the same lock file build the same
  system; `reconfigure update` moves the pin forward when you decide to.
- **[home-manager](https://nix-community.github.io/home-manager/)** — the
  same idea for your user: `nixos/home.nix` declares your programs, git
  identity, GTK theme, Firefox policies and user services. It runs as a
  NixOS module here, so one `rebuild` does both system and home.

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

## Nice to have

Small things that make a laptop pleasant, each one a short script in
`scripts/` or a few lines in the nix files. Steal what you like.

- **Modes** — `mode server|normal|performance|status`. Server mode starts
  sshd and a sleep inhibitor so the lid can close; performance mode sets
  the CPU governor to performance and enables turbo. The awesome bar
  changes color so you always know which one you are in. (`scripts/mode.sh`,
  `mode-set.sh`, `performance.sh`)
- **Battery warning** — a monitor polls the battery and throws up a bare
  X11 popup at 4 % that no notification daemon can swallow.
  (`scripts/battery-monitor.sh`, `scripts/batNotify/`)
- **Hibernation done right** — lid close suspends, and after an hour on
  battery the machine wakes briefly and hibernates to a swapfile that
  lives _inside_ the encrypted root, so the memory image is encrypted at
  rest. On AC it stays in cheap suspend. (`configuration.nix`, POWER and
  BOOT sections)
- **Microcontrollers just work** — plug in a board and a notification
  tells you what it is and which command flashes it. `mcflash` handles
  `.bin`, `.uf2`, `.hex` and `.py` for ESP, Pico, Arduino, Nordic and
  J-Link targets; udev rules and all the tools are in place.
  (`scripts/microcontroller-*.sh`, `scripts/lib/`, SERVICES section)
- **Monitor hotplug** — plugging a screen in or out applies your saved
  `autorandr` layout and offers to open `arandr` if there is none.
  (`scripts/hardware-events.sh`)
- **Lock screen** — a blurred screenshot as the lock, after idle or before
  sleep, never while audio or fullscreen is playing. (`scripts/blurlock.sh`,
  `startup.sh`)
- **SSH indicator** — the bar turns orange while somebody is logged in
  over SSH. (`scripts/ssh-detect.sh`)
- **Dev shells that survive garbage collection** — the fish `dev` function
  enters a project's `nix develop` and pins a GC root under
  `~/.cache/gnoms/shells`, so your toolchain is not silently deleted next
  week. (`dotfiles/fish/startup.fish`)
- **Rescue boot entry** — a `rescue` specialisation in the GRUB menu boots
  the same system without X or autologin, for when the rice breaks.
- **Garbage collection that never breaks the boot menu** — weekly GC only
  removes unreachable paths; generations are pruned in `reconfigure` right
  after a successful rebuild, so GRUB never points at a deleted path.
- **Hardened Firefox** — tracking protection, no telemetry, uBlock and
  friends force-installed, all as declared policies in `home.nix`.
- **The rest** — Syncthing, PipeWire with Bluetooth codecs, Thunar with
  automount, a Brother printer driver, mDNS, an SSH server on a
  non-standard port with rate limiting.

## Machine specific: the ThinkPad T480

Some of this repo is about one particular laptop. It is left in on
purpose, because it shows how NixOS handles hardware: as a few clearly
marked blocks you replace, not as something you reinstall for. Here is
what is T480-specific and where it lives.

- **Thunderbolt eGPU** — an NVIDIA card in an external enclosure. It is a
  **specialisation** (`configuration.nix`, EGPU section): a second entry
  in the GRUB menu that builds the same system with the NVIDIA driver and
  PRIME configured, with the PCI bus IDs of this machine. Boot the normal
  entry and the card is simply absent. `egpu <program>` runs something on
  the card and warns if you booted without it. This is the pattern for
  _any_ hardware you only sometimes have: one config, two boot entries.
- **Rescue mode** — the other specialisation, described above. Same
  mechanism, different reason.
- **Mobile broadband** — the T480 has a WWAN slot, so ModemManager is on
  and pinned to start at boot, with a small GUI for it. Drop the block if
  you have no modem.
- **Fan control** — `thinkpad_acpi` is loaded with `fan_control=1` and a
  sudo rule lets the user write to `/proc/acpi/ibm/fan` without a
  password, so a script can drive the fan. Other laptops want a different
  knob.
- **nouveau blacklisted** — so the eGPU is left to the proprietary driver.
- **Swap sized for 24 GB of RAM** — the swapfile is 32 GB so a full memory
  image fits when hibernating, and `resume_offset` is where that file
  physically sits on _this_ disk. The installer computes the right number
  for your disk and offers to swap it.
- **Everything else machine-shaped** lives in
  `/etc/nixos/hardware-configuration.nix`, which NixOS generates per
  machine and which is deliberately not in this repo. Disks, LUKS device,
  CPU microcode, kernel modules: yours, not mine.

## Installation

### Fresh install:

Download the ISO from
[gerhard.page/projects/proj/gnoms](https://gerhard.page/projects/proj/gnoms)
and flash it to a USB stick. In the BIOS, enable USB boot and turn off
Secure Boot, then boot from the stick. You are handed straight to the
installer. Supports a whole disk or dual boot next to an existing OS.

For more details, read: [installer/README.md](installer/README.md).

### On a NixOS system:

```bash
git clone https://github.com/GerhardMe/GNOMS ~/GNOMS
cd ~/GNOMS/nixos
./reconfigure.sh rebuild
```

It's that simple! Your machine keeps its own
`/etc/nixos/hardware-configuration.nix`; GNOMS only ever copies the flake
next to it. Then edit `user/`, and point `~/GNOMS` at a repo of your own.

(Want to read more? [Click me!](https://gerhard.page/projects/proj/gnoms))
