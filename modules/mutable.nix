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
    # Don't let NixOS manage /etc/hostname - we set it via guestfish and vm-hostname service
    # This prevents NixOS from overwriting our hostname during activation
    networking.hostName = lib.mkForce "";

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

    # Include cloud-utils for growpart
    environment.systemPackages = [ pkgs.cloud-utils ];

    # Grow root partition and filesystem on boot if disk was resized
    systemd.services.grow-root-partition = {
      description = "Grow root partition to fill disk";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Grow partition 2 (root) to fill available space
        # Layout: vda1=ESP, vda2=root (nixos label)
        ${pkgs.cloud-utils}/bin/growpart /dev/vda 2 || true
        # Resize filesystem (online resize supported for ext4)
        ${pkgs.e2fsprogs}/bin/resize2fs /dev/vda2 || true
      '';
    };

    # Service to set hostname from /etc/hostname at boot
    # (hostname is written by guestfish during VM creation)
    # Runs early in boot before network services start
    systemd.services.vm-hostname = {
      description = "Set hostname from /etc/hostname";
      wantedBy = [ "sysinit.target" ];
      before = [ "network-pre.target" "systemd-hostnamed.service" ];
      after = [ "local-fs.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ -f /etc/hostname ]; then
          hostname=$(cat /etc/hostname | tr -d '\n')
          ${pkgs.hostname}/bin/hostname "$hostname"
          echo "Hostname set to: $hostname"
        fi
      '';
    };

    # NixOS modules and profiles are copied to /etc/nixos/ during VM creation
    # via guestfish (alongside flake.nix and flake.lock). This avoids pure
    # evaluation issues that occur when environment.etc references paths.
  };
}
