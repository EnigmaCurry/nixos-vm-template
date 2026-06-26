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

  # Build for a Proxmox LXC container instead of a QEMU/KVM VM. Containers share
  # the host kernel and have no bootloader/UEFI/virtio block devices, so the
  # disk/boot/growpart machinery below (and boot.nix, guest-agent.nix) is guarded
  # off. The /etc-reading identity services are kept — they work in a container.
  # LXC implies mutable (an LXC rootfs is read-write; nixos-rebuild runs inside).
  options.vm.container = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Build for an LXC container (no bootloader/disks/UEFI)";
  };

  config = lib.mkIf config.vm.mutable (lib.mkMerge [
    # ── Shared by mutable VMs AND containers: identity services reading /etc ──
    {
      # Don't let NixOS manage /etc/hostname - we set it via the vm-hostname
      # service from /etc/hostname (seeded at create time).
      networking.hostName = lib.mkForce "";

      # Use standard SSH authorized_keys locations
      services.openssh.authorizedKeysFiles = lib.mkForce [
        "/etc/ssh/authorized_keys.d/%u"
        ".ssh/authorized_keys"
      ];

      # Enable nix garbage collection (works with writable /nix)
      nix.gc.automatic = lib.mkForce true;
      nix.gc.dates = "weekly";
      nix.gc.options = "--delete-older-than 30d";

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

      # Service to set hostname from /etc/hostname at boot
      # (hostname is seeded into /etc/hostname during VM/CT creation)
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

      # NixOS modules and profiles are copied to /etc/nixos/ during VM/CT creation
      # (alongside flake.nix and flake.lock) so nixos-rebuild works inside.
    }

    # ── VM-only (NOT a container): real block devices, bootloader, growpart ──
    (lib.mkIf (!config.vm.container) {
      # Standard writable root filesystem
      # Use mkForce to override the qcow image format defaults.
      # Keep the label-based device but make it read-write.
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
          # Re-read partition table so kernel sees new size
          ${pkgs.parted}/bin/partprobe /dev/vda || true
          # Resize filesystem (online resize supported for ext4)
          ${pkgs.e2fsprogs}/bin/resize2fs /dev/vda2 || true
        '';
      };
    })
  ]);
}
