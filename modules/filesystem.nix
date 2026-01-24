{ config, lib, pkgs, ... }:

{
  # Root filesystem is read-only
  fileSystems."/" = {
    device = lib.mkDefault "/dev/vda2";
    fsType = "ext4";
    options = [ "ro" ];
  };

  # EFI system partition
  fileSystems."/boot" = {
    device = lib.mkDefault "/dev/vda1";
    fsType = "vfat";
    options = [ "ro" ];
  };

  # /var on separate disk (read-write, all mutable state)
  fileSystems."/var" = {
    device = lib.mkDefault "/dev/vdb1";
    fsType = "ext4";
    options = [ "rw" "noatime" ];
    neededForBoot = true;
  };

  # /home is a bind mount of /var/home
  fileSystems."/home" = {
    device = "/var/home";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/var" ];
  };

  # /root is a bind mount of /var/root (persistent root home directory)
  fileSystems."/root" = {
    device = "/var/root";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/var" ];
  };

  # /tmp as tmpfs (root is read-only)
  fileSystems."/tmp" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "mode=1777" "strictatime" "nosuid" "nodev" "size=50%" ];
  };

  # Ensure /var/home and /var/root exist on first boot
  systemd.tmpfiles.rules = [
    "d /var/home 0755 root root -"
    "d /var/root 0700 root root -"
  ];
}
