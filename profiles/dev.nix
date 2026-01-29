# Development profile - includes development tools and home-manager
{ config, lib, pkgs, sway-home, swayHomeInputs, nix-flatpak, ... }:

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

  # Home-manager configuration using sway-home modules
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;

    # Pass inputs that sway-home modules expect
    extraSpecialArgs = {
      inputs = swayHomeInputs;
      userName = config.core.regularUser;
    };

    # Configure home-manager for the regular user
    users.${config.core.regularUser} = { pkgs, ... }: {
      imports = [
        nix-flatpak.homeManagerModules.nix-flatpak
        sway-home.homeModules.home
        sway-home.homeModules.emacs
        sway-home.homeModules.rust
      ];

      # Let home-manager manage itself
      programs.home-manager.enable = true;
    };
  };
}
