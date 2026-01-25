# Base profile - minimal packages and firewall
{ config, lib, pkgs, ... }:

{
  # Create /bin/bash symlink during image build (for scripts with #!/bin/bash)
  system.activationScripts.binbash = lib.stringAfter [ "binsh" ] ''
    ln -sfn ${pkgs.bashInteractive}/bin/bash /bin/bash
  '';

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
