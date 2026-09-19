# WireGuard VPN driven by a single per-VM identity file. Standard wg-quick
# format — one [Interface] section plus any number of [Peer] sections. The
# on-VM path differs by mode:
#
#   immutable:  /var/identity/wireguard.conf   (staged onto /var disk)
#   mutable:    /etc/wireguard/wg0.conf        (staged into rootfs at create)
#
# Absent (or the service condition fails) -> wg-quick silently skips at boot,
# so the same image serves configured and unconfigured VMs.
#
# Example:
#   [Interface]
#   PrivateKey = <this-vm-private-key>
#   Address    = 10.0.0.2/24
#   # ListenPort = 51820          # only for peers that accept inbound
#
#   [Peer]
#   PublicKey  = <hub-public-key>
#   Endpoint   = hub.example.com:51820
#   AllowedIPs = 10.0.0.0/24
#   PersistentKeepalive = 25
#
# The interface name is fixed as `wg0`. If ListenPort is set, also add the
# UDP port to udp_ports (WireGuard is UDP-only). `just create` seeds a
# fresh keypair the first time it sees the profile; recreate/upgrade
# preserve the key because it lives in machines/<name>/wireguard.conf.

{ config, lib, pkgs, ... }:

let
  mutable = config.vm.mutable;
  path = if mutable then "/etc/wireguard/wg0.conf" else "/var/identity/wireguard.conf";
in
{
  environment.systemPackages = [ pkgs.wireguard-tools ];

  networking.wg-quick.interfaces.wg0.configFile = path;

  systemd.services.wg-quick-wg0 = lib.mkMerge [
    { unitConfig.ConditionPathExists = path; }
    (lib.mkIf (!mutable) {
      unitConfig.RequiresMountsFor = "/var/identity";
      after = [ "var.mount" ];
    })
  ];
}
