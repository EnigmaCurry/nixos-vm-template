# cloud-init profile — makes the built image a clonable Proxmox template.
#
# On first boot, cloud-init reads the seed drive that PVE attaches (NoCloud
# datasource) and sets the hostname, network config, SSH host keys, and any
# `users:` / `write_files:` from the user-data snippet. Clones from the
# template each get their own identity that way instead of inheriting the
# baked-in one.
#
# This profile requires `mutable` mode — cloud-init writes to /etc/hostname,
# /etc/ssh/ssh_host_*_key, systemd-networkd configs, etc., all of which are
# read-only in immutable/semi-mutable modes. src/vm/profile.clj enforces this:
# combining cloud-init with semi-mutable is rejected; combining with an
# unset (default = immutable) mode auto-implies mutable.
{ config, lib, pkgs, ... }:

{
  services.cloud-init = {
    enable = true;
    network.enable = true;
    settings = {
      # PVE attaches its cloud-init seed as NoCloud. ConfigDrive is included
      # as a fallback for other hypervisors.
      datasource_list = [ "NoCloud" "ConfigDrive" ];
    };
  };

  # cloud-init's default renderer is systemd-networkd — it writes static
  # per-interface configs to /etc/systemd/network/. modules/mutable.nix sets
  # (with mkForce) useDHCP=true, useNetworkd=false, systemd.network.enable=false
  # for pet-VM ergonomics. Those defaults would leave cloud-init's networkd
  # config on disk with no daemon to read it, so we override at higher priority
  # (25 < mkForce's 50). This ONLY fires on VMs that also carry this profile.
  networking.useDHCP     = lib.mkOverride 25 false;
  networking.useNetworkd = lib.mkOverride 25 true;
  systemd.network.enable = lib.mkOverride 25 true;
  # networkd feeds systemd-resolved; enable it so cloud-init's DNS entries
  # are actually served to userspace resolvers.
  services.resolved.enable = lib.mkDefault true;

  # Cloud-init generates SSH host keys during its modules-config stage.
  # NixOS's sshd-keygen-start shim also tries to generate them (via
  # sshd-keygen.service, pulled in by sshd.service), and its script does
  # NOT check for existing files before invoking `ssh-keygen` — when it
  # runs after cloud-init has already created the keys it hits
  #   /etc/ssh/ssh_host_rsa_key already exists. Overwrite (y/n)?
  # and exits 1, which cascades into sshd.service never starting. Setting
  # hostKeys=[] gives sshd-keygen an empty list to iterate — it exits 0
  # with nothing to do — and sshd falls back to OpenSSH's built-in
  # default HostKey paths (/etc/ssh/ssh_host_{ed25519,rsa}_key), which is
  # exactly where cloud-init wrote them.
  services.openssh.hostKeys = lib.mkForce [];

  # Delay sshd until cloud-init has finished, so the keys cloud-init
  # generates are present by the time sshd binds them.
  systemd.services.sshd = {
    wants = [ "cloud-init.service" ];
    after = [ "cloud-init.service" ];
  };

  # qemu-guest-agent lets PVE report the VM's IP + trigger clean shutdowns.
  services.qemuGuest.enable = true;

  # cloud-init modules invoke `growpart` and related helpers.
  environment.systemPackages = with pkgs; [ cloud-utils ];

  # ── DEBUG ONLY: bake a serial-console root password ──────────────────────
  # When SSH doesn't come up, having a known root password lets us log in via
  # `qm terminal <vmid>` to run `systemctl status sshd`, `journalctl`, etc.
  # Cloud-init runs `passwd -l root` only when it detects an EMPTY shadow
  # entry, so any real password here silently prevents that lock. mkDefault
  # so downstream configs can override with hashedPassword for production.
  # Remove — or override with hashedPassword = null — before shipping any
  # template you don't want a known password on.
  users.users.root.initialPassword = lib.mkDefault "debug";

  # The nixos-generators qcow2 build baked cloud-init state into the image
  # (obj.pkl / instance-id in /var/lib/cloud) AND generated SSH host keys.
  # Both are per-VM identity that must NOT be shared across clones:
  # * With a baked instance-id, cloud-init on every clone sees a "previous iid
  #   matches", denies boot-event network updates, and skips once-per-instance
  #   modules (users, passwords, ssh authorized keys) → user-data is ignored.
  # * With baked SSH host keys, every clone advertises the same host identity.
  #
  # A systemd oneshot doesn't work here because cloud-init-local.service (the
  # first cloud-init stage) runs early and re-populates /var/lib/cloud from the
  # seed drive before we can order our unit ahead of it. An activation script,
  # by contrast, runs during stage 2 boot before ANY service — guaranteed to
  # execute before cloud-init sees the disk.
  #
  # Marker file /var/lib/nixos-vm-template.first-boot-done gates it; on
  # subsequent boots the marker exists and the cleanup is skipped. Because we
  # never *declare* the marker in any Nix module, the built image doesn't ship
  # with it, so a fresh clone always finds it missing on its first boot.
  system.activationScripts.cloudInitFirstBootClean = lib.stringAfter [ "specialfs" ] ''
    if [ ! -f /var/lib/nixos-vm-template.first-boot-done ]; then
      echo "First boot: wiping baked-in cloud-init state and SSH host keys..."
      ${pkgs.coreutils}/bin/rm -rf /var/lib/cloud/* || true
      ${pkgs.coreutils}/bin/rm -f  /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub || true
      ${pkgs.coreutils}/bin/mkdir -p /var/lib
      ${pkgs.coreutils}/bin/touch /var/lib/nixos-vm-template.first-boot-done
    fi
  '';
}
