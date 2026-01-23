# Block outbound traffic to private/local network CIDRs
{ config, lib, pkgs, ... }:

{
  config = {
    networking.firewall.extraCommands = ''
      # Allow responses to connections initiated from outside (e.g. SSH from host)
      iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      # IPv4 RFC 1918
      iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
      iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
      iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
      # IPv6 Unique Local (fc00::/7) and Link-Local (fe80::/10)
      ip6tables -A OUTPUT -d fc00::/7 -j DROP
      ip6tables -A OUTPUT -d fe80::/10 -j DROP
    '';

    networking.firewall.extraStopCommands = ''
      iptables -D OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
      ip6tables -D OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
      iptables -D OUTPUT -d 10.0.0.0/8 -j DROP 2>/dev/null || true
      iptables -D OUTPUT -d 172.16.0.0/12 -j DROP 2>/dev/null || true
      iptables -D OUTPUT -d 192.168.0.0/16 -j DROP 2>/dev/null || true
      ip6tables -D OUTPUT -d fc00::/7 -j DROP 2>/dev/null || true
      ip6tables -D OUTPUT -d fe80::/10 -j DROP 2>/dev/null || true
    '';
  };
}
