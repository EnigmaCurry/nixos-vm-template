{ config, lib, pkgs, ... }:

{
  # Immutable-mode specific configuration
  config = lib.mkIf (!config.vm.mutable) {
    # Disable services that don't work with read-only root/boot

    # Disable filesystem growth (root is read-only and fixed size)
    systemd.services.growpart.enable = false;
    systemd.services."systemd-growfs-root".enable = false;

    # Disable boot random seed update (boot partition is read-only)
    systemd.services."systemd-boot-random-seed".enable = false;

    # Use systemd-networkd instead of dhcpcd (works better with immutable /etc)
    networking.useDHCP = false;
    networking.useNetworkd = true;
    systemd.network.enable = true;

    # Allow DHCP responses through the firewall (normally added automatically
    # by networking.useDHCP, but we use systemd-networkd directly)
    networking.firewall.allowedUDPPorts = [ 68 ];

    # Enable DHCP on all interfaces via systemd-networkd
    systemd.network.networks."99-ethernet-default-dhcp" = {
      matchConfig.Type = "ether";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };

    # Use systemd-resolved for DNS (works with immutable /etc)
    services.resolved.enable = true;

    # Keep nscd enabled (required for NSS modules like systemd-resolved)
    services.nscd.enable = true;
  };
}
