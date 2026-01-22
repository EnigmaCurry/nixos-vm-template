{ config, lib, pkgs, ... }:

{
  # UEFI boot with systemd-boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;  # Read-only root

  # Use the latest kernel
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

  # Console settings
  boot.consoleLogLevel = lib.mkDefault 3;
  boot.kernelParams = [ "quiet" ];

  # initrd modules for virtio
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "virtio_net"
    "ahci"
    "sd_mod"
  ];

  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
  boot.extraModulePackages = [ ];
}
