# Nix profile - mutable /nix filesystem for running nix commands
# Uses overlayfs to make /nix writable while preserving the base image
# content as the lower layer
{ config, lib, pkgs, ... }:

{
  # Make /nix/store writable - remove default ro,nosuid,nodev options
  # Our overlay on /nix handles the actual write layer
  boot.nixStoreMountOpts = [ ];

  # Load overlay kernel module in initrd
  boot.initrd.kernelModules = [ "overlay" ];

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
      # Create directories on /var (which is writable)
      mkdir -p /sysroot/var/nix/base
      mkdir -p /sysroot/var/nix/upper
      mkdir -p /sysroot/var/nix/work

      # Bind mount the original /nix to /var/nix/base (read-only)
      mount --bind /sysroot/nix /sysroot/var/nix/base
      mount -o remount,ro,bind /sysroot/var/nix/base

      # Mount overlay on /nix with base image as lower layer
      mount -t overlay overlay \
        -o lowerdir=/sysroot/var/nix/base,upperdir=/sysroot/var/nix/upper,workdir=/sysroot/var/nix/work \
        /sysroot/nix
    '';
  };
}
