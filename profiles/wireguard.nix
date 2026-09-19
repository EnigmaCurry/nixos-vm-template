# WireGuard VPN driven by a single per-VM identity file. Read at boot by
# wg-quick from /var/identity, so private keys and peer topology never enter
# the shared base image or the nix store.
#
# /var/identity/wireguard.conf     chmod 0600
#   Standard wg-quick format — one [Interface] section plus any number of
#   [Peer] sections. Absent (or the service condition fails) -> wg-quick
#   silently skips at boot, so the same image serves configured and
#   unconfigured VMs.
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
# UDP port to /var/identity/udp_ports (WireGuard is UDP-only).
#
# Put wireguard.conf under machines/<name>/ and it'll be synced to
# /var/identity/ during create/upgrade like every other identity file.
# `just create` seeds a fresh keypair the first time it sees the profile;
# recreate/upgrade preserve whatever key is already in the file.

{ config, lib, pkgs, ... }:

{
  environment.systemPackages = [ pkgs.wireguard-tools ];

  networking.wg-quick.interfaces.wg0 = {
    configFile = "/var/identity/wireguard.conf";
  };

  systemd.services.wg-quick-wg0 = {
    unitConfig = {
      ConditionPathExists = "/var/identity/wireguard.conf";
      RequiresMountsFor = "/var/identity";
    };
    after = [ "var.mount" ];
  };
}
