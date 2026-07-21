{
  description = "NixOS Immutable VM Image Builder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sway-home = {
      url = "github:EnigmaCurry/sway-home?dir=home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-flatpak.url = "github:gmodena/nix-flatpak";
    opencode = {
      # Pinned to a stable release tag. Bump manually after verifying upstream builds.
      url = "github:AnomalyCo/opencode/v1.4.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nifty-filter = {
      url = "github:EnigmaCurry/nifty-filter/dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Pinned to v0.3.2 — the pod is loaded via a local binary path (see
    # src/vm/prompt.clj) because babashka.pods doesn't support :url and
    # this version isn't in the babashka pod-registry yet.
    script-wizard = {
      url = "github:EnigmaCurry/script-wizard/v0.3.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, sway-home, nix-flatpak, opencode, nifty-filter, script-wizard, ... }@inputs:
    let
      lib = nixpkgs.lib;

      # Systems we support
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;

      # Core modules (always included) - see modules/default.nix for the list
      coreModules = [ ./modules ];

      # Available composable profiles (mixin-style, no inheritance)
      # core is always implicitly included via coreModules
      availableProfiles = [ "core" "docker" "podman" "nvidia" "pipewire" "python" "rust" "dev" "home-manager" "claude" "open-code" "nifty-services" "step-ca" "woodpecker" "moonshine-nvidia" "sunshine-plasma-nvidia" "samba-mount" "semi-mutable" "mutable" ];

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
      # Uses native nixpkgs image building (qemu-efi format)
      # Image version string baked into every built image
      imageVersion = let
        # self.shortRev is only populated for git/clean-tree flake refs. The
        # image build evaluates this flake via `getFlake <bare-path>` (to include
        # the full working tree), which drops git metadata, so fall back to the
        # IMAGE_COMMIT env var (set by the image build in vm.profile, read here under --impure).
        envRev = builtins.getEnv "IMAGE_COMMIT";
        rev = self.shortRev or self.dirtyShortRev or
              (if envRev != "" then envRev else "unknown");
        date = self.lastModifiedDate or "unknown";
        # Format: YYYYMMDD from the raw date string (e.g. "20260615120000")
        dateShort = builtins.substring 0 8 date;
      in builtins.concatStringsSep "\n" [
        "repo=github:EnigmaCurry/nixos-vm-template"
        "commit=${rev}"
        "date=${dateShort}"
        ""
      ];

      mkCombinedImage = system: profileList: { mutable ? false, nixOverlay ? false }:
        let
          # Always include core, sort for canonical naming, dedupe
          allProfiles = lib.unique (lib.sort lib.lessThan ([ "core" ] ++ profileList));
          profileModules = map (p: ./profiles/${p}.nix) allProfiles;

          nixosConfig = nixpkgs.lib.nixosSystem {
            specialArgs = {
              inherit sway-home nix-flatpak opencode nifty-filter imageVersion;
              swayHomeInputs = sway-home.inputs;
            };
            modules = coreModules ++ [
              # Native nixpkgs disk image module (replaces nixos-generators)
              "${nixpkgs}/nixos/modules/virtualisation/disk-image.nix"
              home-manager.nixosModules.home-manager
            ] ++ profileModules ++ [
              { nixpkgs.hostPlatform = system; }
              { vm.mutable = lib.mkDefault mutable; vm.nixOverlay = lib.mkDefault nixOverlay; }
              # Configure image format (qcow2 with EFI/systemd-boot)
              {
                image.baseName = "nixos";
                image.format = "qcow2";
                image.efiSupport = true;
              }
            ];
          };
        in
        nixosConfig.config.system.build.image;

      # Build a VM image for a given system and single profile (legacy compatibility)
      mkProfileImage = system: profile:
        mkCombinedImage system [ profile ] { mutable = false; };

      # proxmox-lxc backend: build a NixOS LXC template tarball for a list of
      # profiles. Parallel to mkCombinedImage, but: imports nixpkgs' proxmox-lxc
      # module, sets vm.container (which guards off boot.nix/disks/initrd) and
      # vm.mutable (an LXC rootfs is read-write; nixos-rebuild runs inside), and
      # outputs config.system.build.tarball (a tar.xz for `pct create`). Container
      # networking matches the validated spike: systemd-networkd DHCP on eth0.
      lxcProfiles = [ "core" "docker" "nas" ];
      mkLxcImage = system: profileList:
        let
          allProfiles = lib.unique (lib.sort lib.lessThan ([ "core" ] ++ profileList));
          profileModules = map (p: ./profiles/${p}.nix) allProfiles;
          # The nas profile needs a privileged container (kernel nfsd). The
          # host-side `pct --unprivileged 0` is set by the backend from the
          # machine's `privileged` field; this aligns the in-guest config.
          privileged = builtins.elem "nas" allProfiles;
        in
        (nixpkgs.lib.nixosSystem {
          specialArgs = {
            inherit sway-home nix-flatpak opencode nifty-filter imageVersion;
            swayHomeInputs = sway-home.inputs;
          };
          modules = coreModules ++ [
            "${nixpkgs}/nixos/modules/virtualisation/proxmox-lxc.nix"
            home-manager.nixosModules.home-manager
          ] ++ profileModules ++ [
            { nixpkgs.hostPlatform = system; }
            {
              vm.mutable = true;
              vm.container = true;
              # We own networking (paired with `pct create --ostype unmanaged`).
              proxmoxLXC = { privileged = lib.mkDefault privileged; manageNetwork = true; manageHostName = true; };
              networking.useDHCP = lib.mkForce false;
              networking.useNetworkd = lib.mkForce true;
              networking.useHostResolvConf = lib.mkForce false;
              systemd.network.enable = lib.mkForce true;
              systemd.network.networks."10-eth0" = {
                matchConfig.Name = "eth0";
                networkConfig.DHCP = "yes";
              };
              systemd.network.wait-online.enable = false;
              services.resolved.enable = true;
            }
          ];
        }).config.system.build.tarball;

      # Build a NixOS configuration for testing/debugging/rebuilding
      # mutable: if true, configures as a mutable system (for nixos-rebuild on mutable VMs)
      mkNixosConfig = system: profile: { mutable ? false, nixOverlay ? false }:
        nixpkgs.lib.nixosSystem {
          specialArgs = {
            inherit sway-home nix-flatpak opencode nifty-filter imageVersion;
            swayHomeInputs = sway-home.inputs;
          };
          modules = coreModules ++ [
            home-manager.nixosModules.home-manager
            ./profiles/${profile}.nix
            { nixpkgs.hostPlatform = system; }
            { vm.mutable = lib.mkDefault mutable; vm.nixOverlay = lib.mkDefault nixOverlay; }
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
        )
        // builtins.listToAttrs (
          # proxmox-lxc rootfs tarballs: nix build .#lxc-core / .#lxc-nas / .#lxc-docker
          map (profile: {
            name = "lxc-${profile}";
            value = mkLxcImage system [ profile ];
          }) lxcProfiles
        )
        // {
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
          # Semi-mutable configurations (read-only root + writable /nix overlay)
          (map (profile: {
            name = "${profile}-semi-mutable-${system}";
            value = mkNixosConfig system profile { nixOverlay = true; };
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
        inherit mkCombinedImage mkLxcImage availableProfiles lxcProfiles commonCombinations;
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
              babashka  # bb - runs the VM-management CLI (src/vm/)
              qemu
              libvirt
              libguestfs-with-appliance
              virt-manager
              mkpasswd  # For generating password hashes
              script-wizard.packages.${system}.default  # bb pod for wizard prompts
            ];
          };
        }
      );
    };
}
