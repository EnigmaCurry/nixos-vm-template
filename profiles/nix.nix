# Nix profile - mutable /nix filesystem for running nix commands
# Inherits from core and uses overlayfs to make /nix writable while
# preserving the base image content as the lower layer
{ config, lib, pkgs, ... }:

{
  imports = [
    ./core.nix
  ];

  # Set up overlay for /nix in initrd, before switch_root
  # This allows /nix to be writable while keeping the base image read-only
  boot.initrd.postMountCommands = ''
    # Ensure /var/nix directories exist (create on the mounted /var disk)
    mkdir -p /mnt-root/var/nix/upper
    mkdir -p /mnt-root/var/nix/work

    # Create mount point for the original read-only /nix
    mkdir -p /mnt-root/nix.base

    # Bind mount the original /nix to /nix.base (read-only)
    mount --bind /mnt-root/nix /mnt-root/nix.base
    mount -o remount,ro,bind /mnt-root/nix.base

    # Mount overlay on /nix with base image as lower layer
    mount -t overlay overlay \
      -o lowerdir=/mnt-root/nix.base,upperdir=/mnt-root/var/nix/upper,workdir=/mnt-root/var/nix/work \
      /mnt-root/nix
  '';

  # Declare /nix.base mount so NixOS knows about it
  fileSystems."/nix.base" = {
    device = "/nix.base";
    fsType = "none";
    options = [ "bind" "ro" "nofail" ];
  };
}
