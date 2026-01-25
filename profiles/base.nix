# Base profile - minimal packages and firewall
{ config, lib, pkgs, ... }:

{
  # Minimal packages for all VMs
  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
    git
    duf
    ripgrep
    jq
    dig
    just
    pciutils
    parted
  ];

  # Enable firewall - blocks all incoming by default
  networking.firewall.enable = true;
}
