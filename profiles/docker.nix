# Docker profile - core system with Docker daemon
{ config, lib, pkgs, ... }:

{
  imports = [ ./core.nix ];

  config = {
    # Enable Docker daemon
    virtualisation.docker.enable = true;
    virtualisation.docker.extraOptions = "--config-file /run/docker-daemon.json";

    # Generate Docker daemon.json from per-VM DNS identity before Docker starts
    systemd.services.docker-dns-config = {
      description = "Generate Docker daemon.json from identity DNS";
      before = [ "docker.service" ];
      requiredBy = [ "docker.service" ];
      after = [ "var.mount" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        nameservers=""
        if [ -f /var/identity/resolv.conf ]; then
          while IFS= read -r line; do
            case "$line" in
              nameserver\ *)
                ns="''${line#nameserver }"
                if [ -n "$nameservers" ]; then
                  nameservers="$nameservers, \"$ns\""
                else
                  nameservers="\"$ns\""
                fi
                ;;
            esac
          done < /var/identity/resolv.conf
        fi
        if [ -z "$nameservers" ]; then
          nameservers="\"1.1.1.1\", \"1.0.0.1\""
        fi
        echo "{\"dns\": [$nameservers]}" > /run/docker-daemon.json
      '';
    };

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

    # NVIDIA container toolkit for GPU passthrough to containers
    hardware.nvidia-container-toolkit.enable = true;

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
