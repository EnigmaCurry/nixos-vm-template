# Development profile - includes development tools
{ config, lib, pkgs, ... }:

{
  # Import nix profile (core + mutable /nix), docker, rust, and python
  imports = [
    ./nix.nix
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
