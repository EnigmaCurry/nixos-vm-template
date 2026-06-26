# Spike: NixOS-in-Proxmox-LXC NAS (NFS + Samba) — DISPOSABLE PROOF OF CONCEPT
#
# This is a deliberately standalone, minimal NixOS LXC config. It does NOT
# import ../modules (which assumes a bootable VM: read-only root, systemd-boot,
# a separate /var disk) — none of that applies to an LXC container.
#
# Goal: prove a NixOS LXC built by this repo boots on Proxmox as a *privileged*
# container, gets a host ZFS dataset bind-mounted at /srv/nas (via `pct -mp0`),
# and serves NFS (kernel nfsd) + Samba off it. See spike/README.md.
#
# Built via flake output `.#lxc-nas-spike` (-> config.system.build.tarball).
# An SSH key can be injected at build time with --impure + SSH_AUTHORIZED_KEY;
# otherwise a throwaway password ("nixos") is used for console / password SSH.
{ config, lib, pkgs, ... }:

let
  # Only read at eval time when built with --impure (run.bb does this); under a
  # pure `nix build` this is "" and we fall back to password auth.
  authKey = builtins.getEnv "SSH_AUTHORIZED_KEY";
in
{
  # ── Proxmox LXC integration ────────────────────────────────────────────────
  proxmoxLXC = {
    privileged = true;      # kernel nfsd needs a privileged container
    manageNetwork = true;   # WE own eth0 (combo A) — paired with `pct --ostype unmanaged`
    manageHostName = true;  # set hostname here rather than rely on Proxmox injection
  };

  # ── Networking: NixOS-managed DHCP on eth0 (systemd-networkd) ───────────────
  networking.hostName = "nas-spike";
  networking.useNetworkd = true;
  networking.useHostResolvConf = lib.mkForce false;
  services.resolved.enable = true;
  systemd.network.networks."10-eth0" = {
    matchConfig.Name = "eth0";
    networkConfig.DHCP = "yes";
  };
  # Don't let a slow/absent DHCP lease wedge the boot in "degraded" — the NAS
  # services don't need the network to be declared "online" to start.
  systemd.network.wait-online.enable = false;

  # ── Throwaway access (spike only — do not copy into the real backend) ───────
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "nixos";
    openssh.authorizedKeys.keys = lib.optional (authKey != "") authKey;
  };
  users.users.root.initialPassword = "nixos";
  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;
  # Spike convenience: allow password SSH so you can get in without a baked key.
  services.openssh.settings.PasswordAuthentication = lib.mkForce true;

  # ── NAS storage layout under the bind-mounted dataset ───────────────────────
  # /srv/nas itself is the host ZFS dataset mounted in by `pct set -mp0`.
  # These subdirs are created inside it on first boot.
  systemd.tmpfiles.rules = [
    "d /srv/nas       0755 root root -"
    "d /srv/nas/nfs   0755 root root -"
    "d /srv/nas/samba 0777 root root -"
  ];

  # ── NFS (kernel nfsd; privileged container) ─────────────────────────────────
  services.nfs.server = {
    enable = true;
    exports = ''
      /srv/nas *(rw,sync,no_subtree_check,no_root_squash)
    '';
    # Pin the ancillary RPC ports so the firewall rules below are sufficient.
    mountdPort = 4002;
    statdPort = 4000;
    lockdPort = 4001;
  };

  # ── Samba ───────────────────────────────────────────────────────────────────
  services.samba = {
    enable = true;
    openFirewall = true;
    nmbd.enable = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "nas-spike";
        "security" = "user";
        "map to guest" = "bad user";
      };
      nas = {
        "path" = "/srv/nas/samba";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0644";
        "directory mask" = "0755";
      };
    };
  };

  # ── Firewall: NFS (Samba opens its own ports via openFirewall) ──────────────
  networking.firewall.allowedTCPPorts = [ 111 2049 4000 4001 4002 ];
  networking.firewall.allowedUDPPorts = [ 111 2049 4000 4001 4002 ];

  environment.systemPackages = with pkgs; [ vim nfs-utils ];

  system.stateVersion = "26.11";
}
