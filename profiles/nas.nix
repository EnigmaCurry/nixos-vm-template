# NAS profile (proxmox-lxc backend only)
#
# Serves every host ZFS dataset bind-mounted under /srv/<name> (via the backend's
# `pct set -mpN`) over THREE access methods sharing the same files and the same
# users/permissions:
#   - NFS    (kernel nfsd, v4-only)            — host-allowlisted (nfs_clients)
#   - Samba  (SMB)                             — per-user (nas_passwd + nas_acl)
#   - copyparty (web UI + WebDAV, port 3923)   — per-user (nas_passwd + nas_acl)
# The set of datasets is runtime data (the backend mounts them; they're not known
# when the image is built), so a boot service (nas-shares) discovers the /srv/*
# mountpoints and generates the NFS exports, Samba shares, and copyparty config.
#
# Users/SSH/identity come from the core profile + injected /etc; this profile only
# adds the NAS services. Requires a privileged LXC (kernel nfsd).
#
# Access control — two per-machine files synced from the workstation config:
#   /etc/nas/nas_passwd (0600) — `<user> <password>`, one per line: the users.
#   /etc/nas/nas_acl    (0644) — `<user> <share> <access>`, access = r | rw:
#       user  = a name (must be in nas_passwd), or * for guest/anonymous
#       share = a share name (bind-mount basename), or * for ALL shares
#   Mapping: r  -> copyparty `r`,    Samba read-only.
#            rw -> copyparty `rwmd`, Samba write.
#   DENY BY DEFAULT (unconditional): a user/guest gets only what an explicit rule
#   grants; no rule means no access (Samba/copyparty). There is no open fallback.
#
# SECURITY: nas_passwd is PLAINTEXT (0600) on the workstation and in the container.
# Samba/copyparty access is gated per-user; NFS has no per-user auth so it is
# host-based and DENY-BY-DEFAULT via nas_clients (all_squash to the shared 'nas'
# owner). Everything runs as the unprivileged 'nas' user; files are nas-owned.
# Fine for a trusted home network; not for untrusted multi-tenant use.
{ config, lib, pkgs, ... }:

{
  assertions = [{
    assertion = config.vm.container;
    message = "The 'nas' profile is only supported on the proxmox-lxc backend "
      + "(it needs an LXC container with host ZFS datasets bind-mounted under /srv).";
  }];

  # ACL users are runtime data (the image is generic), so they're created at boot
  # by nas-shares rather than declared. Allow runtime-managed users to persist.
  users.mutableUsers = lib.mkForce true;

  # Single shared owner for all NAS data. Every NFS client UID (via all_squash),
  # every Samba user (force user), and copyparty (runs as nas) map to it, giving
  # flat "anyone authorized can access any file" semantics regardless of client
  # UID. Fixed uid/gid (1500) so it's stable across recreate and matches the
  # anonuid/anongid baked into the NFS exports.
  users.users.nas = {
    uid = 1500;
    group = "nas";
    isSystemUser = true;
    description = "NAS shared data owner";
  };
  users.groups.nas.gid = 1500;

  # NFS server (exports managed dynamically by nas-shares; NFSv4-only).
  services.nfs.server = {
    enable = true;
    exports = "";
  };
  services.nfs.settings.nfsd = {
    vers2 = false;
    vers3 = false;
    vers4 = true;
    udp = false;
  };

  # Samba. Per-dataset [share] stanzas are generated at boot into the include
  # file below; the static config is just the global section.
  services.samba = {
    enable = true;
    # nmbd is legacy NetBIOS (SMB1-era) browsing, ignored by modern SMB2/3
    # clients — discovery is handled by WS-Discovery + mDNS below instead.
    nmbd.enable = false;
    settings.global = {
      "workgroup" = "WORKGROUP";
      "server string" = "%h";
      "security" = "user";
      "map to guest" = "bad user";
      # Only enumerate shares the connecting user can access, so share *names*
      # aren't leaked to unauthorized/guest users.
      "access based share enum" = "yes";
      "include" = "/run/samba/nas-shares.conf";
    };
  };

  # Network discovery for modern clients (no IP needed):
  #   WS-Discovery (wsdd) → Windows "Network" + modern Linux file managers.
  #   mDNS (avahi)        → macOS Finder / Avahi browsers, and <hostname>.local.
  services.samba-wsdd = {
    enable = true;
    workgroup = "WORKGROUP";
  };

  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      userServices = true;
      addresses = true;
    };
    extraServiceFiles.smb = ''
      <?xml version="1.0" standalone='no'?>
      <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
      <service-group>
        <name replace-wildcards="yes">%h</name>
        <service>
          <type>_smb._tcp</type>
          <port>445</port>
        </service>
      </service-group>
    '';
  };

  # Ensure the Samba include target + a CWD-safe dir exist before the services start.
  systemd.tmpfiles.rules = [
    "d /run/samba 0755 root root -"
    "f /run/samba/nas-shares.conf 0644 root root -"
    "d /etc/exports.d 0755 root root -"
    "d /var/empty 0555 root root -"
  ];

  # copyparty: web UI + WebDAV at http://<ip>:3923/<share>, reading the config
  # generated by nas-shares from nas_passwd/nas_acl. Runs as the shared 'nas'
  # owner; WorkingDirectory is an empty dir so it can never fall back to serving
  # its CWD (it always has the /srv/* volumes from the generated config anyway).
  systemd.services.copyparty = {
    description = "copyparty file server (web UI + WebDAV)";
    after = [ "nas-shares.service" ];
    wants = [ "nas-shares.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.copyparty}/bin/copyparty -c /run/copyparty/copyparty.conf";
      User = "nas";
      Group = "nas";
      WorkingDirectory = "/var/empty";
      StateDirectory = "copyparty";
      Environment = "HOME=/var/lib/copyparty";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };

  # Discover each bind-mounted dataset under /srv and serve it over NFS + Samba +
  # copyparty, one share per dataset (share name = the directory basename), with
  # access derived from nas_acl (deny-by-default).
  systemd.services.nas-shares = {
    description = "Generate NFS/Samba/copyparty config for /srv/* bind mounts";
    wantedBy = [ "multi-user.target" ];
    after = [ "nfs-server.service" "samba-smbd.service" ];
    wants = [ "nfs-server.service" "samba-smbd.service" ];
    path = with pkgs; [ coreutils util-linux gnused gnugrep nfs-utils samba shadow systemd ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -u
      passwd=/etc/nas/nas_passwd
      acl=/etc/nas/nas_acl
      nfs_clients=/etc/nas/nfs_clients
      exports=/etc/exports.d/nas-shares.exports
      smbinc=/run/samba/nas-shares.conf
      cpconf=/run/copyparty/copyparty.conf
      mkdir -p /etc/exports.d /run/samba /run/copyparty
      : > "$exports"
      : > "$smbinc"

      # Strip comments and blank lines from a file ($1).
      clean() { sed -e 's/#.*//' "$1" 2>/dev/null | grep -vE '^[[:space:]]*$' || true; }
      # Space-separated list -> comma-separated (copyparty accs need commas).
      commafy() { echo "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]][[:space:]]*/, /g'; }

      # Start the copyparty config: globals + accounts (filled from nas_passwd).
      { echo "[global]"; echo "  usernames"; echo; echo "[accounts]"; } > "$cpconf"

      # Create a system user + Samba passdb entry for each user in nas_passwd, and
      # add it to the copyparty [accounts] section.
      if [ -f "$passwd" ]; then
        while read -r u pw rest; do
          [ -z "$u" ] && continue
          [ "$u" = "*" ] && continue
          id "$u" >/dev/null 2>&1 || useradd -M -N "$u" || true
          if [ -n "$pw" ] && [ "$pw" != "-" ]; then
            printf '%s\n%s\n' "$pw" "$pw" | smbpasswd -s -a "$u" >/dev/null 2>&1 || true
            smbpasswd -e "$u" >/dev/null 2>&1 || true
            echo "  $u: $pw" >> "$cpconf"
          fi
          echo "nas-shares: user '$u' configured"
        done < <(clean "$passwd")
      fi

      # NFS client allowlist (host-based, deny-by-default). Each line: "<cidr> [ro]"
      # (default rw). all_squash maps every client UID to the shared 'nas' owner.
      nfs_spec=""
      if [ -f "$nfs_clients" ]; then
        while read -r c mode rest; do
          [ -z "$c" ] && continue
          rw=rw; [ "$mode" = ro ] && rw=ro
          nfs_spec="$nfs_spec $c($rw,sync,no_subtree_check,all_squash,anonuid=1500,anongid=1500)"
        done < <(clean "$nfs_clients")
      fi

      # Resolve the ACL for a share into ro_users/rw_users/guest_r/guest_rw.
      resolve_acl() {
        s="$1"; ro_users=""; rw_users=""; guest_r=no; guest_rw=no
        while read -r u share access; do
          [ -z "$u" ] && continue
          if [ "$share" = "$s" ] || [ "$share" = "*" ]; then
            if [ "$u" = "*" ]; then
              if [ "$access" = rw ]; then guest_rw=yes; else guest_r=yes; fi
            elif [ "$access" = rw ]; then rw_users="$rw_users $u"
            else ro_users="$ro_users $u"; fi
          fi
        done < <(clean "$acl")
      }

      for d in /srv/*; do
        [ -d "$d" ] || continue
        mountpoint -q "$d" || continue
        name=$(basename "$d")
        # Share root owned by the shared 'nas' identity (setgid so new dirs keep it).
        chown nas:nas "$d" 2>/dev/null || true
        chmod 2775 "$d" 2>/dev/null || true
        # NFS export only for allowlisted clients; none → not exported.
        [ -n "$nfs_spec" ] && echo "$d$nfs_spec" >> "$exports"

        resolve_acl "$name"

        # ── Samba (deny-by-default: empty valid users ⇒ no access) ──
        valid="$ro_users$rw_users"
        { [ "$guest_r" = yes ] || [ "$guest_rw" = yes ]; } && valid="$valid nobody"
        write="$rw_users"; [ "$guest_rw" = yes ] && write="$write nobody"
        {
          echo "[$name]"
          echo "  path = $d"
          echo "  browseable = yes"
          echo "  force user = nas"
          echo "  force group = nas"
          echo "  create mask = 0664"
          echo "  directory mask = 2775"
          echo "  read only = yes"
          echo "  valid users =$valid"
          [ -n "$write" ] && echo "  write list =$write"
          if [ "$guest_r" = yes ] || [ "$guest_rw" = yes ]; then
            echo "  guest ok = yes"
          else
            echo "  guest ok = no"
          fi
        } >> "$smbinc"

        # ── copyparty volume (deny-by-default: no grants ⇒ no access) ──
        r_list="$ro_users"; [ "$guest_r" = yes ] && r_list="$r_list *"
        rwmd_list="$rw_users"; [ "$guest_rw" = yes ] && rwmd_list="$rwmd_list *"
        {
          echo "[/$name]"
          echo "  $d"
          echo "  accs:"
          [ -n "$r_list" ] && echo "    r: $(commafy "$r_list")"
          [ -n "$rwmd_list" ] && echo "    rwmd: $(commafy "$rwmd_list")"
        } >> "$cpconf"

        echo "nas-shares: serving '$name' (smb + web$([ -n "$nfs_spec" ] && echo ' + nfs'))"
      done

      # Return the Samba parser to [global] after the share sections (the include
      # sits in [global] before the other globals alphabetically).
      echo "[global]" >> "$smbinc"

      # copyparty config holds plaintext passwords → readable only by root + nas.
      chown root:nas "$cpconf" 2>/dev/null || true
      chmod 0640 "$cpconf" 2>/dev/null || true

      exportfs -ra
      smbcontrol smbd reload-config 2>/dev/null || true
      # Apply config changes on a re-run (e.g. after sync-identity); on first boot
      # copyparty hasn't started yet (it is ordered after this unit) so this no-ops.
      systemctl try-restart copyparty.service 2>/dev/null || true
    '';
  };

  # Firewall ports are NOT opened in the image. The SMB/NFS/copyparty/discovery
  # ports are seeded into the machine config's tcp_ports/udp_ports at create time
  # (visible, user-editable). Those drive BOTH the container firewall and the
  # Proxmox CT firewall — one place to control, nothing hidden in the profile.

  environment.systemPackages = [ pkgs.nfs-utils ];
}
