# Router profile - IP forwarding, NAT masquerade, DHCP server on internal interface
#
# Expects 2 NICs:
#   - ens3: external (NAT to host) - gets IP via DHCP
#   - ens4: internal (isolated network) - static IP 10.44.0.1, serves DHCP
#
# The router provides:
#   - IP forwarding between interfaces
#   - NAT masquerade for internal -> external traffic
#   - DHCP server on the internal interface (dnsmasq)
#   - DNS forwarding for internal clients
{ config, lib, pkgs, ... }:

{
  config = {
    # IP forwarding
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    # dnsmasq for DHCP + DNS on internal interface
    services.dnsmasq = {
      enable = true;
      settings = {
        interface = "ens4";
        bind-interfaces = true;
        dhcp-range = "10.44.0.100,10.44.0.200,255.255.255.0,12h";
        dhcp-option = [
          "option:router,10.44.0.1"
          "option:dns-server,10.44.0.1"
        ];
        server = [ "1.1.1.1" "1.0.0.1" ];
      };
    };

    # Open DHCP and DNS ports on internal interface
    networking.firewall.allowedUDPPorts = [ 67 53 ];
    networking.firewall.allowedTCPPorts = [ 53 ];

    # Trust the internal interface
    networking.firewall.trustedInterfaces = [ "ens4" ];

    # NAT masquerade: internal traffic exits via external interface
    networking.nat = {
      enable = true;
      internalInterfaces = [ "ens4" ];
      externalInterface = "ens3";
    };

    # Static IP on the internal interface
    systemd.network.networks."10-internal" = {
      matchConfig.Name = "ens4";
      networkConfig = {
        Address = "10.44.0.1/24";
        IPv6AcceptRA = false;
      };
      linkConfig.RequiredForOnline = "no";
    };

    # Restrict the default DHCP catch-all to external NIC only
    systemd.network.networks."99-ethernet-default-dhcp" = {
      matchConfig = lib.mkForce {
        Name = "ens3";
      };
    };
  };
}
