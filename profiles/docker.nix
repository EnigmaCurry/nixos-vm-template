# Docker profile - core system with Docker daemon
{ config, lib, pkgs, ... }:

{
  imports = [ ./core.nix ];

  config = {
    # Enable Docker daemon
    virtualisation.docker.enable = true;

    # Trust the Docker bridge so container traffic passes the firewall
    networking.firewall.trustedInterfaces = [ "docker0" ];

    # Disable bridge netfilter so container bridge traffic bypasses iptables.
    # Docker enables br_netfilter at startup for inter-container isolation,
    # but it causes bridge traffic to be misrouted through iptables INPUT
    # where interface matching fails. Basic container networking (outbound
    # NAT, port publishing via userland proxy) works without it.
    systemd.services.disable-bridge-nf = {
      description = "Disable bridge netfilter for Docker networking";
      after = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables
        echo 0 > /proc/sys/net/bridge/bridge-nf-call-ip6tables
      '';
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
