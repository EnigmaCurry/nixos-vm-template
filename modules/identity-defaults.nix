# Identity defaults module - ensures required identity files exist on first boot
#
# When a VM boots with a bare /var disk (no pre-provisioned identity),
# this module creates sensible defaults for all required identity files.
# This enables "generic image" distribution where the user only needs to
# provide SSH authorized_keys on the /var disk before booting.
#
# Required files (bind-mounted without nofail):
#   machine-id            - generated UUID if missing
#   admin_authorized_keys - empty if missing (login disabled until populated)
#   user_authorized_keys  - empty if missing
#   hostname              - defaults to "nixos" if missing
{ config, lib, pkgs, ... }:

let
  adminUser = config.core.adminUser;
  regularUser = config.core.regularUser;
in
{
  config = lib.mkIf (!config.vm.mutable) {
    # Ensure required identity files exist before bind mounts.
    # Runs after var.mount but before local-fs.target (when bind mounts happen).
    systemd.services.identity-defaults = {
      description = "Create default identity files if missing";
      wantedBy = [ "local-fs.target" ];
      before = [
        "local-fs.target"
        # Must run before bind mounts that depend on these files
        "etc-machine\\x2did.mount"
        "etc-ssh-authorized_keys.d-${adminUser}.mount"
        "etc-ssh-authorized_keys.d-${regularUser}.mount"
      ];
      after = [ "var.mount" ];
      requires = [ "var.mount" ];
      unitConfig.DefaultDependencies = false;

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        mkdir -p /var/identity

        # machine-id: generate random UUID if missing
        if [ ! -f /var/identity/machine-id ]; then
          ${pkgs.util-linux}/bin/uuidgen | tr -d '-' > /var/identity/machine-id
          chmod 0444 /var/identity/machine-id
          echo "identity-defaults: generated machine-id"
        fi

        # hostname: default to "nixos" if missing
        if [ ! -f /var/identity/hostname ]; then
          echo "nixos" > /var/identity/hostname
          chmod 0644 /var/identity/hostname
          echo "identity-defaults: set default hostname"
        fi

        # authorized_keys: create empty files if missing
        if [ ! -f /var/identity/${adminUser}_authorized_keys ]; then
          install -m 0600 /dev/null /var/identity/${adminUser}_authorized_keys
          echo "identity-defaults: created empty ${adminUser}_authorized_keys"
        fi

        if [ ! -f /var/identity/${regularUser}_authorized_keys ]; then
          install -m 0600 /dev/null /var/identity/${regularUser}_authorized_keys
          echo "identity-defaults: created empty ${regularUser}_authorized_keys"
        fi
      '';
    };
  };
}
