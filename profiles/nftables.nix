# nftables profile — replace the default iptables-based firewall with a
# per-VM nftables ruleset loaded from /var/identity/nftables.conf, and pair it
# with PCI NIC passthrough (Proxmox only). Nothing about the ruleset lives in
# the shared base image or the nix store.
#
# The intended shape is a router/firewall VM with a physical NIC handed to
# the guest via `machines/<name>/pci_devices` (seeded/picked by the wizard on
# `just create`). The guest sees the PCI NIC as a real interface and applies
# rules from /var/identity/nftables.conf against it.
#
# /var/identity/nftables.conf     chmod 0644
#   Raw `nft -f` input. Same syntax as /etc/nftables.conf. If the file is
#   missing or contains a syntax error, the loader unit fails hard and
#   `systemctl status nftables-identity` shows the reason — the kernel
#   ruleset is left flushed (no rules) rather than falling back to iptables.
#
# Apply changes with:
#   just upgrade <name>   (or  just sync-identity <name> on proxmox-lxc)
#
# Notes:
#   - core.nix's `networking.firewall.enable = true` (iptables via nixos-fw)
#     is forced off here. `firewall-identity.nix`'s tcp_ports/udp_ports loader
#     silently no-ops without the nixos-fw chain, so those files (if present)
#     are ignored while this profile is active.
#   - PCI passthrough itself is a host-side concern; this profile only
#     configures the guest. See the pci_devices file in the machine dir.
{ config, lib, pkgs, ... }:

{
  config = lib.mkIf (!config.vm.mutable) {
    # Replace the iptables-based firewall from core.nix.
    networking.firewall.enable = lib.mkForce false;

    environment.systemPackages = [ pkgs.nftables ];

    # Placeholder in /etc so `nft -f /etc/nftables.conf` on a fresh image
    # doesn't error — real rules come from /var/identity/nftables.conf.
    environment.etc."nftables.conf" = lib.mkForce {
      text = ''
        #!/usr/sbin/nft -f
        # Placeholder — the nftables profile loads /var/identity/nftables.conf
        # via the nftables-identity service. This file is intentionally empty.
        flush ruleset
      '';
      mode = "0644";
    };

    systemd.services.nftables-identity = {
      description = "Load nftables ruleset from /var/identity/nftables.conf";
      after = [ "var.mount" "network-pre.target" ];
      requires = [ "var.mount" ];
      before = [ "network.target" "sshd.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "/var/identity/nftables.conf";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.nftables}/bin/nft -f /var/identity/nftables.conf";
        ExecReload = "${pkgs.nftables}/bin/nft -f /var/identity/nftables.conf";
        ExecStop = "${pkgs.nftables}/bin/nft flush ruleset";
      };
    };
  };
}
