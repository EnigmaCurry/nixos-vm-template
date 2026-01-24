# Docker with NVIDIA GPU support - for VMs with GPU passthrough
{ config, lib, pkgs, ... }:

{
  imports = [ ./docker.nix ];

  config = {
    # NVIDIA container toolkit for GPU passthrough to containers
    hardware.nvidia-container-toolkit.enable = true;

    # NVIDIA drivers (required by nvidia-container-toolkit)
    services.xserver.videoDrivers = [ "nvidia" ];
    hardware.graphics.enable = true;
    hardware.nvidia.open = true;  # Use open source kernel modules (Turing+ / RTX series)
  };
}
