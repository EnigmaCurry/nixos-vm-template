{ config, lib, pkgs, ... }:

# VM-only: an LXC container has no initrd (boot.isContainer = true).
lib.mkIf (!config.vm.container) {
  # Note: systemd-in-initrd is unconditional as of nixpkgs 2026-10
  # (scripted initrd removed), so there is nothing to opt into here.

  # Note: /etc overlay is disabled - causes boot failures with nixos-generators
  # Instead, we bind mount specific files from /var/identity
}
