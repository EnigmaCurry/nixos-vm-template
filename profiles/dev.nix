# Development profile - includes development tools
{ config, lib, pkgs, ... }:

{
  # Enable zram compressed swap
  vm.zram.enable = true;
  vm.zram.memoryPercent = 50;

  # Import core profile (base + ssh), docker, rust, and python
  imports = [
    ./core.nix
    ./docker-dev.nix
    ./rust.nix
    ./python.nix
  ];

  # Additional development packages
  environment.systemPackages = with pkgs; [
    # Editors
    neovim

    # Shell utilities
    tmux
    ripgrep
    fd
    jq
    tree

    # Development tools
    gnumake

    # Network tools
    wget
    netcat
  ];
}
