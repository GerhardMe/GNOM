{ pkgs, config, ... }:

let
  # user/ holds your profile: ./user when running from a synced copy in
  # /etc/nixos, ../user when evaluating inside the repo.
  profile = import (if builtins.pathExists ./user
    then ./user/userprofile.nix
    else ../user/userprofile.nix);
  userprograms = import (if builtins.pathExists ./user
    then ./user/userprograms.nix
    else ../user/userprograms.nix) { inherit pkgs; };

  rootTriggerScript = pkgs.writeScript "log-hw-event" ''
    #!${pkgs.runtimeShell}
    touch "/tmp/hw-trigger-$(date +%s)-$1"
  '';
in {

  # ------------------------------------------------------------------------------------------
  # ----------------------------------------- CONFIG -----------------------------------------
  # ------------------------------------------------------------------------------------------

  imports = [ ./hardware-configuration.nix ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  programs.command-not-found.enable = false;
  networking.hostName = profile.hostname;

  # ENV varriables
  environment.variables = {
    TERMINAL = "wezterm";
    EDITOR = "nvim";
    BROWSER = "firefox";
  };
  systemd.user.settings.Manager = {
    ImportEnvironment = "DISPLAY XAUTHORITY";
  };
  xdg.mime = {
    enable = true;
    defaultApplications = {
      # file manager
      "inode/directory" = "Thunar.desktop";
      # HTML files
      "text/html" = "firefox.desktop";
      # URL handlers
      "x-scheme-handler/http" = "firefox.desktop";
      "x-scheme-handler/https" = "firefox.desktop";
    };
  };

  # ------------------------------------------------------------------------------------------
  # ----------------------------------------- BOOT -------------------------------------------
  # ------------------------------------------------------------------------------------------

  boot.loader.systemd-boot.enable = false;
  boot.loader = {
    efi.canTouchEfiVariables = true;
    grub = {
      enable = true;
      efiSupport = true;
      enableCryptodisk = true;
      device = "nodev";
      configurationLimit = 10;
      useOSProber = true; # pick up Windows/other installs for dual-boot
    };
    timeout = 1;
  };
  boot.blacklistedKernelModules =
    [ "nouveau" "nvidiafb" ]; # to get eGPU to work
  boot.extraModprobeConfig = ''
    options nvidia-drm modeset=1
    options thinkpad_acpi fan_control=1
  '';
  # Swap is >= RAM (24 GB) so a full memory image fits when hibernating.
  swapDevices = [{
    device = "/var/lib/swapfile";
    size = 32 * 1024;
  }];

  # --- Hibernate / resume ---
  # The swapfile lives on the LUKS-encrypted ext4 root, so any hibernation
  # image is encrypted at rest. initrd already unlocks that device for root;
  # resumeDevice points the kernel at it, and resume_offset says where in it
  # the swapfile starts.
  #
  # resume_offset MUST be regenerated whenever the swapfile is (re)created,
  # e.g. after changing `size` above. The installer computes it automatically;
  # to update it later, set it in user/userprofile.nix and rebuild:
  #   sudo filefrag -v /var/lib/swapfile | awk 'NR==4 {print $4+0}'
  boot.resumeDevice = config.fileSystems."/".device;
  boot.kernelParams = [ "resume_offset=${toString profile.resume_offset}" ];

  # ------------------------------------------------------------------------------------------
  # ----------------------------------------- POWER ----------------------------------------
  # ------------------------------------------------------------------------------------------

  # Lid close / power key: suspend to RAM now (instant resume), then after
  # HibernateDelaySec of sleeping, wake briefly and hibernate to disk so a
  # forgotten laptop ends up at zero battery draw instead of dying flat.
  # Inhibitors still win, so "server mode" (awake.service) keeps it awake.
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend-then-hibernate";
    HandleLidSwitchExternalPower = "suspend";
    HandlePowerKey = "suspend-then-hibernate";
  };
  systemd.sleep.settings.Sleep = {
    HibernateDelaySec = "1h";
    HibernateOnACPower = "no"; # on AC (eGPU dock) stay in cheap S3; only hibernate on battery
  };

  # Keep the 32 GB swap mostly empty so a hibernation image always fits, and
  # spare the SSD writes. 24 GB RAM means real swap pressure is rare anyway.
  boot.kernel.sysctl."vm.swappiness" = 10;

  # ------------------------------------------------------------------------------------------
  # ----------------------------------------- USER -----------------------------------------
  # ------------------------------------------------------------------------------------------

  users.users.${profile.username} = {
    isNormalUser = true;
    extraGroups = [ "networkmanager" "wheel" "dialout" "audio" "jackaudio" ];
    shell = pkgs.fish;
    subUidRanges = [{ startUid=100000; count=65536;}];
    subGidRanges = [{ startGid=100000; count=65536;}];
  };
  programs.fish.enable = true;

  # Language and locale
  time.timeZone = profile.timezone;
  i18n.defaultLocale = profile.locale;
  i18n.extraLocaleSettings = {
    LC_ADDRESS = profile.locale;
    LC_IDENTIFICATION = profile.locale;
    LC_MEASUREMENT = profile.locale;
    LC_MONETARY = profile.locale;
    LC_NAME = profile.locale;
    LC_NUMERIC = profile.locale;
    LC_PAPER = profile.locale;
    LC_TELEPHONE = profile.locale;
    LC_TIME = profile.locale;
  };

  # ------------------------------------------------------------------------------------------
  # --------------------------------------- PERIFERALS ---------------------------------------
  # ------------------------------------------------------------------------------------------

  # Inverse tutchpad scolling
  services.libinput = {
    enable = true;
    touchpad.naturalScrolling = true;
  };

  # Keyboard layout
  console.keyMap = profile.keyboard_layout;
  services.xserver.xkb = {
    layout = profile.keyboard_layout;
    options = "lv3:ralt_switch";
  };

  # ------------------------------------------------------------------------------------------
  # ------------------------------------ DISPLAY MANAGER -------------------------------------
  # ------------------------------------------------------------------------------------------

  services = {
    xserver = {
      enable = true;
      windowManager.awesome = {
        enable = true;
        luaModules = with pkgs.luaPackages; [
          luarocks # is the package manager for Lua modules
          luadbi-mysql # Database abstraction layer
        ];
      };
    };

    displayManager = {
      sddm.enable = true;
      defaultSession = "none+awesome";
      autoLogin.enable = true;
      autoLogin.user = profile.username;
    };
  };
  programs.i3lock.enable = true;

  # ------------------------------------------------------------------------------------------
  # ------------------------------------------ SOUND -----------------------------------------
  # ------------------------------------------------------------------------------------------

  # Sound
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };

  # Bluetooth
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
  environment.etc = {
    "wireplumber/bluetooth.lua.d/51-bluez-config.lua".text =
      "	bluez_monitor.properties = {\n		[\"bluez5.enable-sbc-xq\"] = true,\n		[\"bluez5.enable-msbc\"] = true,\n		[\"bluez5.enable-hw-volume\"] = true,\n		[\"bluez5.headset-roles\"] = \"[ hsp_hs hsp_ag hfp_hf hfp_ag ]\"\n	}\n";
  };

  # ------------------------------------------------------------------------------------------
  # ---------------------------------------- NETWORK -----------------------------------------
  # ------------------------------------------------------------------------------------------

  # Networking protocols
  networking.networkmanager.enable = true; # Enable networking
  services.openssh = {
    enable = true;
    ports = [ 34826 ];
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PubkeyAuthentication = true;
      AuthenticationMethods = "publickey";

      MaxAuthTries = 3;
      LoginGraceTime = "30s";
      MaxStartups = "10:30:100";
    };
  };
  services.printing = {
    enable = true;
    drivers = [ pkgs.brlaser ];
  };
  services.avahi = {
  enable = true;
  nssmdns4 = true;
};
  networking.modemmanager.enable = true;
  systemd.services.ModemManager = {
    enable = pkgs.lib.mkForce true;
    wantedBy = [ "multi-user.target" "network.target" ];
    restartIfChanged = false;
    serviceConfig.TimeoutStopSec = 3;
  };
  networking.firewall = {
    enable = true;
    # Syncthing:
    allowedTCPPorts = [
      # 8384
      22000
      53317 # localsend
      4321
    ]; # 22000 TCP and/or UDP for sync traffic & 8384 for remote access to GUI
    allowedUDPPorts = [ 22000 21027 53317]; # 21027/UDP for discovery
    # SSH:
    extraInputRules = ''
      tcp dport 34826 ct state new limit rate 30/minute accept
    '';
  };

  # ------------------------------------------------------------------------------------------
  # ----------------------------------------- SECURITY ---------------------------------------
  # ------------------------------------------------------------------------------------------

  security.polkit.enable = true; # managing user premitions
  security.sudo.extraRules = [{
    users = [ profile.username ];
    commands = [
      {
        command = "${pkgs.systemd}/bin/systemctl start sshd";
        options = [ "NOPASSWD" ]; # Not shure if nessesary
      }
      {
        command = "${pkgs.systemd}/bin/systemctl stop sshd";
        options = [ "NOPASSWD" ]; # Not shure if nessesary
      }
      {
        command = "${pkgs.coreutils}/bin/tee /proc/acpi/ibm/fan";
        options = [ "NOPASSWD" ];
      }
    ];
  }];
  programs.dconf.enable = true; # somthing, something, keys...
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };

  # ------------------------------------------------------------------------------------------
  # ----------------------------------------- GRAPHICS ---------------------------------------
  # ------------------------------------------------------------------------------------------

  hardware.graphics.enable32Bit = true; # Steam support
  services.picom = {
    enable = true;
    settings = {
      vsync = true;
      backend = "glx";
      blur-method = "dual_kawase";
      blur-strength = 3;
      blur-background = true;
      blur-background-frame = false;
      blur-background-exclude = [ "_NET_WM_WINDOW_TYPE@:32a *= '_NET_WM_WINDOW_TYPE_DOCK'" ];
    };
  };
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "modesetting" ];

  # ------------------------------------------------------------------------------------------
  # ---------------------------------------- EGPU --------------------------------------------
  # ------------------------------------------------------------------------------------------

  specialisation = {
    rescue.configuration = {
      system.nixos.label = "rescue";

      services.xserver.enable = pkgs.lib.mkForce false;
      services.displayManager.sddm.enable = pkgs.lib.mkForce false;
      services.displayManager.autoLogin.enable = pkgs.lib.mkForce false;
      services.picom.enable = pkgs.lib.mkForce false;

      environment.etc."issue".text = ''

        ┌─────────────────────────────────────────────────────┐
        │                                                     │
        │          GNOMS  —  EMERGENCY  RESCUE  MODE          │
        │                                                     │
        │   No graphical session. Auto-login disabled.        │
        │   Home-manager user services will not start.        │
        │   Log in to access the shell environment.           │
        │                                                     │
        └─────────────────────────────────────────────────────┘

      '';
    };

    eGPU.configuration = {
      system.nixos.label = "nix-NVIDIA";
      services.xserver.videoDrivers = [ "nvidia" "modesetting" ];
      hardware.nvidia = {
        modesetting.enable = true;
        open = false;
        nvidiaSettings = true;
        powerManagement.enable = true;
        powerManagement.finegrained = false;
        package = config.boot.kernelPackages.nvidiaPackages.stable;
        prime = {
          sync.enable = true; # shuld be false ???
          offload.enable = false; # shuld be true ???
          allowExternalGpu = true;
          # Make sure to use the correct Bus ID values for your system!
          intelBusId = "PCI:0:2:0";
          nvidiaBusId = "PCI:12:0:0";
        };
      };
    };
  };

  # ------------------------------------------------------------------------------------------
  # ---------------------------------------- NIX SPESIFIC ------------------------------------
  # ------------------------------------------------------------------------------------------

  # Fix to get bin/bash to work, not strictly nessesary.
  system.activationScripts.binbash = {
  text = ''
    mkdir -p /bin
    ln -sf ${pkgs.bash}/bin/bash /bin/bash
  '';
};

  # Nix garbage collection (weekly, keep only last 30 days)
  nix = {
    settings = {
      auto-optimise-store = true;
      keep-outputs = true;      # keep build outputs of installed packages
      keep-derivations = true;  # keep .drv files so builds can be reproduced
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
      # persistent = true; # (default is true; ensures missed runs happen later)
    };
  };

  # nix-direnv: creates GC roots for dev environments so they survive garbage
  # collection — without this, `nix develop` packages have no GC root and get
  # collected even though the flake hasn't changed
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };


  system.stateVersion = "24.11"; # apparantly important. ¯\_(ツ)_/¯
  home-manager.backupFileExtension = "backup";

  # ------------------------------------------------------------------------------------------
  # ----------------------------------------- SERVICES ---------------------------------------
  # ------------------------------------------------------------------------------------------

  # Monitor and usb connection watch:
  services.udev.packages = with pkgs; [
    segger-jlink-headless # installs 99-jlink.rules
    (pkgs.nrfutil.withExtensions [ "nrfutil-device" ]) # installs 71-nrf.rules
  ];
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="tty", TAG+="systemd", ENV{SYSTEMD_WANTS}="log-usb-event.service"
    ACTION=="change", SUBSYSTEM=="drm", TAG+="systemd", ENV{SYSTEMD_WANTS}="log-monitor-event.service"
    ACTION=="change", KERNEL=="lid*", SUBSYSTEM=="power_supply", ENV{POWER_SUPPLY_ONLINE}=="0", \
      TAG+="systemd", ENV{SYSTEMD_USER_WANTS}="log-on-lid.service"
  '';
  systemd.services.log-usb-event = {
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${rootTriggerScript} usb";
    };
  };
  systemd.services.log-monitor-event = {
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${rootTriggerScript} monitor";
    };
  };
  systemd.services.log-on-lid = {
    description = "Delay suspend to allow screen lock";
    before = [ "sleep.target" ];
    wantedBy = [ "sleep.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart =
        "${pkgs.bash}/bin/bash -c '${rootTriggerScript} sleep; sleep 3'";
    };
  };
  systemd.tmpfiles.rules = [ "r /tmp/awesome-has-started - - - - -" ];

  # ------------------------------------------------------------------------------------------
  # ----------------------------------------- PROGRAMS ---------------------------------------
  # ------------------------------------------------------------------------------------------

  # SYSTEM WIDE PROGRAMS
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.segger-jlink.acceptLicense = true;
  environment.systemPackages = with pkgs; [
    config.boot.kernelPackages.nvidia_x11

    # Terminal:
    wezterm

    # Editors:
    vim

    # Backupp browser:
    chromium

    # Multi monitor support:
    arandr
    autorandr

    # Microcontrollers:
    mpremote # (MicroPython REPL + file push)
    esptool # (ESP flashing)
    picocom # (serial monitor)
    avrdude # (Arduino flashing)
    picotool # (Pico UF2 loading)
    (pkgs.nrfutil.withExtensions [ "nrfutil-device" ]) # Nordic nRF flashing; device extension bundled to avoid NixOS FHS issues
    segger-jlink-headless # J-Link drivers/tools without Qt GUI
    arduino-cli # compiler for arduino
    probe-rs-tools # RTT monitor + debug probe for Nordic/ARM bare-metal

    # Coding resources:
    python3
    gcc
    poetry

    # Code formatters
    nixfmt # Nix formatter
    stylua
    black
    shfmt
    prettier
    jq

    # Small programs:
    rofi # Application launcer
    dunst # notification daemon
    flameshot # screenshot app
    pavucontrol # Audio controll
    polkit_gnome # GUI for user auth
    networkmanagerapplet # nm-applet nm-connection-editor
    brightnessctl # Backlight brightness support
    qalculate-gtk # Calculator
    udiskie # USB automout applet
    baobab # disk analyser tool
    speedtest-cli # network speed test
    nethogs # program network usage
    bluetuith # Bluetooth TUI
    modem-manager-gui # 4G GUI

    # Cmd tools:
    zip # zip files
    unzip # unzip files
    gnupg # OpenPGP, encrypt/decrypt & sign data
    curl # transfer data over URLs (HTTP, FTP, etc.)
    file # detect a file’s type/format
    xclip # clipboard manager
    htop # program control pannel
    libnotify # notifyer backend
    xev # show keycodes
    xmodmap # list keycodes
    imagemagick # Blur images
    xdotool # for scripts flashing to microcontollers
    wget # download files from web
    usbutils # list USB devices
    lsof # list open files/processes
    pciutils # list PCI devices
    inotify-tools # filesystem change watcher
    coreutils # GNU base tools (ls, cp, etc.)
    maim # screenshot tool
    lshw # list hardware details
    sshfs # acsess to folk.NTNU
    xidlehook # autolocker
    ntfs3g # Windows filesystem support
    file-roller # zip and unzip for thunar
    mesa-demos # GPU utils
    nftables # Filefwall tools
    glmark2 # GPU benchmark
    mpv # the best video player
    bat # cat but with colors
    bat-extras.core # Batman!
    ffmpeg-full

    # MAN PAGES:
    man-pages
    man-pages-posix

  ] ++ userprograms.system;
  documentation.dev.enable = true;
  documentation.man = {
    man-db.enable = false;
    mandoc.enable = true;
  };

  # ------------------------------------------------------------------------------------------
  # -------------------------------------- SYNCTHING -----------------------------------------
  # ------------------------------------------------------------------------------------------

  services.syncthing = {
    enable = true;
    group = "users";
    user = profile.username;
    configDir = "/home/${profile.username}/.config/syncthing";
  }; # GUI on http://127.0.0.1:8384/

  # ------------------------------------------------------------------------------------------
  # -------------------------------------- FILEMANAGER ---------------------------------------
  # ------------------------------------------------------------------------------------------

  programs.thunar.enable = true;
  programs.xfconf.enable = true;
  programs.thunar.plugins = with pkgs; [
    thunar-archive-plugin
    thunar-volman
  ];
  services.gvfs.enable = true; # Mount, trash, and other functionalities
  services.tumbler.enable = true; # Thumbnail support for images
  services.udisks2.enable = true; # AutoMount backend

  # ------------------------------------------------------------------------------------------
  # ---------------------------------------- FONTS -------------------------------------------
  # ------------------------------------------------------------------------------------------

  fonts.packages = with pkgs; [
    jetbrains-mono # system font
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    noto-fonts-monochrome-emoji
    liberation_ttf
    fira-code
    fira-code-symbols
    mplus-outline-fonts.githubRelease
    dina-font
    proggyfonts
    nerd-fonts.jetbrains-mono
    nerd-fonts.inconsolata
    font-awesome
  ];
  fonts.fontDir.enable = true;

}