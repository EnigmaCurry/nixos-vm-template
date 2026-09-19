# WireGuard hub role — enables IPv4 forwarding so spoke-to-spoke traffic
# can transit this peer.
#
# Roles (hub-and-spoke topology):
#   * Client / spoke: profile list contains `wireguard` only.
#   * Server / hub:   profile list contains BOTH `wireguard` AND
#                     `wireguard-hub` (this profile does not imply the
#                     base `wireguard` profile — you must list both).
#
# Do not add `wireguard-hub` to a roaming client. Forwarding on a spoke
# with multiple interfaces (wlan0/eth0/etc.) turns it into an unintended
# router between those networks.
#
# FORWARD chain is left at the kernel default ACCEPT; nixos-firewall
# only hooks INPUT.

{ ... }:

{
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
}
