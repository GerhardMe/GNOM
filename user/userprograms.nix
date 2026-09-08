# Programs you want installed.
#   system : available to all users (added to configuration.nix)
#   user   : installed for your user only (added to home.nix)
# Add package names exactly as they appear on https://search.nixos.org

{ pkgs, ... }: with pkgs; {
  system = [

  ];

  user = [
    # Big programs:
    slack
    spotify
    kicad-small
    discord
    freecad
    qbittorrent
    proton-vpn
    krita
    gimp
    texstudio
    texliveFull
    inkscape
    prusa-slicer
    blender
    localsend
    obs-studio
    kdePackages.kdenlive

    # Terminal tools:
    glow

    # AI-cli
    claude-code
    opencode

    # Music
    ardour
    ladspaPlugins      # huge collection of basic effects
    lsp-plugins        # excellent quality, has pitch shifter, reverb, delay, EQ
    calf               # reverb, delay, chorus, lots of good stuff
    rubberband         # the rubber band pitch shifter
    mda_lv2            # another good collection
    zita-at1           # autotune style pitch correction
    rnnoise
    noise-repellent

    # Games:
    prismlauncher # open source minecraft launcher
    steam

    # Editors:
    vscode
    obsidian
    libreoffice

    # Fun:
    cmatrix
    pipes
    cava
    asciiquarium-transparent
    sl
  ];
}
