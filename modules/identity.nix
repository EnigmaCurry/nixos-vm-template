{ config, lib, pkgs, ... }:

# VM identity is stored on /var/identity and loaded at boot.
# This allows a single base image to be shared by multiple VMs.
#
# Identity files on /var/identity (written during VM creation):
#   hostname              - VM hostname
#   machine-id            - systemd machine ID
#   admin_authorized_keys - SSH authorized keys for 'admin' user
#   user_authorized_keys  - SSH authorized keys for 'user' user
#   ssh_host_*_key        - SSH host keys (auto-generated if ssh profile enabled)
#
# Users are defined in profiles/ssh.nix (admin with sudo, user without).

{
  # Immutable-mode identity configuration
  config = lib.mkIf (!config.vm.mutable) {
    # Don't let NixOS manage the hostname - we set it from /var/identity/hostname at boot
    networking.hostName = lib.mkDefault "";

    # Service to set hostname from /var/identity/hostname at boot
    systemd.services.vm-hostname = {
      description = "Set hostname from /var/identity/hostname";
      wantedBy = [ "sysinit.target" ];
      before = [ "network-pre.target" "systemd-hostnamed.service" ];
      after = [ "local-fs.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ -f /var/identity/hostname ]; then
          hostname=$(cat /var/identity/hostname | tr -d '\n')
          ${pkgs.hostname}/bin/hostname "$hostname"
          echo "Hostname set to: $hostname"
        fi
      '';
    };

    # Ensure identity directory exists on /var
    systemd.tmpfiles.rules = [
      "d /var/identity 0755 root root -"
    ];

    # Create placeholder for machine-id bind mount
    environment.etc."machine-id" = {
      text = "uninitialized\n";
      mode = "0444";
    };

    # Bind mount /etc/machine-id from /var (mounts over the placeholder)
    fileSystems."/etc/machine-id" = {
      device = "/var/identity/machine-id";
      fsType = "none";
      options = [ "bind" ];
      depends = [ "/var" ];
    };

    # Create placeholder for hostname bind mount
    environment.etc."hostname" = lib.mkForce {
      text = "nixos\n";
      mode = "0644";
    };

    # Bind mount /etc/hostname from /var (mounts over the placeholder)
    fileSystems."/etc/hostname" = {
      device = "/var/identity/hostname";
      fsType = "none";
      options = [ "bind" "nofail" ];
      depends = [ "/var" ];
    };
  };
}
