{
  description = "NixOS Immutable VM Image Builder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, ... }:
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
        ./modules/root-password.nix
      ];

      # Available profiles (each adds packages on top of core modules)
      profiles = [ "base" "core" "docker" "dev" "claude" "open-code" ];

      # Build a VM image for a given system and profile
      mkProfileImage = system: profile:
        nixos-generators.nixosGenerate {
          inherit system;
          format = "qcow";
          modules = coreModules ++ [
            ./profiles/${profile}.nix
            { nixpkgs.hostPlatform = system; }
          ];
        };

      # Build a NixOS configuration for testing/debugging
      mkNixosConfig = system: profile:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = coreModules ++ [
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
