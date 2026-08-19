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

  # The nixos-generators qcow2 build baked cloud-init state into the image
  # (obj.pkl / instance-id in /var/lib/cloud) AND generated SSH host keys.
  # Both are per-VM identity that must NOT be shared across clones:
  # * With baked instance-id, cloud-init on every clone sees a "previous iid
  #   matches", denies boot-event network updates, and skips once-per-instance
  #   modules (users, passwords, ssh authorized keys) → user-data is ignored.
  # * With baked SSH host keys, every clone advertises the same host identity.
  #
  # This oneshot runs BEFORE cloud-init.service and, on the first boot after
  # a clone, wipes both. The marker file /var/lib/nixos-vm-template.first-boot-done
  # is created after wiping; subsequent boots on the same VM see the marker
  # and skip. Because we never *declare* the marker in any Nix module, the
  # built image doesn't ship with it — so a fresh clone always finds it
  # missing on its first boot.
  systemd.services.cloud-init-clone-clean = {
    description = "Wipe baked-in cloud-init/SSH state on first boot of a clone";
    wantedBy = [ "cloud-init.target" ];
    before = [ "cloud-init.service" ];
    unitConfig.ConditionPathExists = "!/var/lib/nixos-vm-template.first-boot-done";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      rm -rf /var/lib/cloud/*
      rm -f  /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
      mkdir -p /var/lib
      touch /var/lib/nixos-vm-template.first-boot-done
    '';
  };
}
