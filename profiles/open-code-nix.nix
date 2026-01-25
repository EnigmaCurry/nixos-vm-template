# OpenCode with mutable /nix profile
# Combines open-code profile with mutable /nix filesystem for running nix commands
{ config, lib, pkgs, ... }:

{
  imports = [
    ./dev.nix
    ./open-code.nix
    ./nix.nix
  ];
}
