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
          mkdir -p /etc/ssl/certs
          # Append the CA cert to the system bundle
          if ! grep -qf "${caCertPath}" /etc/ssl/certs/ca-certificates.crt 2>/dev/null; then
            cat "${caCertPath}" >> /etc/ssl/certs/ca-certificates.crt
            cat "${caCertPath}" >> /etc/ssl/certs/ca-bundle.crt
            echo "ca-cert-identity: added CA cert to system trust store"
          else
            echo "ca-cert-identity: CA cert already in trust store"
          fi
        else
          echo "ca-cert-identity: no CA cert at ${caCertPath}, skipping"
        fi
      '';
    };
  };
}
