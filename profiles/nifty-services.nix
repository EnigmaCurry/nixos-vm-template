# Nifty infrastructure services profile
#
# Runs containerized network services (NTP, mDNS, monitoring, etc.)
# on a dedicated infra VLAN, managed by podman.
#
# Usage: just create infra-services podman,nifty-services

{ config, lib, pkgs, nifty-filter, ... }:

{
  imports = [ nifty-filter.nixosModules.services ];

  config = {
    boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];

    services.nifty-services.enable = true;
    services.nifty-services.chrony.enable = true;

    # PVE: /var disk is a raw LVM thin volume (no partition table).
    # Override the default /dev/vdb1 mount to use /dev/vdb directly.
    fileSystems."/var" = lib.mkForce {
      device = "/dev/vdb";
      fsType = "ext4";
      options = [ "rw" "noatime" ];
      neededForBoot = true;
    };
  };
}
