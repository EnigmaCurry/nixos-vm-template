# Step-CA private PKI profile
#
# Runs Smallstep Step-CA on a dedicated VM for certificate authority services.
# Deploy first, before the router or infra-services VMs.
# No registry pull needed — the container image is built by Nix.
#
# Usage: just create infra-CA podman,step-ca

{ config, lib, pkgs, nifty-filter, ... }:

{
  imports = [ nifty-filter.nixosModules.step-ca ];

  config = {
    boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];

    services.nifty-step-ca.enable = true;
    services.nifty-step-ca.dnsNames = [ "localhost" "127.0.0.1" "10.99.2.3" ];

    # Disable NixOS firewall — the router's nftables handles isolation.
    # Step-CA port (9443) is opened by the module when the host firewall is active.
    networking.firewall.enable = lib.mkForce false;
  };
}
