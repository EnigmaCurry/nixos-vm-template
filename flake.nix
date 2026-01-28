{
  description = "NixOS Immutable VM Image Builder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sway-home = {
      url = "github:EnigmaCurry/sway-home?dir=home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-flatpak.url = "github:gmodena/nix-flatpak";
  };

  outputs = { self, nixpkgs, nixos-generators, home-manager, sway-home, nix-flatpak, ... }@inputs:
    let
      # Systems we support
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Core modules (always included)
      coreModules = [
        ./modules/base.nix
        ./modules/filesystem.nix
        ./modules/boot.nix
        ./modules/overlay-etc.nix
        ./modules/journald.nix
        ./modules/immutable.nix
        ./modules/identity.nix
        ./modules/firewall-identity.nix
        ./modules/dns-identity.nix
        ./modules/hosts-identity.nix
        ./modules/root-password.nix
        ./modules/guest-agent.nix
        ./modules/zram.nix
      ];

      # Available profiles (each adds packages on top of core modules)
      profiles = [ "base" "core" "nix" "docker" "docker-nvidia" "dev" "dev-nvidia" "dev-nix" "claude" "claude-nvidia" "claude-nix" "open-code" "open-code-nvidia" "open-code-nix" ];

      # Build a VM image for a given system and profile
      mkProfileImage = system: profile:
        nixos-generators.nixosGenerate {
          inherit system;
          format = "qcow";
          specialArgs = {
            inherit sway-home nix-flatpak;
            swayHomeInputs = sway-home.inputs;
          };
          modules = coreModules ++ [
            home-manager.nixosModules.home-manager
            ./profiles/${profile}.nix
            { nixpkgs.hostPlatform = system; }
          ];
        };

      # Build a NixOS configuration for testing/debugging
      mkNixosConfig = system: profile:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit sway-home nix-flatpak;
            swayHomeInputs = sway-home.inputs;
          };
          modules = coreModules ++ [
            home-manager.nixosModules.home-manager
            ./profiles/${profile}.nix
            { nixpkgs.hostPlatform = system; }
          ];
        };

    in
    {
      # Profile images for each supported system
      # Access as: nix build .#base or .#dev
      packages = forAllSystems (system:
        builtins.listToAttrs (
          map (profile: {
            name = profile;
            value = mkProfileImage system profile;
          }) profiles
        ) // {
          default = mkProfileImage system "core";
        }
      );

      # NixOS configurations (for nixos-rebuild, testing)
      nixosConfigurations = builtins.listToAttrs (
        builtins.concatMap (system:
          map (profile: {
            name = "${profile}-${system}";
            value = mkNixosConfig system profile;
          }) profiles
        ) supportedSystems
      );

      # Development shell with useful tools
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              just
              qemu
              libvirt
              libguestfs-with-appliance
              virt-manager
              mkpasswd  # For generating password hashes
            ];
          };
        }
      );
    };
}
