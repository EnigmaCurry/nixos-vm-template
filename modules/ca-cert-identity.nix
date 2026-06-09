# Trust a CA certificate from /var/identity at boot time.
#
# If machines/<name>/ca-cert.pem exists, it is copied to /var/identity/ca-cert.pem
# by the backend at install/upgrade time. This module reads it at boot and adds
# it to the system trust store so all TLS clients (curl, reqwest, etc.) trust it.
{ config, lib, pkgs, ... }:

let
  caCertPath = "/var/identity/ca-cert.pem";
in
{
  config = lib.mkIf (!config.vm.mutable) {
    systemd.services.ca-cert-identity = {
      description = "Add CA certificate from identity to system trust store";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" "var.mount" ];
      wants = [ "local-fs.target" ];
      before = [ "network.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        if [ -f "${caCertPath}" ] && [ -s "${caCertPath}" ]; then
          # /etc/ssl/certs is read-only (nix store). Build a merged bundle
          # in /run and bind-mount over the originals.
          for f in /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-bundle.crt; do
            target="$(readlink -f "$f")"
            runfile="/run/ssl-$(basename "$f")"
            cp "$target" "$runfile"
            cat "${caCertPath}" >> "$runfile"
            chmod 0644 "$runfile"
            ${pkgs.util-linux}/bin/mount --bind "$runfile" "$f"
          done
          echo "ca-cert-identity: added CA cert to system trust store (bind-mounted)"
        else
          echo "ca-cert-identity: no CA cert at ${caCertPath}, skipping"
        fi
      '';
    };
  };
}
