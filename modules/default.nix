# Core modules - always included in all VM configurations
# Add new core modules here and they will automatically be included
{ ... }:

{
  imports = [
    ./base.nix
    ./filesystem.nix
    ./boot.nix
    ./overlay-etc.nix
    ./journald.nix
    ./immutable.nix
    ./mutable.nix
    ./nix-overlay.nix
    ./identity.nix
    ./identity-defaults.nix
    ./firewall-identity.nix
    ./dns-identity.nix
    ./hosts-identity.nix
    ./network-identity.nix
    ./root-password.nix
    ./guest-agent.nix
    ./ca-cert-identity.nix
    ./zram.nix
    ./image-version.nix
  ];
}
