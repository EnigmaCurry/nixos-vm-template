# Rust development profile - rustup with rust-analyzer
{ config, lib, pkgs, ... }:

let
  regularUser = config.core.regularUser;
in
{
  imports = [
    ../modules/sqlite.nix
  ];

  config = {
    environment.systemPackages = with pkgs; [
      rustup
      gcc  # Needed for linking
      pkg-config
    ];

    # Initialize rustup on first interactive shell login (only for regular user)
    environment.interactiveShellInit = ''
      if [ "$(whoami)" = "${regularUser}" ] && [ ! -d "$HOME/.rustup" ]; then
        echo "Initializing rustup with stable toolchain..."
        rustup default stable
        rustup component add rust-analyzer
        echo "Rustup ready! Run 'rustup show' to see installed toolchains."
      fi
    '';
  };
}
