# Per-machine root password module
#
# Uses the placeholder + bind mount pattern (same as machine-id) to
# override /etc/shadow with a version that includes the per-machine
# root password hash from /var/identity.
{ config, lib, pkgs, ... }:

{
  # Immutable-mode root password configuration
  config = lib.mkIf (!config.vm.mutable) {
    # Generate a shadow file and bind-mount it over /etc/shadow
    systemd.services.root-password = {
      description = "Set root password from /var/identity";
      wantedBy = [ "multi-user.target" ];
      before = [ "getty.target" "sshd.service" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Build shadow entries from /etc/passwd
        # Root gets the per-machine hash (if configured), all others get no password
        root_hash="!"
        if [ -s /var/identity/root_password_hash ]; then
          root_hash=$(cat /var/identity/root_password_hash)
        fi

        while IFS=: read -r username _ _ _ _ _ _; do
          if [ "$username" = "root" ]; then
            printf '%s:%s:1::::::\n' "$username" "$root_hash"
          else
            printf '%s:!:1::::::\n' "$username"
          fi
        done < /etc/passwd > /run/shadow

        chmod 600 /run/shadow
        ${pkgs.util-linux}/bin/mount --bind /run/shadow /etc/shadow
      '';
    };
  };
}
