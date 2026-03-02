# Network identity module - configures static IP from /var/identity/static_ip
#
# For immutable VMs (systemd-networkd):
#   Writes a high-priority .network file to /run/systemd/network/ that overrides
#   the default DHCP config (99-ethernet-default-dhcp from immutable.nix).
#
# For mutable VMs (dhcpcd):
#   Stops dhcpcd and applies static IP using ip addr/route commands.
#
# File format (key=value):
#   address=10.56.0.5/24
#   gateway=10.56.0.1
{ config, lib, pkgs, ... }:

{
  config = lib.mkMerge [
    # Immutable mode: write a systemd-networkd .network file to /run
    (lib.mkIf (!config.vm.mutable) {
      systemd.services.network-identity = {
        description = "Configure static IP from /var/identity/static_ip";
        wantedBy = [ "multi-user.target" ];
        before = [ "systemd-networkd.service" ];
        after = [ "var.mount" ];
        requires = [ "var.mount" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          if [ -f /var/identity/static_ip ]; then
            address=""
            gateway=""
            while IFS='=' read -r key value; do
              case "$key" in
                address) address="$value" ;;
                gateway) gateway="$value" ;;
              esac
            done < /var/identity/static_ip

            if [ -n "$address" ]; then
              echo "Configuring static IP: $address (gateway: $gateway)"
              mkdir -p /run/systemd/network
              {
                echo "[Match]"
                echo "Type=ether"
                echo ""
                echo "[Network]"
                echo "Address=$address"
                if [ -n "$gateway" ]; then
                  echo "Gateway=$gateway"
                fi
                echo "IPv6AcceptRA=false"
              } > /run/systemd/network/10-static.network
              echo "Static network config written to /run/systemd/network/10-static.network"
            else
              echo "No address found in /var/identity/static_ip, using DHCP"
            fi
          else
            echo "No static IP configured, using DHCP"
          fi
        '';
      };
    })

    # Mutable mode: stop dhcpcd and apply static IP via ip commands
    (lib.mkIf config.vm.mutable {
      systemd.services.static-ip = {
        description = "Apply static IP from /etc/network-config/static_ip";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          if [ -f /etc/network-config/static_ip ]; then
            address=""
            gateway=""
            while IFS='=' read -r key value; do
              case "$key" in
                address) address="$value" ;;
                gateway) gateway="$value" ;;
              esac
            done < /etc/network-config/static_ip

            if [ -n "$address" ]; then
              echo "Applying static IP: $address (gateway: $gateway)"

              # Stop dhcpcd to prevent it from overriding our config
              ${pkgs.systemd}/bin/systemctl stop dhcpcd.service 2>/dev/null || true

              # Find the first non-loopback ethernet interface
              iface=""
              for dev in /sys/class/net/*/type; do
                devtype=$(cat "$dev" 2>/dev/null)
                devname=$(basename "$(dirname "$dev")")
                if [ "$devtype" = "1" ] && [ "$devname" != "lo" ]; then
                  iface="$devname"
                  break
                fi
              done

              if [ -z "$iface" ]; then
                echo "Error: No ethernet interface found"
                exit 1
              fi

              echo "Using interface: $iface"

              # Flush existing addresses and add static IP
              ${pkgs.iproute2}/bin/ip addr flush dev "$iface"
              ${pkgs.iproute2}/bin/ip addr add "$address" dev "$iface"
              ${pkgs.iproute2}/bin/ip link set "$iface" up

              if [ -n "$gateway" ]; then
                ${pkgs.iproute2}/bin/ip route add default via "$gateway" dev "$iface" 2>/dev/null || true
              fi

              # Configure DNS from /etc/network-config/resolv.conf
              # Use resolvconf to register DNS servers (it manages /etc/resolv.conf)
              if [ -f /etc/network-config/resolv.conf ]; then
                cat /etc/network-config/resolv.conf | ${pkgs.openresolv}/bin/resolvconf -a "$iface.static" -m 0
                echo "DNS configured via resolvconf from /etc/network-config/resolv.conf"
              fi

              echo "Static IP applied on $iface"
            else
              echo "No address found in /etc/network-config/static_ip"
            fi
          fi
        '';
      };
    })
  ];
}
