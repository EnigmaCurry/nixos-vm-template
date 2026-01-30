# DNS identity module - configures DNS from /var/identity using systemd-resolved
#
# This module:
# 1. Enables systemd-resolved stub listener on 127.0.0.53 and ::1
# 2. Redirects 127.0.0.1:53 to 127.0.0.53:53 for apps that hardcode localhost DNS
# 3. Configures custom DNS servers from /var/identity/resolv.conf
#
# Note: /etc/resolv.conf cannot be bind-mounted due to NixOS special handling.
# Apps using glibc resolver work via nsswitch -> resolved.
# Apps hardcoding 127.0.0.1:53 or ::1:53 work via iptables/resolved listener.
{ config, lib, pkgs, ... }:

{
  # Immutable-mode DNS identity configuration
  config = lib.mkIf (!config.vm.mutable) {
    # Enable systemd-resolved with listeners on 127.0.0.1 and ::1
    # (in addition to the default 127.0.0.53)
    services.resolved.enable = true;
    services.resolved.settings.Resolve.DNSStubListenerExtra = [ "127.0.0.1" "::1" ];

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
            echo "Setting DNS from /var/identity/resolv.conf: $nameservers"
            # Apply DNS to all managed non-loopback interfaces
            configured=false
            for iface in $(${pkgs.systemd}/bin/networkctl list --no-legend | awk '{print $2}' | grep -v '^lo$'); do
              if ${pkgs.systemd}/bin/resolvectl dns "$iface" $nameservers 2>/dev/null; then
                echo "DNS configured on $iface"
                configured=true
              fi
            done
            if [ "$configured" = false ]; then
              echo "Warning: Could not set custom DNS on any interface"
            fi
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
