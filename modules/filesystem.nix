{ config, lib, pkgs, ... }:

{
  # /tmp as tmpfs (always needed)
  fileSystems."/tmp" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "mode=1777" "strictatime" "nosuid" "nodev" "size=50%" ];
  };

  # Immutable mode filesystem layout (two-disk setup)
  config = lib.mkIf (!config.vm.mutable) {
    # Include cloud-utils for growpart
    environment.systemPackages = [ pkgs.cloud-utils ];

    # Grow /var partition and filesystem on boot if disk was resized
    systemd.services.grow-var-partition = {
      description = "Grow /var partition to fill disk";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Grow partition to fill available space
        ${pkgs.cloud-utils}/bin/growpart /dev/vdb 1 || true
        # Resize filesystem (online resize supported for ext4)
        ${pkgs.e2fsprogs}/bin/resize2fs /dev/vdb1 || true
      '';
    };

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
      autoResize = true;
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

    # Ensure /var/home and /var/root exist on first boot
    systemd.tmpfiles.rules = [
      "d /var/home 0755 root root -"
      "d /var/root 0700 root root -"
    ];
  };
}
