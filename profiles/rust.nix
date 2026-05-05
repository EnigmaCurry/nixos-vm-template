# Rust development profile.
#
# Use Nix-provided Rust tools instead of rustup-managed toolchains. In immutable
# VMs, /home persists across image upgrades but /nix/store is replaced with the
# new boot image; rustup-installed toolchains in $HOME can retain linker wrapper
# scripts that point at old rustup store paths.
{ config, lib, pkgs, ... }:

{
  imports = [
    ../modules/sqlite.nix
  ];

  config = {
    environment.systemPackages = with pkgs; [
      cargo
      rustc
      rust-analyzer
      clippy
      rustfmt
      gcc  # Needed for linking
      pkg-config
    ];
  };
}
