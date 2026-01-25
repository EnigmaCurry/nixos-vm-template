# Claude Code profile with NVIDIA GPU support
{ config, lib, pkgs, ... }:

{
  imports = [
    ./claude.nix
    ./docker-nvidia.nix
  ];
}
