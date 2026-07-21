# Client-side CIFS/SMB mounts driven by two per-VM identity files. Read at
# boot from /var/identity, so nothing about specific servers or credentials
# leaks into the shared base image or the nix store.
#
# /var/identity/samba_credentials      chmod 0600
#   mount.cifs credentials-file format:
#     username=<user>
#     password=<pass>
#     domain=<workgroup>        # optional
#
# /var/identity/samba_client_shares    chmod 0644
#   One share per line, whitespace-separated:
#     <mount-point>  <//server/share>  [extra,mount,opts]
#   Blank lines and lines starting with `#` are ignored.
#   Example:
#     /home/user/ROMs  //nas.local/roms
#     /mnt/media       //10.0.0.5/media  ro
#
# On boot, samba-client-mounts reads the shares file and generates a
# `<escaped>.mount` + `<escaped>.automount` unit pair per line under
# /run/systemd/system, then starts the automount units. Access to the mount
# point triggers the actual CIFS mount on demand, so an unreachable NAS
# never blocks boot. Each mount point is created (chown to the regular
# user) if it doesn't already exist, so `/home/user/ROMs` etc. just work.
#
# Put both files under machines/<name>/ (or wherever your workflow keeps
# per-machine identity) and they'll be synced to /var/identity/ during
# create/upgrade like every other identity file.

{ config, lib, pkgs, ... }:

let
  user = config.core.regularUser;
in
{
  environment.systemPackages = [ pkgs.cifs-utils ];

  systemd.services.samba-client-mounts = {
    description = "Generate CIFS mount+automount units from /var/identity/samba_client_shares";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [ coreutils systemd cifs-utils util-linux ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -u
      shares=/var/identity/samba_client_shares
      creds=/var/identity/samba_credentials
      [ -f "$shares" ] || exit 0
      [ -f "$creds" ] || { echo "samba-client-mounts: $creds missing" >&2; exit 1; }

      runtime=/run/systemd/system
      mkdir -p "$runtime"

      uid=$(id -u ${user}) || uid=1001
      gid=$(id -g ${user}) || gid=100

      to_start=""
      while IFS=$' \t' read -r mp dev extras || [ -n "$mp" ]; do
        case "$mp" in ""|\#*) continue;; esac
        if [ -z "$dev" ]; then
          echo "samba-client-mounts: no device for '$mp' — skipping" >&2
          continue
        fi

        unit=$(systemd-escape --path "$mp")
        mount_unit="$runtime/$unit.mount"
        auto_unit="$runtime/$unit.automount"
        extras_norm="''${extras:-}"

        {
          echo "[Unit]"
          echo "Description=CIFS mount $mp"
          echo "After=network-online.target"
          echo "Wants=network-online.target"
          echo ""
          echo "[Mount]"
          echo "What=$dev"
          echo "Where=$mp"
          echo "Type=cifs"
          opts="credentials=$creds,uid=$uid,gid=$gid"
          opts="$opts,file_mode=0664,dir_mode=0775,iocharset=utf8,nofail"
          [ -n "$extras_norm" ] && opts="$opts,$extras_norm"
          echo "Options=$opts"
        } > "$mount_unit"

        {
          echo "[Unit]"
          echo "Description=CIFS automount $mp"
          echo ""
          echo "[Automount]"
          echo "Where=$mp"
        } > "$auto_unit"

        # Mount point directory: created (once) so systemd has somewhere to
        # attach the automount. Owned by the regular user so apps running
        # as that user can read/write the mounted share.
        mkdir -p "$mp"
        chown "$uid":"$gid" "$mp" 2>/dev/null || true

        to_start="$to_start $unit.automount"
      done < "$shares"

      if [ -n "$to_start" ]; then
        systemctl daemon-reload
        # shellcheck disable=SC2086
        systemctl start $to_start
      fi
    '';
  };
}
