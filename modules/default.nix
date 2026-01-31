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
    ./identity.nix
    ./firewall-identity.nix
    ./dns-identity.nix
    ./hosts-identity.nix
    ./root-password.nix
    ./guest-agent.nix
    ./zram.nix
  ];
}
