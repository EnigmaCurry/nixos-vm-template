# Development profile with NVIDIA GPU support
{ config, lib, pkgs, ... }:

{
  imports = [
    ./dev.nix
    ./docker-nvidia.nix
  ];
}
