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

    environment.systemPackages = with pkgs; [
      tcpdump
      nftables
      dig
    ];

    # Technitium manages DNS — disable the default systemd-resolved setup
    vm.dnsIdentity = false;

    services.nifty-services.enable = true;
    services.nifty-services.chrony.enable = true;
    services.nifty-services.technitium.enable = true;
    services.nifty-services.traefik.enable = true;
    services.nifty-services.service-monitor.enable = true;
    services.nifty-services.service-monitor.routerUrl = "https://10.99.2.1:3000";
    services.nifty-services.service-monitor.package = nifty-filter.packages.${pkgs.stdenv.hostPlatform.system}.nifty-service-monitor;
    services.nifty-services.traefik.dashboard.enable = true;
    services.nifty-services.traefik.cert.san = [ "DNS:infra.lan" "IP:10.99.2.10" ];
    # VLAN subnets must match your nifty-filter HCL config
    services.nifty-services.traefik.vlans = {
      infra   = "10.99.2.0/24";
      trusted = "10.99.10.0/24";
      iot     = "10.99.20.0/24";
      guest   = "10.99.30.0/24";
      lab     = "10.99.40.0/24";
    };
    services.nifty-services.traefik.routers.technitium = {
      rule = "PathPrefix(`/`)";
      backend = "http://127.0.0.1:5380";
      allowVlans = [ "infra" "trusted" ];
    };

    # Disable NixOS firewall — the router's nftables handles isolation
    networking.firewall.enable = lib.mkForce false;
  };
}
