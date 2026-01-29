# Development profile - includes development tools
{ config, lib, pkgs, ... }:

{
  # Enable zram compressed swap
  vm.zram.enable = true;
  vm.zram.memoryPercent = 50;

  # Development packages
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
    asciinema

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
    libguestfs
    libguestfs-with-appliance
  ];
}
