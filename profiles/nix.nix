# Nix profile - mutable /nix filesystem for running nix commands
# Inherits from core and bind mounts /nix to /var/nix for read-write access
{ config, lib, pkgs, ... }:

{
  imports = [
    ./core.nix
  ];

  # Bind mount /nix to /var/nix for read-write access
  fileSystems."/nix" = {
    device = "/var/nix";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/var" ];
  };

  # Ensure /var/nix exists on first boot
  systemd.tmpfiles.rules = [
    "d /var/nix 0755 root root -"
  ];
}
