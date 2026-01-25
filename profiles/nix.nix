# Nix profile - mutable /nix filesystem for running nix commands
# Inherits from core and uses overlayfs to make /nix writable while
# preserving the base image content as the lower layer
{ config, lib, pkgs, ... }:

{
  imports = [
    ./core.nix
  ];

  # Set up overlay for /nix in initrd using systemd (stage 1)
  # This runs after root and /var are mounted but before switch-root
  boot.initrd.systemd.services.nix-overlay = {
    description = "Set up /nix overlay filesystem";
    # Run after filesystems are mounted, before switching to real root
    after = [ "sysroot.mount" "sysroot-var.mount" ];
    before = [ "initrd-switch-root.target" ];
    wantedBy = [ "initrd-switch-root.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Ensure /var/nix directories exist on the mounted /var disk
      mkdir -p /sysroot/var/nix/upper
      mkdir -p /sysroot/var/nix/work

      # Create mount point for the original read-only /nix
      mkdir -p /sysroot/nix.base

      # Bind mount the original /nix to /nix.base (read-only)
      mount --bind /sysroot/nix /sysroot/nix.base
      mount -o remount,ro,bind /sysroot/nix.base

      # Mount overlay on /nix with base image as lower layer
      mount -t overlay overlay \
        -o lowerdir=/sysroot/nix.base,upperdir=/sysroot/var/nix/upper,workdir=/sysroot/var/nix/work \
        /sysroot/nix
    '';
  };

  # Declare /nix.base mount so NixOS knows about it after boot
  fileSystems."/nix.base" = {
    device = "/nix.base";
    fsType = "none";
    options = [ "bind" "ro" "nofail" ];
  };
}
