# Home-manager profile - configures home-manager for the regular user
# Uses sway-home modules for a complete terminal/editor environment
# Requires writable /nix for activation, so imports the nix overlay
{ config, lib, pkgs, sway-home, swayHomeInputs, nix-flatpak, ... }:

let
  regularUser = config.core.regularUser;
in
{
  imports = [
    ./nix.nix
  ];

  # The standard home-manager activation fails because nix-store commands
  # don't work with our overlay setup (store paths aren't in the nix database).
  # This service creates the symlinks directly before home-manager runs.
  systemd.services."home-manager-symlinks-${regularUser}" = {
    description = "Create home-manager symlinks for ${regularUser}";
    wantedBy = [ "multi-user.target" ];
    before = [ "home-manager-${regularUser}.service" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = regularUser;
    };
    script = ''
      set -euo pipefail
      cd "$HOME"

      # Find the home-manager generation for this user
      generation=$(find /nix/store -maxdepth 1 -name '*-home-manager-generation' -type d 2>/dev/null | head -1)
      if [[ -z "$generation" || ! -d "$generation" ]]; then
        echo "No home-manager generation found, skipping"
        exit 0
      fi

      # Get the home-files path from the generation
      if [[ ! -L "$generation/home-files" ]]; then
        echo "No home-files symlink in generation, skipping"
        exit 0
      fi
      home_files=$(readlink "$generation/home-files")

      if [[ ! -d "$home_files" ]]; then
        echo "home-files path does not exist: $home_files"
        exit 0
      fi

      echo "Creating home-manager symlinks from $home_files"

      # Create symlinks for each file in home-files
      for f in "$home_files"/.* "$home_files"/*; do
        name=$(basename "$f")
        [[ "$name" == "." || "$name" == ".." ]] && continue

        # Remove existing symlink if it points to wrong location
        if [[ -L "$HOME/$name" ]]; then
          current_target=$(readlink "$HOME/$name")
          if [[ "$current_target" != "$f" ]]; then
            rm -f "$HOME/$name"
          fi
        fi

        # Create symlink if it doesn't exist
        if [[ ! -e "$HOME/$name" && ! -L "$HOME/$name" ]]; then
          ln -sfn "$f" "$HOME/$name"
          echo "  Created: $name -> $f"
        fi
      done

      # Set up .nix-profile to point to home-manager-path (contains the packages)
      if [[ -L "$generation/home-path" ]]; then
        home_path=$(readlink "$generation/home-path")
        if [[ -d "$home_path" ]]; then
          mkdir -p "$HOME/.local/state/nix/profiles"
          ln -sfn "$home_path" "$HOME/.local/state/nix/profiles/profile"
          ln -sfn "$HOME/.local/state/nix/profiles/profile" "$HOME/.nix-profile"
          echo "  Created: .nix-profile -> $home_path"
        fi
      fi

      echo "Home-manager symlinks created successfully"
    '';
  };

  # The original home-manager service will fail with nix-store errors on immutable systems.
  # Our symlinks service runs first and creates the symlinks, so we just make the
  # failure non-fatal. We must keep the service as-is so the generation is included in closure.
  systemd.services."home-manager-${regularUser}" = {
    serviceConfig = {
      # Allow exit code 1 (nix-store failure) to be treated as success
      SuccessExitStatus = [ 1 ];
    };
  };

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
        sway-home.homeModules.nixos-vm-template
      ];

      # Install packages from sway-home
      home.packages = import "${sway-home}/modules/packages.nix" { inherit pkgs; };

      # Let home-manager manage itself
      programs.home-manager.enable = true;
    };
  };
}
