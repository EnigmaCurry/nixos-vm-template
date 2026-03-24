# DNS identity module - configures DNS from /var/identity using systemd-resolved
#
# This module:
# 1. Bakes /etc/resolv.conf pointing to resolved's stub listener (127.0.0.53)
#    (NixOS normally creates this as a symlink, but that fails on read-only root)
# 2. Enables systemd-resolved stub listener on 127.0.0.1 and ::1
# 3. Configures custom DNS servers from /var/identity/resolv.conf via
#    a resolved drop-in config in /run/systemd/resolved.conf.d/
{ config, lib, pkgs, ... }:

let
  resolvConf = pkgs.writeText "resolv.conf" ''
# This VM uses systemd-resolved for DNS.
# 127.0.0.53 is the local stub listener, not the actual upstream DNS.
# To see the real upstream DNS servers: resolvectl status
nameserver 127.0.0.53
options edns0 trust-ad
'';
in
{
  # Immutable-mode DNS identity configuration
  config = lib.mkIf (!config.vm.mutable) {
    # Enable systemd-resolved with listeners on 127.0.0.1 and ::1
    # (in addition to the default 127.0.0.53)
    services.resolved.enable = true;
    services.resolved.settings.Resolve.DNSStubListenerExtra = [ "127.0.0.1" "::1" ];

    # Bake /etc/resolv.conf into the image during build.
    # NixOS resolved sets environment.etc."resolv.conf".source to a runtime path
    # (/run/systemd/resolve/stub-resolv.conf) which doesn't exist at build time,
    # so the activation script can't create the /etc/resolv.conf symlink.
    # On read-only root this means /etc/resolv.conf is missing entirely.
    # Fix: use an activation script to write the file directly into /etc/ during
    # image build (same pattern as /bin/bash in core.nix).
    environment.etc."resolv.conf" = lib.mkForce {
      source = resolvConf;
      mode = "0644";
    };

    system.activationScripts.resolvConf = lib.stringAfter [ "etc" ] ''
      if [ ! -e /etc/resolv.conf ]; then
        cp ${resolvConf} /etc/resolv.conf
        chmod 0644 /etc/resolv.conf
      fi
    '';

    # Service to configure custom DNS from /var/identity
    systemd.services.dns-identity = {
      description = "Configure custom DNS from /var/identity";
      wantedBy = [ "multi-user.target" ];
      after = [ "var.mount" "systemd-resolved.service" ];
      wants = [ "systemd-resolved.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        # Configure custom DNS via resolved drop-in if identity file exists
        if [ -f /var/identity/resolv.conf ]; then
          nameservers=""
          while read -r line; do
            case "$line" in
              nameserver\ *)
                ns="''${line#nameserver }"
                nameservers="$nameservers $ns"
                ;;
            esac
          done < /var/identity/resolv.conf
          nameservers="''${nameservers# }"  # trim leading space

          if [ -n "$nameservers" ]; then
            echo "Setting DNS: $nameservers"
            mkdir -p /run/systemd/resolved.conf.d
            printf '[Resolve]\nDNS=%s\n' "$nameservers" > /run/systemd/resolved.conf.d/identity.conf
            ${pkgs.systemd}/bin/systemctl restart systemd-resolved
          fi
        else
          echo "Using default DNS from DHCP/resolved"
        fi
      '';
    };
  };
}
