# Mutable mode - standard read-write NixOS system
# When vm.mutable = true, the system uses a single read-write disk
# with full nix toolchain support (nix-env, nixos-rebuild, etc.)
#
# Other modules check config.vm.mutable to conditionally enable
# immutable-specific features (bind mounts, identity loading, etc.)
{ config, lib, pkgs, ... }:

{
  options.vm.mutable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable mutable mode with single read-write disk";
  };

  config = lib.mkIf config.vm.mutable {
    # Standard writable root filesystem
    # Use mkForce to override nixos-generators qcow format defaults
    # Keep the label-based device from nixos-generators but make it read-write
    fileSystems."/" = lib.mkForce {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
      options = [ "rw" "noatime" ];
    };

    fileSystems."/boot" = lib.mkForce {
      device = "/dev/disk/by-label/ESP";
      fsType = "vfat";
      options = [ "rw" ];
    };

    # Enable standard DHCP (not systemd-networkd)
    networking.useDHCP = lib.mkForce true;
    networking.useNetworkd = lib.mkForce false;
    systemd.network.enable = lib.mkForce false;

    # Enable boot random seed (disabled in immutable mode)
    systemd.services."systemd-boot-random-seed".enable = lib.mkForce true;

    # Use standard SSH authorized_keys locations
    services.openssh.authorizedKeysFiles = lib.mkForce [
      "/etc/ssh/authorized_keys.d/%u"
      ".ssh/authorized_keys"
    ];

    # Service to open firewall ports from /etc/firewall-ports (seeded at VM creation)
    # This mirrors firewall-identity.nix but reads from /etc/ instead of /var/identity/
    systemd.services.firewall-ports = {
      description = "Open firewall ports from /etc/firewall-ports";
      after = [ "firewall.service" ];
      wants = [ "firewall.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        # Open TCP ports
        if [ -f /etc/firewall-ports/tcp_ports ]; then
          while read -r port; do
            [[ -z "$port" || "$port" =~ ^# ]] && continue
            echo "Opening TCP port: $port"
            ${pkgs.iptables}/bin/iptables -I nixos-fw -p tcp --dport "$port" -j nixos-fw-accept 2>/dev/null || true
            ${pkgs.iptables}/bin/ip6tables -I nixos-fw -p tcp --dport "$port" -j nixos-fw-accept 2>/dev/null || true
          done < /etc/firewall-ports/tcp_ports
        fi

        # Open UDP ports
        if [ -f /etc/firewall-ports/udp_ports ]; then
          while read -r port; do
            [[ -z "$port" || "$port" =~ ^# ]] && continue
            echo "Opening UDP port: $port"
            ${pkgs.iptables}/bin/iptables -I nixos-fw -p udp --dport "$port" -j nixos-fw-accept 2>/dev/null || true
            ${pkgs.iptables}/bin/ip6tables -I nixos-fw -p udp --dport "$port" -j nixos-fw-accept 2>/dev/null || true
          done < /etc/firewall-ports/udp_ports
        fi
      '';
    };

    # Service to set root password from /etc/root_password_hash (seeded at VM creation)
    # This mirrors root-password.nix but modifies /etc/shadow directly (writable on mutable)
    systemd.services.root-password = {
      description = "Set root password from /etc/root_password_hash";
      wantedBy = [ "multi-user.target" ];
      before = [ "getty.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ -s /etc/root_password_hash ]; then
          root_hash=$(cat /etc/root_password_hash)
          # Use chpasswd to set the password hash
          echo "root:$root_hash" | ${pkgs.shadow}/bin/chpasswd -e
          echo "Root password set from /etc/root_password_hash"
        fi
      '';
    };

    # Enable nix garbage collection (works with writable /nix)
    nix.gc.automatic = lib.mkForce true;
    nix.gc.dates = "weekly";
    nix.gc.options = "--delete-older-than 30d";
  };
}
