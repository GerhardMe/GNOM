# This is your profile.
# It is a way to manage personal data, like name, email and machine settings. (not a secret)
# You may add custom keys and use them as profile.<key> in configuration.nix / home.nix.

{
  hostname = "gnoms";
  username = "gg";

  timezone = "Europe/Oslo";
  locale = "en_GB.UTF-8";
  keyboard_layout = "no";

  # Programs used across GNOMS (exported as env vars in configuration.nix).
  terminal = "wezterm";
  editor = "nvim";
  browser = "firefox";

  # Seconds the GRUB menu waits before booting the default entry.
  boot_timeout = 1;

  github_name = "Gerhard";
  github_email = "gerhard.git@proton.me";

  # Dual-boot: if true, GNOMS installs its GRUB as a contained instance
  # (/EFI/GNOMS + a separate firmware entry) and never touches the boot order
  # of an existing OS. If false, GRUB owns the ESP and NVRAM like standard
  # NixOS. The installer sets this when it detects a dual-boot target.
  dualboot = false;
}
