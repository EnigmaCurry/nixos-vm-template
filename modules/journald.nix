{ config, lib, pkgs, ... }:

{
  # Configure journald for persistent storage on /var
  services.journald = {
    storage = "persistent";
    extraConfig = ''
      SystemMaxUse=500M
      SystemKeepFree=1G
      MaxRetentionSec=1month
    '';
  };

  # Ensure journal directory exists
  systemd.tmpfiles.rules = [
    "d /var/log/journal 2755 root systemd-journal -"
  ];
}
