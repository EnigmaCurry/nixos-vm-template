{ config, lib, pkgs, ... }:

{
  # Use systemd in initrd (required for proper boot sequencing)
  boot.initrd.systemd.enable = true;

  # Note: /etc overlay is disabled - causes boot failures with nixos-generators
  # Instead, we bind mount specific files from /var/identity
}
