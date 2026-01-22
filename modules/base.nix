{ config, lib, pkgs, ... }:

{
  # System basics
  system.stateVersion = "24.11";

  # Disable automatic garbage collection (breaks on read-only root)
  nix.gc.automatic = false;

  # Enable flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Packages are defined in profiles (see profiles/ directory)
  # SSH is enabled via profiles/ssh.nix

  # Basic networking
  networking = {
    useDHCP = lib.mkDefault true;
    firewall.enable = true;
  };

  # Timezone
  time.timeZone = lib.mkDefault "UTC";

  # Locale
  i18n.defaultLocale = "en_US.UTF-8";

  # Allow "no password" at build time since the real shadow file is bind-mounted at boot
  users.allowNoPasswordLogin = true;
  users.mutableUsers = false;
}
