# Step-CA private PKI profile
#
# Runs Smallstep Step-CA on a dedicated VM for certificate authority services.
# Deploy first, before the router or infra-services VMs.
# No registry pull needed — the container image is built by Nix.
#
# Usage: just create infra-CA podman,step-ca

{ config, lib, pkgs, nifty-filter, ... }:

let
  # Override via env vars at build time (--impure required):
  #   NIFTY_STEP_CA_IP      — this VM's IP (default: 10.99.2.3)
  #   NIFTY_ROUTER_IP       — router IP on infra VLAN (default: 10.99.2.1)
  #   NIFTY_DOMAIN          — base domain (default: nifty.internal)
  stepCaIp = let v = builtins.getEnv "NIFTY_STEP_CA_IP"; in if v != "" then v else "10.99.2.3";
  routerIp = let v = builtins.getEnv "NIFTY_ROUTER_IP"; in if v != "" then v else "10.99.2.1";
  domain   = let v = builtins.getEnv "NIFTY_DOMAIN"; in if v != "" then v else "nifty.internal";
in
{
  imports = [ nifty-filter.nixosModules.step-ca ];

  config = {
    boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];

    services.nifty-step-ca.enable = true;
    services.nifty-step-ca.dnsNames = [ "localhost" "127.0.0.1" stepCaIp ];
    services.nifty-step-ca.domain = domain;

    # Disable NixOS firewall — the router's nftables handles isolation.
    # Step-CA port (9443) is opened by the module when the host firewall is active.
    networking.firewall.enable = lib.mkForce false;
  };
}
