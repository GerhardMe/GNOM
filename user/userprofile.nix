# This is your profile.
# It is a way to manage personal data, like name, email and machine settings. (not a secret)
# You may add custom keys and use them as profile.<key> in configuration.nix / home.nix.

{
  hostname = "gnoms";
  username = "gg";

  timezone = "Europe/Oslo";
  locale = "en_GB.UTF-8";
  keyboard_layout = "no";

  # Where the swapfile starts on disk (hibernate). The installer computes this;
  # if you ever recreate the swapfile, update it (see configuration.nix comment).
  resume_offset = 589824;

  github_name = "Gerhard";
  github_email = "gerhard.git@proton.me";
}
