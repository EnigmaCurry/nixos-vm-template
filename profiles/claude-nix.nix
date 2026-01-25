# Claude Code with mutable /nix profile
# Combines claude profile with mutable /nix filesystem for running nix commands
{ config, lib, pkgs, ... }:

{
  imports = [
    ./dev.nix
    ./claude.nix
    ./nix.nix
  ];
}
