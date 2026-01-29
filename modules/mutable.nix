# Mutable mode - standard read-write NixOS system
# When vm.mutable = true, the system uses a single read-write disk
# with full nix toolchain support (nix-env, nixos-rebuild, etc.)
#
# Other modules check config.vm.mutable to conditionally enable
# immutable-specific features (bind mounts, identity loading, etc.)
{ config, lib, pkgs, ... }:

{
  options.vm.mutable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable mutable mode with single read-write disk";
  };

  config = lib.mkIf config.vm.mutable {
    # Standard writable root filesystem
    # Use mkForce to override nixos-generators qcow format defaults
    # Keep the label-based device from nixos-generators but make it read-write
    fileSystems."/" = lib.mkForce {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
      options = [ "rw" "noatime" ];
    };

    fileSystems."/boot" = lib.mkForce {
      device = "/dev/disk/by-label/ESP";
      fsType = "vfat";
      options = [ "rw" ];
    };

    # Enable standard DHCP (not systemd-networkd)
    networking.useDHCP = lib.mkForce true;
    networking.useNetworkd = lib.mkForce false;
    systemd.network.enable = lib.mkForce false;

    # Enable boot random seed (disabled in immutable mode)
    systemd.services."systemd-boot-random-seed".enable = lib.mkForce true;

    # Use standard SSH authorized_keys locations
    services.openssh.authorizedKeysFiles = lib.mkForce [
      "/etc/ssh/authorized_keys.d/%u"
      ".ssh/authorized_keys"
    ];

    # Open SSH port in firewall (immutable mode uses firewall-identity.nix instead)
    networking.firewall.allowedTCPPorts = [ 22 ];

    # Enable nix garbage collection (works with writable /nix)
    nix.gc.automatic = lib.mkForce true;
    nix.gc.dates = "weekly";
    nix.gc.options = "--delete-older-than 30d";

    # TEMPORARY: Set root password for debugging
    users.users.root.initialPassword = "root";
  };
}
