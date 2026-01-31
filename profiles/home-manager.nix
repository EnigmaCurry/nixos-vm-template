# Home-manager profile - configures home-manager for the regular user
# Uses sway-home modules for a complete terminal/editor environment
# Works with immutable /nix - uses custom symlink service instead of nix-store commands
{ config, lib, pkgs, sway-home, swayHomeInputs, nix-flatpak, ... }:

let
  regularUser = config.core.regularUser;
  swayHomePath = "~/git/vendor/enigmacurry/sway-home";
  swayHomeRepo = "https://github.com/enigmacurry/sway-home.git";
in
{
  # On mutable VMs, clone sway-home repo on first login so hm-upgrade works
  # The hm-upgrade alias calls: just -f ~/git/vendor/enigmacurry/sway-home/Justfile hm-upgrade
  environment.interactiveShellInit = lib.mkIf config.vm.mutable ''
    if [ "$(id -u)" != "0" ] && [ ! -d "${swayHomePath}" ]; then
      echo "Cloning sway-home repository for hm-upgrade support..."
      mkdir -p ~/git/vendor/enigmacurry
      ${pkgs.git}/bin/git clone ${swayHomeRepo} ${swayHomePath}
      echo "sway-home cloned. You can now run 'hm-upgrade' to update home-manager."
    fi
  '';

  # The standard home-manager activation fails on immutable systems because
  # nix-store commands require a writable /nix with a valid database.
  # This service creates the symlinks directly before home-manager runs.
  # On mutable VMs, the standard activation works fine so we skip this.
  systemd.services."home-manager-symlinks-${regularUser}" = lib.mkIf (!config.vm.mutable) {
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

        # Skip .cache entirely - it's runtime data that needs to be writable
        if [[ "$name" == ".cache" ]]; then
          echo "  Skipped (writable): $name"
          mkdir -p "$HOME/$name"
          continue
        fi

        # For .local, create the directory structure but symlink contents
        # This preserves managed files while allowing writable state dirs
        if [[ "$name" == ".local" && -d "$f" ]]; then
          echo "  Merging (partial writable): $name"
          mkdir -p "$HOME/.local"
          # Symlink subdirectories (share, bin, etc.) but not state
          for subdir in "$f"/*; do
            subname=$(basename "$subdir")
            if [[ "$subname" == "state" ]]; then
              mkdir -p "$HOME/.local/state"
              echo "    Skipped (writable): .local/state"
            elif [[ ! -e "$HOME/.local/$subname" ]]; then
              ln -sfn "$subdir" "$HOME/.local/$subname"
              echo "    Created: .local/$subname -> $subdir"
            fi
          done
          continue
        fi

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

      # Note: .nix-profile is not set up because:
      # 1. nix-env/nix profile require writable /nix with a valid database
      # 2. Packages from home.packages are already in PATH via home-manager's shell config

      echo "Home-manager symlinks created successfully"
    '';
  };

  # The original home-manager service fails with nix-store errors on immutable systems.
  # Our symlinks service runs first and creates the symlinks, so we allow the failure.
  # We keep the service reference intact so the generation is included in the closure.
  # On mutable VMs, the standard activation works fine so we don't override this.
  systemd.services."home-manager-${regularUser}" = lib.mkIf (!config.vm.mutable) {
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
      home.packages = import "${sway-home}/modules/packages.nix" { inherit pkgs; }
        ++ [ swayHomeInputs.script-wizard.packages.${pkgs.system}.default ];

      # Let home-manager manage itself
      programs.home-manager.enable = true;
    };
  };
}
