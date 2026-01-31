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
      lib = nixpkgs.lib;

      # Systems we support
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;

      # Core modules (always included) - see modules/default.nix for the list
      coreModules = [ ./modules ];

      # Available composable profiles (mixin-style, no inheritance)
      # core is always implicitly included via coreModules
      availableProfiles = [ "core" "docker" "podman" "nvidia" "python" "rust" "nix" "dev" "home-manager" "claude" "open-code" ];

      # Common profile combinations (convenience shortcuts)
      # These are pre-defined combinations that users commonly need
      commonCombinations = {
        # Single profiles (for backwards compatibility and convenience)
        "core" = [ "core" ];
        "docker" = [ "core" "docker" ];
        "podman" = [ "core" "podman" ];
        "dev" = [ "core" "docker" "podman" "rust" "python" "dev" "home-manager" ];
        "claude" = [ "core" "docker" "podman" "rust" "python" "dev" "home-manager" "claude" ];
        "open-code" = [ "core" "docker" "podman" "rust" "python" "dev" "home-manager" "open-code" ];
      };

      # Build a combined VM image for a given system and list of profiles
      # mutable: if true, builds a standard read-write NixOS system
      mkCombinedImage = system: profileList: { mutable ? false }:
        let
          # Always include core, sort for canonical naming, dedupe
          allProfiles = lib.unique (lib.sort lib.lessThan ([ "core" ] ++ profileList));
          profileModules = map (p: ./profiles/${p}.nix) allProfiles;
        in
        nixos-generators.nixosGenerate {
          inherit system;
          format = "qcow";
          specialArgs = {
            inherit sway-home nix-flatpak;
            swayHomeInputs = sway-home.inputs;
            vmModulesPath = ./modules;
            vmProfilesPath = ./profiles;
          };
          modules = coreModules ++ [
            home-manager.nixosModules.home-manager
          ] ++ profileModules ++ [
            { nixpkgs.hostPlatform = system; }
            { vm.mutable = mutable; }
          ];
        };

      # Build a VM image for a given system and single profile (legacy compatibility)
      mkProfileImage = system: profile:
        mkCombinedImage system [ profile ] { mutable = false; };

      # Build a NixOS configuration for testing/debugging/rebuilding
      # mutable: if true, configures as a mutable system (for nixos-rebuild on mutable VMs)
      mkNixosConfig = system: profile: { mutable ? false }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit sway-home nix-flatpak;
            swayHomeInputs = sway-home.inputs;
            vmModulesPath = ./modules;
            vmProfilesPath = ./profiles;
          };
          modules = coreModules ++ [
            home-manager.nixosModules.home-manager
            ./profiles/${profile}.nix
            { nixpkgs.hostPlatform = system; }
            { vm.mutable = mutable; }
          ];
        };

    in
    {
      # Profile images for each supported system
      # Access as: nix build .#core or .#docker
      packages = forAllSystems (system:
        builtins.listToAttrs (
          map (profile: {
            name = profile;
            value = mkProfileImage system profile;
          }) availableProfiles
        ) // {
          default = mkProfileImage system "core";
        }
      );

      # NixOS configurations (for nixos-rebuild, testing)
      # Includes both immutable (default) and mutable variants
      # Mutable configs are named: <profile>-mutable-<system>
      nixosConfigurations = builtins.listToAttrs (
        builtins.concatMap (system:
          # Immutable configurations
          (map (profile: {
            name = "${profile}-${system}";
            value = mkNixosConfig system profile { mutable = false; };
          }) availableProfiles)
          ++
          # Mutable configurations (for nixos-rebuild on mutable VMs)
          (map (profile: {
            name = "${profile}-mutable-${system}";
            value = mkNixosConfig system profile { mutable = true; };
          }) availableProfiles)
        ) supportedSystems
      );

      # Expose lib functions for backend scripts to build dynamic combinations
      lib = {
        inherit mkCombinedImage availableProfiles commonCombinations;
      };

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
