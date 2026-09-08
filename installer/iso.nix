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

  # NetworkManager (with nmtui) instead of the ISO's default wpa_supplicant
  networking.networkmanager.enable = true;
  networking.wireless.enable = lib.mkForce false;

  isoImage.volumeID = "GNOMS-INSTALL";

  # Same keyboard as the target system
  console.keyMap = "no";

  environment.systemPackages = with pkgs; [
    gnoms # the installer entry point
    git
    curl
    neovim
  ];

  # Greet the user at the login prompt
  environment.etc."issue".text = ''

    ┌─────────────────────────────────────────────────────┐
    │                                                     │
    │            GNOMS  —  INSTALLER  USB                 │
    │                                                     │
    │   1. Connect to Wi-Fi:                  nmtui       │
    │   2. Install (fetches latest GNOMS):    sudo gnoms  │
    │                                                     │
    └─────────────────────────────────────────────────────┘

  '';
}
