# DNS identity module - configures DNS from /var/identity using systemd-resolved
#
# This module:
# 1. Bakes /etc/resolv.conf pointing to resolved's stub listener (127.0.0.53)
#    (NixOS normally creates this as a symlink, but that fails on read-only root)
# 2. Enables systemd-resolved stub listener on 127.0.0.1 and ::1
# 3. Configures custom DNS servers from /var/identity/resolv.conf via
#    a resolved drop-in config in /run/systemd/resolved.conf.d/
{ config, lib, pkgs, ... }:

{
  # Immutable-mode DNS identity configuration
  config = lib.mkIf (!config.vm.mutable) {
    # Enable systemd-resolved with listeners on 127.0.0.1 and ::1
    # (in addition to the default 127.0.0.53)
    services.resolved.enable = true;
    services.resolved.settings.Resolve.DNSStubListenerExtra = [ "127.0.0.1" "::1" ];

    # Create /etc/resolv.conf placeholder in the image.
    # NixOS resolved sets environment.etc."resolv.conf".source to
    # /run/systemd/resolve/stub-resolv.conf, which doesn't exist at build time
    # so no file gets baked into /etc/static/. Override with a static file
    # using pkgs.writeText so the placeholder exists in the image.
    # The dns-identity service bind mounts /run/resolv.conf over it at boot.
    environment.etc."resolv.conf" = lib.mkForce {
      source = pkgs.writeText "resolv.conf" "# Placeholder - replaced by dns-identity bind mount\nnameserver 127.0.0.53\noptions edns0 trust-ad\n";
      mode = "0644";
    };

    # Service to create /etc/resolv.conf and configure custom DNS
    systemd.services.dns-identity = {
      description = "Configure DNS and /etc/resolv.conf from /var/identity";
      wantedBy = [ "sysinit.target" ];
      before = [ "network-pre.target" "nss-lookup.target" "systemd-resolved.service" ];
      after = [ "local-fs.target" "var.mount" ];
      wants = [ "local-fs.target" ];

      unitConfig = {
        DefaultDependencies = false;
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        # Write resolv.conf to /run and bind mount over the placeholder
        cat > /run/resolv.conf << 'EOF'
nameserver 127.0.0.53
options edns0 trust-ad
EOF
        chmod 0644 /run/resolv.conf
        ${pkgs.util-linux}/bin/mount --bind /run/resolv.conf /etc/resolv.conf

        # Configure custom DNS via resolved drop-in if identity file exists
        if [ -f /var/identity/resolv.conf ]; then
          nameservers=""
          while read -r line; do
            case "$line" in
              nameserver\ *)
                ns="''${line#nameserver }"
                nameservers="$nameservers $ns"
                ;;
            esac
          done < /var/identity/resolv.conf
          nameservers="''${nameservers# }"  # trim leading space

          if [ -n "$nameservers" ]; then
            echo "Setting DNS: $nameservers"
            mkdir -p /run/systemd/resolved.conf.d
            printf '[Resolve]\nDNS=%s\n' "$nameservers" > /run/systemd/resolved.conf.d/identity.conf
          fi
        fi
      '';
    };
  };
}
