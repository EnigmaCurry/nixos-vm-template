# Docker profile - core system with Docker daemon
{ config, lib, pkgs, ... }:

{
  imports = [ ./core.nix ];

  config = {
    # Enable Docker daemon
    virtualisation.docker.enable = true;

    # Trust the Docker bridge so container traffic passes the firewall
    networking.firewall.trustedInterfaces = [ "docker0" ];

    # Allow forwarding for Docker containers to reach the internet
    networking.firewall.extraCommands = ''
      iptables -A FORWARD -i docker0 -j ACCEPT
      iptables -A FORWARD -o docker0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    '';
    networking.firewall.extraStopCommands = ''
      iptables -D FORWARD -i docker0 -j ACCEPT 2>/dev/null || true
      iptables -D FORWARD -o docker0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    '';

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
