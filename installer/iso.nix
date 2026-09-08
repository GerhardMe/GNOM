# iso.nix — GNOMS bootable installer ISO.
#
# A minimal NixOS CLI live environment with NetworkManager. It contains
# almost nothing: the `gnoms` command clones the latest GNOMS from master
# and runs the repo's own installer, so the ISO never goes stale.
#
# Build:   nix build ./nixos#iso        (from the repo root)
# Result:  result/iso/*.iso
{
  pkgs,
  lib,
  modulesPath,
  ...
}: let
  gnoms = pkgs.writeShellScriptBin "gnoms" (builtins.readFile ./bootstrap.sh);
in {
  imports = [(modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")];

  # NetworkManager (with nmtui) + ModemManager instead of the ISO's default
  # wpa_supplicant. Wired ethernet works out of the box.
  networking.networkmanager.enable = true;
  networking.wireless.enable = lib.mkForce false;
  networking.modemmanager.enable = true;

  # Auto-login as nixos — the installer (gnoms) starts by itself on tty1.
  services.getty.autologinUser = "nixos";
  environment.loginShellInit = ''
    if [ "$(tty)" = "/dev/tty1" ] && [ -z "''${GNOMS_AUTORUN:-}" ]; then
      export GNOMS_AUTORUN=1
      gnoms
    fi
  '';

  isoImage.volumeID = "GNOMS-INSTALL";

  # ISO default keymap; the gnoms script's first prompt offers a change
  # for the session (Enter keeps this).
  console.keyMap = "no";

  environment.systemPackages = with pkgs; [
    gnoms # the installer entry point
    git
    curl
    neovim
  ];

  # Greet the user on the other TTYs
  environment.etc."issue".text = ''

    ┌────────────────────────────────────────────────────────────┐
    │                                                            │
    │             GNOMS  —  INSTALLER  USB                       │
    │                                                            │
    │   tty1: auto-logged in, the installer starts by itself.    │
    │                                                            │
    │   No network yet?  Exit the installer (Ctrl-C), run        │
    │   'nmtui' to connect, then run 'gnoms' again.              │
    │                                                            │
    └────────────────────────────────────────────────────────────┘

  '';
}
