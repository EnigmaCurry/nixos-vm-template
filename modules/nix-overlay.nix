# Semi-mutable mode - overlayfs on /nix for runtime package installation
# When vm.nixOverlay = true (and vm.mutable = false), /nix gets an overlay
# with the read-only base image as lower and /var/nix-overlay as upper.
# The overlay persists across reboots but is wiped on upgrade.
{ config, lib, pkgs, ... }:

{
  options.vm.nixOverlay = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable writable /nix overlay (semi-mutable mode)";
  };

  config = lib.mkIf (!config.vm.mutable && config.vm.nixOverlay) {
    # Overlay /nix: lower is the read-only /nix from the base image,
    # upper and work directories live on the writable /var disk.
    fileSystems."/nix" = {
      device = "overlay";
      fsType = "overlay";
      options = [
        "lowerdir=/nix"
        "upperdir=/var/nix-overlay/upper"
        "workdir=/var/nix-overlay/work"
      ];
      depends = [ "/var" ];
      neededForBoot = true;
    };

    # Ensure overlay directories exist on /var
    systemd.tmpfiles.rules = [
      "d /var/nix-overlay 0755 root root -"
      "d /var/nix-overlay/upper 0755 root root -"
      "d /var/nix-overlay/work 0755 root root -"
    ];

    # Enable nix garbage collection (writable /nix supports GC)
    nix.gc.automatic = lib.mkForce true;
    nix.gc.dates = "weekly";
    nix.gc.options = "--delete-older-than 30d";
  };
}
