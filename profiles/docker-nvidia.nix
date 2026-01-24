# Docker with NVIDIA GPU support - for VMs with GPU passthrough
{ config, lib, pkgs, ... }:

{
  imports = [ ./docker.nix ];

  config = {
    # Allow unfree NVIDIA driver packages
    nixpkgs.config.allowUnfree = true;

    # NVIDIA container toolkit for GPU passthrough to containers
    hardware.nvidia-container-toolkit.enable = true;

    # Register nvidia runtime for legacy docker-compose "gpus: all" syntax
    # CDI (nvidia.com/gpu=all) works by default, but many docker-compose files
    # still use the legacy runtime approach
    virtualisation.docker.daemon.settings = {
      runtimes.nvidia.path = "${pkgs.nvidia-container-toolkit}/bin/nvidia-container-runtime";
    };

    # NVIDIA drivers (required by nvidia-container-toolkit)
    services.xserver.videoDrivers = [ "nvidia" ];
    hardware.graphics.enable = true;
    hardware.nvidia.open = true;  # Use open source kernel modules (Turing+ / RTX series)
  };
}
