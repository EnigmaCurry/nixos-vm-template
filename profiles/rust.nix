# Rust development profile - rustup with rust-analyzer
{ config, lib, pkgs, ... }:

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

    # Initialize rustup on first interactive shell login (skip for root)
    environment.interactiveShellInit = ''
      if [ "$(id -u)" != "0" ] && [ ! -d "$HOME/.rustup" ]; then
        echo "Initializing rustup with stable toolchain..."
        rustup default stable
        rustup component add rust-analyzer
        echo "Rustup ready! Run 'rustup show' to see installed toolchains."
      fi
    '';
  };
}
