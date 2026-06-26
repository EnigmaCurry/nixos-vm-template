{ config, lib, pkgs, ... }:

# VM-only: an LXC container has no initrd (boot.isContainer = true).
lib.mkIf (!config.vm.container) {
  # Use systemd in initrd (required for proper boot sequencing)
  boot.initrd.systemd.enable = true;

  # Note: /etc overlay is disabled - causes boot failures with nixos-generators
  # Instead, we bind mount specific files from /var/identity
}
