{ config, lib, pkgs, ... }:

# VM-only: an LXC container (vm.container = true) shares the host kernel and has
# no bootloader/UEFI/virtio block devices, so none of this applies there.
lib.mkIf (!config.vm.container) {
  # UEFI boot with systemd-boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;  # Read-only root

  # Use the latest kernel
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

  # Console settings
  boot.consoleLogLevel = lib.mkDefault 3;
  # Serial console (ttyS0) is the production default; ttyS0 is listed last so
  # it becomes the primary /dev/console and systemd spawns a serial-getty on it.
  # tty0 (VGA) still gets kernel messages for debugging once the backend is
  # manually reconfigured for a graphical display.
  boot.kernelParams = [ "quiet" "console=tty0" "console=ttyS0,115200" ];

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
