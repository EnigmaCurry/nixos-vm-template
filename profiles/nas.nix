# NAS profile (proxmox-lxc backend only)
#
# Serves every host ZFS dataset bind-mounted under /srv/<name> (via the backend's
# `pct set -mpN`) over THREE access methods sharing the same files and the same
# users/permissions:
#   - NFS    (kernel nfsd, v4-only)            — host-allowlisted (nas_hosts)
#   - Samba  (SMB)                             — per-user (nas_passwd + nas_acl)
#   - copyparty (web UI + WebDAV, port 3923)   — per-user (nas_passwd + nas_acl)
# The set of datasets is runtime data (the backend mounts them; they're not known
# when the image is built), so a boot service (nas-shares) discovers the /srv/*
# mountpoints and generates the NFS exports, Samba shares, and copyparty config.
#
# Users/SSH/identity come from the core profile + injected /etc; this profile only
# adds the NAS services. Requires a privileged LXC (kernel nfsd).
#
# Access control — per-machine files synced from the workstation config:
#   /etc/nas/nas_passwd (0600) — `<user> <password>`, one per line: the users.
#   /etc/nas/nas_acl    (0644) — `<user> <share> <access>`, access = r | rw:
#       user  = a name (must be in nas_passwd), or * for guest/anonymous
#       share = a share name (bind-mount basename), or * for ALL shares
#   Mapping: r  -> copyparty `r`,    Samba read-only.
#            rw -> copyparty `rwmd`, Samba write.
#   DENY BY DEFAULT (unconditional): a user/guest gets only what an explicit rule
#   grants; no rule means no access (Samba/copyparty). There is no open fallback.
#
#   /etc/nas/nas_hosts (0644, optional) — per-share host allowlist. One
#     line per scoped share: `<share> <token>...` where tokens are `wg:<peer>`,
#     `wg:*`, or a literal CIDR. Adds Samba `hosts allow`/`hosts deny` and
#     substitutes the NFS export's client list. Works with or without
#     wireguard — literal CIDR restrictions apply either way; `wg:` tokens
#     are only meaningful when the wireguard profile is also enabled.
#     Default policy for unlisted shares: LAN-only if wireguard is enabled
#     (wg subnet denied); no restriction if not. See NAS_HOSTS.md.
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
  #
  # bindsTo nas-shares: if the generator fails validation, copyparty is stopped
  # rather than running with a stale/partial config.
  systemd.services.copyparty = {
    description = "copyparty file server (web UI + WebDAV)";
    after = [ "nas-shares.service" ];
    bindsTo = [ "nas-shares.service" ];
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

  # Fail closed: if nas-shares fails its pre-flight validation, Samba and NFS
  # are stopped rather than served with a broken or partial config. On boot,
  # they wait for nas-shares to activate first (After). On re-run at
  # sync-identity time, BindsTo propagates a failed re-run into a clean stop.
  systemd.services.samba-smbd = {
    after = [ "nas-shares.service" ];
    bindsTo = [ "nas-shares.service" ];
  };
  systemd.services.nfs-server = {
    after = [ "nas-shares.service" ];
    bindsTo = [ "nas-shares.service" ];
  };

  # Discover each bind-mounted dataset under /srv and serve it over NFS + Samba +
  # copyparty, one share per dataset (share name = the directory basename), with
  # access derived from nas_acl (deny-by-default).
  #
  # Runs BEFORE samba-smbd/nfs-server/copyparty; they bindsTo this unit, so a
  # failed pre-flight validation keeps them stopped (fail closed, not stale).
  # Ordered after wg-quick-wg0 when the wireguard profile is enabled (systemd
  # silently drops the ordering hint if that unit is absent).
  systemd.services.nas-shares = {
    description = "Generate NFS/Samba/copyparty config for /srv/* bind mounts";
    wantedBy = [ "multi-user.target" ];
    after = [ "wg-quick-wg0.service" ];
    wants = [ "wg-quick-wg0.service" ];
    path = with pkgs; [ coreutils util-linux gnused gnugrep gawk nfs-utils samba shadow systemd ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -u
      passwd=/etc/nas/nas_passwd
      acl=/etc/nas/nas_acl
      hosts_file=/etc/nas/nas_hosts
      wg_conf=/etc/wireguard/wg0.conf

      exports=/etc/exports.d/nas-shares.exports
      smbinc=/run/samba/nas-shares.conf
      cpconf=/run/copyparty/copyparty.conf

      mkdir -p /etc/exports.d /run/samba /run/copyparty

      # ── helpers ──────────────────────────────────────────────────────
      # Strip comments and blank lines from a file ($1).
      clean() { sed -e 's/#.*//' "$1" 2>/dev/null | grep -vE '^[[:space:]]*$' || true; }
      # Space-separated list -> comma-separated (copyparty accs need commas).
      commafy() { echo "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]][[:space:]]*/, /g'; }
      # Zero out host bits: ipv4_network 10.0.0.1 24 -> 10.0.0.0
      ipv4_network() {
        awk -v ip="$1" -v p="$2" '
          BEGIN {
            split(ip, o, ".")
            addr = o[1]*16777216 + o[2]*65536 + o[3]*256 + o[4]
            block = 2 ^ (32 - p)
            net = int(addr / block) * block
            printf "%d.%d.%d.%d",
              int(net/16777216)%256, int(net/65536)%256,
              int(net/256)%256, net%256
          }'
      }

      # ── pre-flight: parse wg0.conf ───────────────────────────────────
      wg_enabled=no
      wg_subnet=""
      declare -A wg_peer_ips=()   # name -> space-separated list of "a.b.c.d/N"
      declare -a wg_peer_names=() # ordered list, for wg:* expansion

      if [ -f "$wg_conf" ]; then
        wg_enabled=yes
        section=""
        cur_name=""
        cur_ips=""
        interface_addr=""

        flush_peer() {
          if [ -n "$cur_name" ] && [ -n "$cur_ips" ]; then
            wg_peer_ips[$cur_name]="''${cur_ips# }"
            wg_peer_names+=("$cur_name")
          fi
          cur_name=""
          cur_ips=""
        }

        while IFS= read -r line || [ -n "$line" ]; do
          # trim
          line="''${line#"''${line%%[![:space:]]*}"}"
          line="''${line%"''${line##*[![:space:]]}"}"
          case "$line" in
            "[Interface]") flush_peer; section=interface ;;
            "[Peer]")      flush_peer; section=peer ;;
            "#"*)
              hn=$(printf '%s\n' "$line" | sed -nE 's/^#[[:space:]]*hostname:[[:space:]]*(.+)$/\1/p')
              if [ -n "$hn" ] && [ "$section" = peer ]; then
                cur_name="$hn"
              fi
              ;;
            "") ;;
            *=*)
              key=$(printf '%s\n' "$line" | sed -nE 's/^([^=[:space:]]+)[[:space:]]*=.*/\1/p')
              val=$(printf '%s\n' "$line" | sed -nE 's/^[^=]+=[[:space:]]*(.+)$/\1/p')
              if [ "$section" = interface ] && [ "$key" = Address ]; then
                interface_addr="$val"
              elif [ "$section" = peer ] && [ "$key" = AllowedIPs ]; then
                for a in $(printf '%s' "$val" | tr ',' ' '); do
                  a=$(printf '%s' "$a" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                  [ -n "$a" ] && cur_ips="$cur_ips $a"
                done
              fi
              ;;
          esac
        done < "$wg_conf"
        flush_peer

        # Derive IPv4 wg_subnet from the interface's first IPv4 Address.
        for a in $(printf '%s' "$interface_addr" | tr ',' ' '); do
          a=$(printf '%s' "$a" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
          case "$a" in
            *:*) ;;   # skip IPv6
            *)
              ip=$(printf '%s' "$a" | cut -d/ -f1)
              pfx=$(printf '%s' "$a" | cut -d/ -f2)
              if [ -n "$ip" ] && [ -n "$pfx" ] && [ "$ip" != "$pfx" ]; then
                wg_subnet="$(ipv4_network "$ip" "$pfx")/$pfx"
                break
              fi
              ;;
          esac
        done
      fi

      # ── pre-flight: parse + validate nas_hosts ──────────────────────
      # Host-centric: `<host-token>  <share>...` — one line per host, listing
      # every share that host may reach. Multiple lines may reference the
      # same share; the share's allow list is the union.
      #
      # This file is REQUIRED for the nas profile — missing or empty (no
      # active rules) means DENY-ALL: no share is reachable over Samba/NFS.
      # nas_acl (user gate) is unaffected but useless without network
      # reachability. Uncomment one of the quick-start examples in the
      # template to open things up.
      #
      # Wildcards:
      #   share `*`  every /srv/* bind mount (expanded at emit time)
      # For "any host" use `0.0.0.0/0` (all IPv4) or `wg:*` (all wg peers).
      # Bare `*` is NOT accepted in the host slot — the two are semantically
      # different and we require the explicit form for clarity.
      #
      # Processed whether wg is enabled or not — literal CIDR restrictions
      # are useful on LAN-only deployments too. wg: tokens error out if wg
      # is not enabled (no peer IPs to resolve).
      declare -A share_allow=()        # share -> space-separated resolved IPs/CIDRs
      declare -A share_seen=()         # share -> 1 if any host line references it
      declare -A share_has_wg=()       # share -> 1 if a wg: host referenced it
      declare -A share_has_net=()      # share -> 1 if a literal-CIDR host referenced it
      declare -A host_seen=()          # host token -> 1 (duplicate detection)
      declare -a star_hosts=()         # "kind|ips" for hosts whose share list contained `*`
      errors=""

      if [ -f "$hosts_file" ]; then
        line_no=0
        # Disable filename globbing across the parse loop: `*` and other glob
        # characters appear in host/share tokens and must NOT expand to cwd.
        set -f
        while IFS= read -r raw || [ -n "$raw" ]; do
          line_no=$((line_no + 1))
          # strip comments + trim
          line=$(printf '%s' "$raw" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
          [ -z "$line" ] && continue
          # positional split: host + shares
          set -- $line
          host="$1"; shift
          if [ -z "$host" ] || [ "$#" -eq 0 ]; then
            errors="$errors"$'\n'"nas-shares: ERROR: $hosts_file line $line_no: malformed (expected: <host-token> <share>...)"
            continue
          fi
          if [ -n "''${host_seen[$host]:-}" ]; then
            errors="$errors"$'\n'"nas-shares: ERROR: $hosts_file line $line_no: duplicate entry for host '$host' — consolidate all of its shares onto a single line"
            continue
          fi
          host_seen[$host]=1

          # Resolve the host token to IPs/CIDRs and remember its flavor.
          host_ips=""
          host_kind=""  # "wg" or "net"
          case "$host" in
            \*)
              errors="$errors"$'\n'"nas-shares: ERROR: $hosts_file line $line_no: bare '*' is not accepted as a host — use '0.0.0.0/0' (any IPv4) or 'wg:*' (all wg peers) to disambiguate"
              continue
              ;;
            wg:\*)
              if [ "$wg_enabled" != yes ]; then
                errors="$errors"$'\n'"nas-shares: ERROR: $hosts_file line $line_no: wg:* used but wireguard is not enabled (no $wg_conf)"
                continue
              fi
              host_kind=wg
              for pn in "''${wg_peer_names[@]}"; do
                host_ips="$host_ips ''${wg_peer_ips[$pn]}"
              done
              ;;
            wg:*)
              peer="''${host#wg:}"
              if [ "$wg_enabled" != yes ]; then
                errors="$errors"$'\n'"nas-shares: ERROR: $hosts_file line $line_no: wg:$peer used but wireguard is not enabled (no $wg_conf)"
                continue
              fi
              if [ -z "''${wg_peer_ips[$peer]:-}" ]; then
                errors="$errors"$'\n'"nas-shares: ERROR: $hosts_file line $line_no: wg:$peer not found in $wg_conf"
                continue
              fi
              host_kind=wg
              host_ips=" ''${wg_peer_ips[$peer]}"
              ;;
            [0-9]*)
              if ! printf '%s' "$host" | grep -qE '^[0-9]+(\.[0-9]+){3}(/[0-9]+)?$'; then
                errors="$errors"$'\n'"nas-shares: ERROR: $hosts_file line $line_no: '$host' is not a valid IPv4 CIDR"
                continue
              fi
              host_kind=net
              host_ips=" $host"
              ;;
            *)
              errors="$errors"$'\n'"nas-shares: ERROR: $hosts_file line $line_no: unknown host token '$host'"
              continue
              ;;
          esac

          # Fan out per-share. `*` in the share list is deferred to emit
          # time (we don't yet know which /srv/* mounts exist).
          has_star_share=no
          for share in "$@"; do
            if [ "$share" = "*" ]; then
              has_star_share=yes
              continue
            fi
            share_seen[$share]=1
            case "$host_kind" in
              wg)  share_has_wg[$share]=1 ;;
              net) share_has_net[$share]=1 ;;
            esac
            share_allow[$share]="''${share_allow[$share]:-}$host_ips"
          done
          if [ "$has_star_share" = yes ]; then
            star_hosts+=("$host_kind|$host_ips")
          fi
        done < "$hosts_file"
        set +f  # re-enable globbing for the /srv/* iteration below

        # Trim leading space from each accumulated allow list.
        for s in "''${!share_allow[@]}"; do
          share_allow[$s]="''${share_allow[$s]# }"
        done
      fi

      if [ -n "$errors" ]; then
        printf '%s\n' "$errors" >&2
        echo "nas-shares: pre-flight failed; no config files written; Samba/NFS/copyparty will not start." >&2
        exit 1
      fi

      # ── emit (pre-flight passed) ────────────────────────────────────
      : > "$exports"
      : > "$smbinc"

      # Start the copyparty config: globals + accounts (filled from nas_passwd).
      # Trust X-Forwarded-For from loopback so copyparty logs the real client
      # IP when it's fronted by a reverse proxy in the same container (e.g.
      # the traefik profile). Harmless when no proxy is in front.
      #
      # rproxy: -1 picks the LAST X-Forwarded-For entry (what traefik itself
      # appended = the real TCP source), not the first. A client sending its
      # own X-Forwarded-For prefix cannot displace traefik's entry, so the
      # ipu/ipar auto-login rules see only traefik-verified IPs.
      #
      # idp-h-usr: x-remote-user makes copyparty trust the pre-authenticated
      # username the wg-auth service injects via the traefik wg-user /
      # wg-required middlewares (see profiles/wg-auth.nix). auth-ord runs
      # idp first, then ipu (unused here), then pw so users on unmapped
      # wg peers or off-wg still get the normal password prompt.
      { echo "[global]";
        echo "  usernames";
        echo "  xff-hdr: x-forwarded-for";
        echo "  xff-src: 127.0.0.1";
        echo "  rproxy: -1";
        echo "  idp-h-usr: x-remote-user";
        echo "  auth-ord: idp,ipu,pw";
        echo;
        echo "[accounts]"; } > "$cpconf"

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

      # Build a "$cidr(opts)..." string for a set of CIDRs. nas_hosts drives
      # NFS export CIDRs per-share; all_squash maps every client UID to the
      # shared 'nas' owner.
      nfs_spec_from_cidrs() {
        out=""
        for c in $1; do
          [ -z "$c" ] && continue
          out="$out $c(rw,sync,no_subtree_check,all_squash,anonuid=1500,anongid=1500)"
        done
        printf '%s' "$out"
      }

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

      # Apply any deferred `*` share expansions now that we know which
      # /srv/* mounts exist. For every star_hosts entry, add its IPs to
      # every discovered share.
      if [ "''${#star_hosts[@]}" -gt 0 ]; then
        for d in /srv/*; do
          [ -d "$d" ] || continue
          mountpoint -q "$d" || continue
          name=$(basename "$d")
          for entry in "''${star_hosts[@]}"; do
            kind="''${entry%%|*}"
            ips="''${entry#*|}"
            share_seen[$name]=1
            case "$kind" in
              wg)  share_has_wg[$name]=1 ;;
              net) share_has_net[$name]=1 ;;
            esac
            share_allow[$name]="''${share_allow[$name]:-}$ips"
          done
        done
        # Re-trim any allow lists we just extended.
        for s in "''${!share_allow[@]}"; do
          share_allow[$s]="''${share_allow[$s]# }"
        done
      fi

      for d in /srv/*; do
        [ -d "$d" ] || continue
        mountpoint -q "$d" || continue
        name=$(basename "$d")
        # Share root owned by the shared 'nas' identity (setgid so new dirs keep it).
        chown nas:nas "$d" 2>/dev/null || true
        chmod 2775 "$d" 2>/dev/null || true

        # ── Compute per-share host scoping ──
        # Default policy: DENY-ALL for shares not listed in nas_hosts.
        # See NAS_HOSTS.md policy table.
        smb_hosts_allow=""
        smb_hosts_deny=""
        share_nfs_spec=""
        scoped=no
        if [ -n "''${share_seen[$name]:-}" ]; then
          scoped=yes
          smb_hosts_allow="127.0.0.1 ''${share_allow[$name]}"
          # Mixed (wg + net) tokens: deny wg subnet so wg peers outside the
          # allow list can't reach; allow always beats deny for allowed IPs.
          if [ -n "''${share_has_wg[$name]:-}" ] && [ -n "''${share_has_net[$name]:-}" ] && [ -n "$wg_subnet" ]; then
            smb_hosts_deny="$wg_subnet"
          fi
          share_nfs_spec=$(nfs_spec_from_cidrs "''${share_allow[$name]}")
        else
          # DENY-ALL: not listed. hosts allow = 127.0.0.1 only.
          scoped=denied
          smb_hosts_allow="127.0.0.1"
          # NFS: no export at all (empty spec).
        fi

        [ -n "$share_nfs_spec" ] && echo "$d$share_nfs_spec" >> "$exports"

        resolve_acl "$name"

        # ── Samba ──
        # CRITICAL: Samba interprets `valid users =` (empty) as "any user
        # may login" — the opposite of deny-by-default. So if a share has
        # no nas_acl grants and no guest access, skip the [share] block
        # entirely rather than emitting an empty valid users. Missing block
        # = the share doesn't exist to Samba (no browse, no tconx, no auth
        # attempts possible).
        valid="$ro_users$rw_users"
        { [ "$guest_r" = yes ] || [ "$guest_rw" = yes ]; } && valid="$valid nobody"
        write="$rw_users"; [ "$guest_rw" = yes ] && write="$write nobody"
        smb_emitted=no
        if [ -n "$valid" ]; then
          smb_emitted=yes
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
            [ -n "$smb_hosts_allow" ] && echo "  hosts allow = $smb_hosts_allow"
            [ -n "$smb_hosts_deny" ] && echo "  hosts deny = $smb_hosts_deny"
          } >> "$smbinc"
        fi

        # ── copyparty volume ──
        # Same reasoning: emit no volume block for shares with no accs, so
        # they don't appear in copyparty's volume tree at all.
        r_list="$ro_users"; [ "$guest_r" = yes ] && r_list="$r_list *"
        rwmd_list="$rw_users"; [ "$guest_rw" = yes ] && rwmd_list="$rwmd_list *"
        cp_emitted=no
        if [ -n "$r_list" ] || [ -n "$rwmd_list" ]; then
          cp_emitted=yes
          {
            echo "[/$name]"
            echo "  $d"
            echo "  accs:"
            [ -n "$r_list" ] && echo "    r: $(commafy "$r_list")"
            [ -n "$rwmd_list" ] && echo "    rwmd: $(commafy "$rwmd_list")"
          } >> "$cpconf"
        fi

        # Report: list protocols the share is actually exposed on.
        protos=""
        [ "$smb_emitted" = yes ] && protos="$protos smb"
        [ "$cp_emitted" = yes ]  && protos="$protos web"
        [ -n "$share_nfs_spec" ] && protos="$protos nfs"
        protos="''${protos# }"
        case "$scoped" in
          yes)    scope_tag=" [scoped: ''${share_allow[$name]}]" ;;
          denied) scope_tag=" [DENIED — add a rule to $hosts_file]" ;;
        esac
        if [ -z "$protos" ]; then
          echo "nas-shares: skipping '$name' — no nas_acl grants and no nas_hosts entry (nothing to expose)$scope_tag"
        else
          echo "nas-shares: serving '$name' ($protos)$scope_tag"
        fi
      done

      # Return the Samba parser to [global] after the share sections (the include
      # sits in [global] before the other globals alphabetically).
      echo "[global]" >> "$smbinc"

      # Warn about shares mentioned in nas_hosts that don't exist as
      # bind mounts — likely a typo or a share not added yet. Non-fatal.
      for s in "''${!share_seen[@]}"; do
        if [ ! -d "/srv/$s" ] || ! mountpoint -q "/srv/$s"; then
          echo "nas-shares: WARNING: $hosts_file references share '$s' but /srv/$s is not a bind mount — grants ignored." >&2
        fi
      done

      # copyparty config holds plaintext passwords → readable only by root + nas.
      chown root:nas "$cpconf" 2>/dev/null || true
      chmod 0640 "$cpconf" 2>/dev/null || true

      exportfs -ra 2>/dev/null || true
      smbcontrol smbd reload-config 2>/dev/null || true
      # Apply config changes on a re-run (e.g. after sync-identity); on first boot
      # copyparty hasn't started yet (it bindsTo this unit) so this no-ops.
      systemctl try-restart copyparty.service 2>/dev/null || true
    '';
  };

  # Firewall ports are NOT opened in the image. The SMB/NFS/copyparty/discovery
  # ports are seeded into the machine config's tcp_ports/udp_ports at create time
  # (visible, user-editable). Those drive BOTH the container firewall and the
  # Proxmox CT firewall — one place to control, nothing hidden in the profile.

  environment.systemPackages = [ pkgs.nfs-utils ];
}
