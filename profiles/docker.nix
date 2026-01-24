# Docker profile - core system with Docker daemon
{ config, lib, pkgs, ... }:

{
  imports = [ ./core.nix ];

  config = {
    # Enable Docker daemon
    virtualisation.docker.enable = true;

    # Trust the Docker bridge so container traffic passes the firewall
    networking.firewall.trustedInterfaces = [ "docker0" ];

    # Prevent systemd-networkd from managing Docker's veth interfaces.
    # The catch-all "99-ethernet-default-dhcp" in immutable.nix matches
    # Type=ether which includes veth pairs. networkd trying to DHCP on
    # veth interfaces breaks Docker container networking entirely.
    systemd.network.networks."10-docker-veth" = {
      matchConfig.Driver = "veth";
      linkConfig.Unmanaged = "yes";
    };

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
