{ system, nixpkgs, config, home-manager, pkgs, ... }: {

  # ------------------------------------------------------------------------------------------
  # ----------------------------------------- SETTINGS ---------------------------------------
  # ------------------------------------------------------------------------------------------

  home.stateVersion = "24.11";

  # ENV varriables
  home.sessionVariables = {
    GIT_EDITOR = "nvim";
    EDITOR = "nvim";
    BROWSER = "firefox";
    XCURSOR_THEME = "phinger-cursors-light";
  };

  # Custom directories
  xdg.userDirs = {
    enable = true;
    setSessionVariables = false;
    download = "$HOME/downloads";
    pictures = "$HOME/media/img";
    videos = "$HOME/media/vid";
    music = "$HOME/media/music";
    documents = "$HOME/workspaces";
    desktop = "$HOME/workspaces";
    templates = "$HOME/.xdgdirs/templates";
  };

  home.file.".config/gtk-3.0/bookmarks".text = ''
    file://${config.home.homeDirectory}/downloads Downloads
    file://${config.home.homeDirectory}/media/img Images
    file://${config.home.homeDirectory}/media/vid Videos
    file://${config.home.homeDirectory}/media/music Music
  '';

  # ------------------------------------------------------------------------------------------
  # ----------------------------------------- SERVICES ---------------------------------------
  # ------------------------------------------------------------------------------------------

  # Handle hardware events
  systemd.user.services.hw-events = {
    Unit = {
      Description = "handle all hardware events";
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/GNOMS/scripts/hardware-events.sh";
      Restart = "on-failure";
      RestartSec = 10;
      Environment = "PATH=/run/current-system/sw/bin";
      Group = "users";
    };
    Install = { WantedBy = [ "default.target" ]; };
  };

  # Sleep inhibetor service
  systemd.user.services.awake = {
    Unit = {
      Description = "Keep laptop awake (block suspend + lid close)";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart =
        "${pkgs.systemd}/bin/systemd-inhibit --what=idle:sleep:handle-lid-switch --mode=block --why='server mode' ${pkgs.coreutils}/bin/sleep infinity";
      # If you stop it, it stays stopped. No Restart.
      Environment = "PATH=/run/current-system/sw/bin";
    };
    Install = { WantedBy = [ "default.target" ]; };
  };

  # SSH watcher
  systemd.user.services.ssh-bar = {
    Unit = {
      Description = "Watch sshd journal";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "%h/GNOMS/scripts/ssh-detect.sh";
      Restart = "always";
      RestartSec = 1;
      Environment = [
        "PATH=%h/.nix-profile/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin"
        "DISPLAY=:0"
        "XDG_RUNTIME_DIR=%t"
      ];
    };
    Install = { WantedBy = [ "default.target" ]; };
  };

  # ------------------------------------------------------------------------------------------
  # ----------------------------------------- RICE -------------------------------------------
  # ------------------------------------------------------------------------------------------

  home.pointerCursor = {
    enable = true;
    name = "phinger-cursors-light";
    package = pkgs.phinger-cursors;
    size = 32;
    gtk.enable = true;
  };

gtk = {
  enable = true;
  iconTheme = {
    name = "Papirus-Dark";
    package = pkgs.papirus-icon-theme;
  };
  theme = {
    name = "Adwaita-dark";
    package = pkgs.gnome-themes-extra;
  };
  gtk4.theme = null;
  # Disable the audible error bell (water-drop sound on invalid input)
  gtk2.extraConfig = "gtk-error-bell = 0";
  gtk3.extraConfig."gtk-error-bell" = false;
  gtk4.extraConfig."gtk-error-bell" = false;
};

  # ------------------------------------------------------------------------------------------
  # ----------------------------------------- USER PROGRAMS ----------------------------------
  # ------------------------------------------------------------------------------------------

  nixpkgs.config.allowUnfree = true;
  home.packages = with pkgs; [
    # Rice:
    unclutter
    xwallpaper
    papirus-icon-theme
    fastfetch

    {{user_programs}}
  ];

  # ------------------------------------------------------------------------------------------
  # ---------------------------------------- NEOVIM ------------------------------------------
  # ------------------------------------------------------------------------------------------

  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    withRuby = false;
    withPython3 = false;
  };

  # ------------------------------------------------------------------------------------------
  # ----------------------------------------- GIT --------------------------------------------
  # ------------------------------------------------------------------------------------------

  programs.git = {
    enable = true;
    settings.user = {
      name = "{{github_name}}";
      email = "{{github_email}}";
    };
    signing.format = null;
  };

  # ------------------------------------------------------------------------------------------
  # ----------------------------------------- FIREFOX ----------------------------------------
  # ------------------------------------------------------------------------------------------

  programs = {
    firefox = {
      enable = true;
      configPath = "${config.xdg.configHome}/mozilla/firefox";
      languagePacks = [ "en-UK" "no" ];

      # ---- POLICIES ----
      # Check about:policies#documentation for options.
      policies = {
        AppAutoUpdate = false;
        BackgroundAppUpdate = false;
        DisableTelemetry = true;
        DisableFirefoxStudies = true;
        EnableTrackingProtection = {
          Value = true;
          Locked = true;
          Cryptomining = true;
          Fingerprinting = true;
        };
        DisablePocket = true;
        DisableFirefoxAccounts = true;
        DisableAccounts = true;
        DisableFirefoxScreenshots = true;
        OverrideFirstRunPage = "";
        OverridePostUpdatePage = "";
        DontCheckDefaultBrowser = true;
        DisplayBookmarksToolbar = "never"; # alternatives: "always" or "newtab"
        DisplayMenuBar =
          "default-off"; # alternatives: "always", "never" or "default-on"
        OfferToSaveLogins = false;
        SearchBar = "unified"; # alternative: "separate"
        PasswordManagerEnabled = false;

        # ---- EXTENSIONS ----
        # Check about:support for extension/add-on ID strings.
        # Valid strings for installation_mode are "allowed", "blocked",
        # "force_installed" and "normal_installed".
        ExtensionSettings = {
          "*".installation_mode = "allowed";
          # uBlock Origin:
          "uBlock0@raymondhill.net" = {
            install_url =
              "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi";
            installation_mode = "force_installed";
          };
          # Privacy Badger:
          "jid1-MnnxcxisBPnSXQ@jetpack" = {
            install_url =
              "https://addons.mozilla.org/firefox/downloads/latest/privacy-badger17/latest.xpi";
            installation_mode = "force_installed";
          };
          # Proton Pass:
          "78272b6fa58f4a1abaac99321d503a20@proton.me" = {
            install_url =
              "https://addons.mozilla.org/firefox/downloads/latest/proton-pass/latest.xpi";
            installation_mode = "force_installed";
          };
          # Proton VPN:
          "vpn@proton.ch" = {
            install_url =
              "https://addons.mozilla.org/firefox/downloads/file/4539502/proton_vpn_firefox_extension-1.2.9.xpi";
            installation_mode = "force_installed";
          };
          # Unhook:
          "myallychou@gmail.com" = {
            install_url =
              "https://addons.mozilla.org/firefox/downloads/file/4263531/youtube_recommended_videos-1.6.7.xpi";
            installation_mode = "force_installed";
          };
          # Theme:
          "dreamer-bold-colorway@mozilla.org" = {
            install_url =
              "https://addons.mozilla.org/firefox/downloads/latest/dreamer-bold/latest.xpi";
            installation_mode = "force_installed";
          };
        };

        # ---- PREFERENCES ----
        # Check about:config for options.
        Preferences = {
          "browser.contentblocking.category" = {
            Value = "strict";
            Status = "locked";
          };
          "browser.tabs.inTitlebar" = {
            Value = 0;
            Status = "default";
          };
          "browser.newtabpage.activity-stream.feeds.topsites" = {
            Value = false;
            Status = "default";
          };
          "browser.newtabpage.activity-stream.showSponsoredTopSites" = {
            Value = false;
            Status = "default";
          };
          "sidebar.revamp" = {
            Value = true;
            Status = "default";
          };
          "sidebar.verticalTabs" = {
            Value = true;
            Status = "default";
          };
        };
      };

      profiles.default = {
        isDefault = true;
        search = {
          force          = true;
          default        = "ddg";
          privateDefault = "ddg";
        };
      };
    };
  };

}