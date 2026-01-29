# Home-manager profile - configures home-manager for the regular user
# Uses sway-home modules for a complete terminal/editor environment
# Requires writable /nix for activation, so imports the nix overlay
{ config, lib, pkgs, sway-home, swayHomeInputs, nix-flatpak, ... }:

{
  imports = [
    ./nix.nix
  ];

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
