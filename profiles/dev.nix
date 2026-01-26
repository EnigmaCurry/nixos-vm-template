# Development profile - includes development tools
{ config, lib, pkgs, ... }:

{
  # Enable zram compressed swap
  vm.zram.enable = true;
  vm.zram.memoryPercent = 50;

  # Import core profile (base + ssh), docker, podman, rust, and python
  imports = [
    ./core.nix
    ./docker-dev.nix
    ./podman-dev.nix
    ./rust.nix
    ./python.nix
  ];

  # Additional development packages
  environment.systemPackages = with pkgs; [
    # Editors
    neovim

    # Shell utilities
    bashInteractive
    tmux
    ripgrep
    fd
    jq
    tree
    gettext
    moreutils
    inotify-tools
    w3m

    # Development tools
    gnumake
    openssl
    xdg-utils

    # Network tools
    wget
    netcat
    sshfs
    wireguard-tools
    ipcalc
    apacheHttpd  # htpasswd, ab, etc.

    # VM tools
    qemu
    libguestfs-with-appliance
  ];
}
