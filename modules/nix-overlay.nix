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
    # Mount /nix overlay via a systemd service that creates the dirs first.
    # We cannot use fileSystems because the overlay dirs on /var may not
    # exist yet when systemd processes local-fs.target mounts.
    systemd.services.nix-overlay = {
      description = "Mount writable /nix overlay";
      wantedBy = [ "local-fs.target" ];
      after = [ "var.mount" ];
      before = [ "nix-daemon.service" "local-fs.target" ];
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = "/var";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /var/nix-overlay/upper /var/nix-overlay/work
        ${pkgs.util-linux}/bin/mount -t overlay overlay \
          -o lowerdir=/nix,upperdir=/var/nix-overlay/upper,workdir=/var/nix-overlay/work \
          /nix
      '';
    };

    # Enable nix garbage collection (writable /nix supports GC)
    nix.gc.automatic = lib.mkForce true;
    nix.gc.dates = "weekly";
    nix.gc.options = "--delete-older-than 30d";
  };
}
