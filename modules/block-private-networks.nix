# Block outbound traffic to private network CIDRs
# Exception: 192.168.122.1 (the libvirt host) is always allowed
{ config, lib, pkgs, ... }:

{
  config = {
    networking.firewall.extraCommands = ''
      # Allow outbound to the VM host (libvirt default gateway)
      iptables -I OUTPUT -d 192.168.122.1/32 -j ACCEPT
      # Block outbound to private networks (RFC 1918)
      iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
      iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
      iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
    '';

    networking.firewall.extraStopCommands = ''
      iptables -D OUTPUT -d 192.168.122.1/32 -j ACCEPT 2>/dev/null || true
      iptables -D OUTPUT -d 10.0.0.0/8 -j DROP 2>/dev/null || true
      iptables -D OUTPUT -d 172.16.0.0/12 -j DROP 2>/dev/null || true
      iptables -D OUTPUT -d 192.168.0.0/16 -j DROP 2>/dev/null || true
    '';
  };
}
