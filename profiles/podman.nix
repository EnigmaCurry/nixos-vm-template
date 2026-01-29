# Podman profile - rootless container runtime for all users
{ config, lib, pkgs, ... }:

{
  config = {
    # Enable Podman
    virtualisation.podman = {
      enable = true;
      # Note: dockerCompat is not enabled as it conflicts with Docker
      # Use 'podman' command directly instead of 'docker'
      defaultNetwork.settings.dns_enabled = true;
    };

    # Enable rootless containers for all users
    virtualisation.containers.enable = true;

    # Trust the podman bridge so container traffic passes the firewall
    networking.firewall.trustedInterfaces = [ "podman0" ];

    # Prevent systemd-networkd from managing Podman's veth interfaces
    systemd.network.networks."10-podman-veth" = {
      matchConfig.Driver = "veth";
      linkConfig.Unmanaged = "yes";
    };

    # Podman-related packages including development tools
    environment.systemPackages = with pkgs; [
      podman-compose
      distrobox
      buildah
      skopeo
    ];
  };
}
