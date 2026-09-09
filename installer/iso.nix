# iso.nix — GNOMS bootable installer ISO.
#
# A minimal NixOS CLI live environment with NetworkManager. It contains
# almost nothing: the `gnoms` command clones GNOMS and runs the repo's own
# installer, so the ISO never goes stale.
#
# Build:   installer/build-iso.sh       (from anywhere in the repo)
#          → runs `nix build --impure ./nixos#iso` with GNOMS_REPO_URL set
#            to this checkout's `git remote get-url origin`, so a fork's ISO
#            defaults to that fork. A plain `nix build ./nixos#iso` (pure,
#            no git remote known) also works — bootstrap.sh then falls back
#            to its DEFAULT_REPO_URL, and the prompt lets you change it.
# Result:  result/iso/*.iso
{
  pkgs,
  lib,
  modulesPath,
  ...
}: let
  # Baked in at build time by build-iso.sh (needs --impure; "" in pure eval).
  repoUrl = builtins.getEnv "GNOMS_REPO_URL";
  repoBranch = builtins.getEnv "GNOMS_REPO_BRANCH";
  # ui.sh (colors, prompts, logo banner) + bootstrap.sh, inlined in order.
  gnoms = pkgs.writeShellScriptBin "gnoms" ''
    export GNOMS_REPO_URL=${lib.escapeShellArg repoUrl}
    export GNOMS_REPO_BRANCH=${lib.escapeShellArg repoBranch}
    ${builtins.readFile ./ui.sh}
    ${builtins.readFile ./bootstrap.sh}
  '';
  repoLine =
    if repoUrl == ""
    then "   Repo: bootstrap.sh default (the installer asks anyway)."
    else "   Repo: ${repoUrl}";
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

  # The logo, referenced from the repo (ui.sh's banner reads it here on the
  # ISO, and from <repo>/user/logo.txt once the repo is cloned).
  environment.etc."gnoms/logo.txt".source = ../user/logo.txt;

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
    ${repoLine}

  '';
}
