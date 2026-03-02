# DNS identity module - configures DNS from /var/identity using systemd-resolved
#
# This module:
# 1. Bakes /etc/resolv.conf pointing to resolved's stub listener (127.0.0.53)
#    (NixOS normally creates this as a symlink, but that fails on read-only root)
# 2. Enables systemd-resolved stub listener on 127.0.0.1 and ::1
# 3. Configures custom DNS servers from /var/identity/resolv.conf via
#    a resolved drop-in config in /run/systemd/resolved.conf.d/
{ config, lib, pkgs, ... }:

{
  # Immutable-mode DNS identity configuration
  config = lib.mkIf (!config.vm.mutable) {
    # Enable systemd-resolved with listeners on 127.0.0.1 and ::1
    # (in addition to the default 127.0.0.53)
    services.resolved.enable = true;
    services.resolved.settings.Resolve.DNSStubListenerExtra = [ "127.0.0.1" "::1" ];

    # Create /etc/resolv.conf placeholder pointing to resolved's stub listener.
    # NixOS normally creates this as a symlink during activation, but on read-only
    # root the symlink can't be created. We use the placeholder + bind mount pattern.
    environment.etc."resolv.conf" = lib.mkForce {
      text = "nameserver 127.0.0.53\noptions edns0 trust-ad\n";
      mode = "0644";
    };

    # Bind mount resolv.conf from /etc/static (where environment.etc puts it)
    fileSystems."/etc/resolv.conf" = {
      device = "/etc/static/resolv.conf";
      options = [ "bind" ];
    };

    # Service to configure custom DNS from /var/identity
    systemd.services.dns-identity = {
      description = "Configure DNS from /var/identity";
      wantedBy = [ "multi-user.target" ];
      after = [ "var.mount" "systemd-resolved.service" ];
      requires = [ "systemd-resolved.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        # Configure custom DNS from /var/identity if present
        if [ -f /var/identity/resolv.conf ]; then
          # Extract nameservers (avoid pipeline to prevent broken pipe errors)
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
            # Write a resolved drop-in config and restart resolved to pick it up
            mkdir -p /run/systemd/resolved.conf.d
            printf '[Resolve]\nDNS=%s\n' "$nameservers" > /run/systemd/resolved.conf.d/identity.conf
            ${pkgs.systemd}/bin/systemctl restart systemd-resolved
          else
            echo "No nameservers found in /var/identity/resolv.conf"
          fi
        else
          echo "Using default DNS from DHCP/resolved"
        fi
      '';
    };
  };
}
