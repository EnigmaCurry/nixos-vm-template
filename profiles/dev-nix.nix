# Development with mutable /nix profile
# Combines dev profile with mutable /nix filesystem for running nix commands
{ config, lib, pkgs, ... }:

{
  imports = [
    ./dev.nix
    ./nix.nix
  ];
}
