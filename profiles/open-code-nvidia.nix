# OpenCode profile with NVIDIA GPU support
{ config, lib, pkgs, ... }:

{
  imports = [
    ./open-code.nix
    ./docker-nvidia.nix
  ];
}
