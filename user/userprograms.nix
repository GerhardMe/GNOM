# Programs you want installed.
#   system : available to all users (added to configuration.nix)
#   user   : installed for your user only (added to home.nix)
# Add package names exactly as they appear on https://search.nixos.org
#
# NOTE: Some programs are NOT listed here — they are installed and configured
# through module options ("programs.<name> = { ... }"), which handle both the
# install and the settings in one place:
#   firefox : browser — configured in nixos/home.nix (policies, extensions, search)
#   neovim  : editor  — enabled in nixos/home.nix (default editor + vi/vim aliases)
#   git     : version control — configured in nixos/home.nix (user name/email)
#   fish    : user shell — enabled in nixos/configuration.nix
#   thunar  : file manager — enabled in nixos/configuration.nix (with plugins)
#   i3lock  : screen locker — enabled in nixos/configuration.nix
#   direnv  : per-project envs — enabled in nixos/configuration.nix (nix-direnv)
#   gnupg   : encryption/keys — agent enabled in nixos/configuration.nix

{ pkgs, ... }: with pkgs; {
  system = [

  ];

  user = [
    # Big programs:
    slack             # team chat
    spotify           # music streaming
    kicad-small       # PCB design
    discord           # voice/chat
    freecad           # 3D CAD
    qbittorrent       # torrent client
    proton-vpn        # VPN client
    krita             # digital painting
    gimp              # image editing
    texstudio         # LaTeX editor
    texliveFull       # full LaTeX distribution
    inkscape          # vector graphics
    prusa-slicer      # 3D print slicer
    blender           # 3D modeling
    localsend         # AirDrop-style file sharing
    obs-studio        # screen recording/streaming
    kdePackages.kdenlive # video editor

    # Terminal tools:
    glow              # markdown reader in terminal

    # AI-cli
    claude-code       # AI coding agent
    opencode          # AI coding agent

    # Music
    ardour            # DAW (multitrack recording)
    ladspaPlugins      # huge collection of basic effects
    lsp-plugins        # excellent quality, has pitch shifter, reverb, delay, EQ
    calf               # reverb, delay, chorus, lots of good stuff
    rubberband         # the rubber band pitch shifter
    mda_lv2            # another good collection
    zita-at1           # autotune style pitch correction
    rnnoise           # noise suppression plugin
    noise-repellent   # noise reduction plugin

    # Games:
    prismlauncher # open source minecraft launcher
    steam             # game store/launcher

    # Editors:
    vscode            # code editor
    obsidian          # note taking
    libreoffice       # office suite

    # Fun:
    cmatrix           # matrix rain
    pipes             # ASCII pipes screensaver
    cava              # audio visualizer
    asciiquarium-transparent # aquarium screensaver
    sl                # steam locomotive (typo'd ls)
  ];
}
