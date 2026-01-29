# Mutable mode - standard read-write NixOS system
# When vm.mutable = true, the system uses a single read-write disk
# with full nix toolchain support (nix-env, nixos-rebuild, etc.)
{ config, lib, pkgs, ... }:

let
  adminUser = config.core.adminUser;
  regularUser = config.core.regularUser;
in
{
  options.vm.mutable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable mutable mode with single read-write disk";
  };

  config = lib.mkIf config.vm.mutable {
    # Standard writable root filesystem (single disk on /dev/vda)
    fileSystems."/" = lib.mkForce {
      device = "/dev/vda2";
      fsType = "ext4";
      options = [ "rw" "noatime" ];
    };

    fileSystems."/boot" = lib.mkForce {
      device = "/dev/vda1";
      fsType = "vfat";
      options = [ "rw" ];
    };

    # No separate /var mount - use standard layout
    fileSystems."/var" = lib.mkForce { };

    # Standard /home (not a bind mount)
    fileSystems."/home" = lib.mkForce { };

    # Standard /root
    fileSystems."/root" = lib.mkForce { };

    # /tmp as tmpfs (standard)
    fileSystems."/tmp" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=1777" "strictatime" "nosuid" "nodev" "size=50%" ];
    };

    # No machine-id bind mount - use standard /etc/machine-id
    fileSystems."/etc/machine-id" = lib.mkForce { };

    # No authorized_keys bind mounts - use standard SSH authorized_keys
    fileSystems."/etc/ssh/authorized_keys.d/${adminUser}" = lib.mkForce { };
    fileSystems."/etc/ssh/authorized_keys.d/${regularUser}" = lib.mkForce { };

    # No resolv.conf bind mount
    fileSystems."/etc/resolv.conf" = lib.mkForce { };

    # No /etc/hosts bind mount
    fileSystems."/etc/hosts" = lib.mkForce { };

    # Enable standard DHCP (no systemd-networkd needed)
    networking.useDHCP = lib.mkForce true;
    networking.useNetworkd = lib.mkForce false;
    systemd.network.enable = lib.mkForce false;

    # Standard filesystem growth (these may not exist, so use mkDefault)
    # systemd.services.growpart.enable = lib.mkDefault true;
    # systemd.services."systemd-growfs-root".enable = lib.mkDefault true;
    systemd.services."systemd-boot-random-seed".enable = lib.mkForce true;

    # Disable immutable-specific services
    systemd.services.grow-var-partition.enable = lib.mkForce false;
    systemd.services.vm-identity.enable = lib.mkForce false;
    systemd.services.firewall-identity.enable = lib.mkForce false;
    systemd.services.dns-identity.enable = lib.mkForce false;
    systemd.services.hosts-identity.enable = lib.mkForce false;
    systemd.services.root-password.enable = lib.mkForce false;

    # Use standard SSH authorized_keys in /home
    services.openssh.authorizedKeysFiles = lib.mkForce [
      "/etc/ssh/authorized_keys.d/%u"
      ".ssh/authorized_keys"
    ];

    # Enable nix garbage collection (works with writable /nix)
    nix.gc.automatic = lib.mkForce true;
    nix.gc.dates = "weekly";
    nix.gc.options = "--delete-older-than 30d";
  };
}
