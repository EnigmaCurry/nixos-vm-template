# cloud-init profile — makes the built image a clonable Proxmox template.
#
# On first boot, cloud-init reads the seed drive that PVE attaches (NoCloud
# datasource) and sets the hostname, network config, SSH host keys, and any
# `users:` / `write_files:` from the user-data snippet. Clones from the
# template each get their own identity that way instead of inheriting the
# baked-in one.
#
# This profile requires `mutable` mode — cloud-init writes to /etc/hostname,
# /etc/ssh/ssh_host_*_key, systemd-networkd configs, etc., all of which are
# read-only in immutable/semi-mutable modes. src/vm/profile.clj enforces this:
# combining cloud-init with semi-mutable is rejected; combining with an
# unset (default = immutable) mode auto-implies mutable.
{ config, lib, pkgs, ... }:

{
  services.cloud-init = {
    enable = true;
    network.enable = true;
    settings = {
      # PVE attaches its cloud-init seed as NoCloud. ConfigDrive is included
      # as a fallback for other hypervisors.
      datasource_list = [ "NoCloud" "ConfigDrive" ];
    };
  };

  # qemu-guest-agent lets PVE report the VM's IP + trigger clean shutdowns.
  services.qemuGuest.enable = true;

  # cloud-init modules invoke `growpart` and related helpers.
  environment.systemPackages = with pkgs; [ cloud-utils ];
}
