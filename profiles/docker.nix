# Docker profile - core system with Docker daemon
{ config, lib, pkgs, ... }:

{
  imports = [ ./core.nix ];

  config = {
    # Enable Docker daemon
    virtualisation.docker.enable = true;

    # Add admin user to docker group for non-root access
    users.users.${config.core.adminUser}.extraGroups = [ "docker" ];

    # Traefik UID reservation for Docker containers
    users.users.traefik = {
      isSystemUser = true;
      group = "traefik";
    };
    users.groups.traefik = {};
  };
}
