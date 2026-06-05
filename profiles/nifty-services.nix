# Nifty infrastructure services profile
#
# Runs containerized network services (NTP, mDNS, monitoring, etc.)
# on a dedicated infra VLAN, managed by podman.
#
# Usage: just create infra-services podman,nifty-services

{ config, lib, pkgs, nifty-filter, ... }:

let
  # Override via env vars at build time (--impure required):
  #   NIFTY_ROUTER_IP       — router IP on infra VLAN (default: 10.99.2.1)
  #   NIFTY_SERVICES_IP     — this VM's IP (default: 10.99.2.2)
  #   NIFTY_DOMAIN          — base domain (default: nifty.internal)
  routerIp   = let v = builtins.getEnv "NIFTY_ROUTER_IP"; in if v != "" then v else "10.99.2.1";
  servicesIp = let v = builtins.getEnv "NIFTY_SERVICES_IP"; in if v != "" then v else "10.99.2.2";
  domain     = let v = builtins.getEnv "NIFTY_DOMAIN"; in if v != "" then v else "nifty.internal";
in
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
    services.nifty-services.domain = domain;
    services.nifty-services.chrony.enable = true;
    services.nifty-services.technitium.enable = true;
    services.nifty-services.traefik.enable = true;
    services.nifty-services.ddns.enable = true;
    services.nifty-services.service-monitor.enable = true;
    services.nifty-services.service-monitor.routerUrl = "https://router.${domain}";
    services.nifty-services.service-monitor.package = nifty-filter.packages.${pkgs.stdenv.hostPlatform.system}.nifty-service-monitor;
    services.nifty-services.traefik.dashboard.enable = true;
    services.nifty-services.traefik.cert.san = [ "DNS:${domain}" "IP:${servicesIp}" ];
    # Service routing and access control is managed dynamically by the
    # service-monitor from the HCL config's services.traefik block.

    # Disable NixOS firewall — the router's nftables handles isolation
    networking.firewall.enable = lib.mkForce false;
  };
}
