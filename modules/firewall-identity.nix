# Firewall identity module - opens ports from /var/identity at boot
{ config, lib, pkgs, ... }:

{
  # Immutable-mode firewall identity configuration
  config = lib.mkIf (!config.vm.mutable) {
    # Service to open additional ports from /var/identity
    systemd.services.firewall-identity = {
      description = "Open firewall ports from /var/identity";
      after = [ "firewall.service" "var.mount" ];
      wants = [ "firewall.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        # Open TCP ports (insert before the log-refuse rule)
        if [ -f /var/identity/tcp_ports ]; then
          while read -r port; do
            # Skip empty lines and comments
            [[ -z "$port" || "$port" =~ ^# ]] && continue
            echo "Opening TCP port: $port"
            ${pkgs.iptables}/bin/iptables -I nixos-fw -p tcp --dport "$port" -j nixos-fw-accept 2>/dev/null || true
            ${pkgs.iptables}/bin/ip6tables -I nixos-fw -p tcp --dport "$port" -j nixos-fw-accept 2>/dev/null || true
          done < /var/identity/tcp_ports
        fi

        # Open UDP ports (insert before the log-refuse rule)
        if [ -f /var/identity/udp_ports ]; then
          while read -r port; do
            # Skip empty lines and comments
            [[ -z "$port" || "$port" =~ ^# ]] && continue
            echo "Opening UDP port: $port"
            ${pkgs.iptables}/bin/iptables -I nixos-fw -p udp --dport "$port" -j nixos-fw-accept 2>/dev/null || true
            ${pkgs.iptables}/bin/ip6tables -I nixos-fw -p udp --dport "$port" -j nixos-fw-accept 2>/dev/null || true
          done < /var/identity/udp_ports
        fi
      '';
    };
  };
}
