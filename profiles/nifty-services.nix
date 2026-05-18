# Nifty infrastructure services profile
#
# Runs containerized network services (NTP, mDNS, monitoring, etc.)
# on a dedicated infra VLAN, managed by podman.
#
# Usage: just create infra-services podman,nifty-services

{ config, lib, pkgs, nifty-filter, ... }:

{
  imports = [ nifty-filter.nixosModules.services ];

  config = {
    boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];

    services.nifty-services.enable = true;
    services.nifty-services.chrony.enable = true;
    services.nifty-services.technitium.enable = true;
    services.nifty-services.traefik.enable = true;
    services.nifty-services.traefik.dashboard.enable = true;
    services.nifty-services.traefik.cert.san = [ "DNS:infra.lan" "IP:10.99.2.10" ];
    services.nifty-services.traefik.routers.technitium = {
      rule = "PathPrefix(`/`)";
      backend = "http://127.0.0.1:5380";
    };

    # Disable NixOS firewall — the router's nftables handles isolation
    networking.firewall.enable = false;
  };
}
