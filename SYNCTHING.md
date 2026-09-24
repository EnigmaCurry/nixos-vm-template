# Syncthing

Peer-to-peer file sync on the [`syncthing`](PROFILES.md#available-profiles)
profile. Device identity, peer table, and folder table live in the machine
directory on the workstation and are synced into the guest at create/upgrade
time. A boot service (`syncthing-config`) reconciles syncthing's running config
to match those files on every start — the files are **authoritative**, GUI
additions are pruned on the next `sync-identity` / `upgrade`.

## Preconditions

- A machine with the `syncthing` profile — either bundled with `nas`
  (LXC, shares data under `/srv/*`) or standalone on any backend (data under
  `/var/lib/syncthing`).
- On LXC, use the `nas,syncthing` combo when you want syncthing folders to
  point at ZFS bind mounts under `/srv/*` served by Samba/NFS/copyparty.

## 1. Create the VM

```bash
just create nas nas,syncthing         # or `syncthing` alone
```

Seeds:

- `machines/nas/syncthing_cert.pem`, `syncthing_key.pem` (mode 0600) —
  pinned device identity generated once via `syncthing generate`. Preserved
  across `recreate`.
- `machines/nas/syncthing_devices` — peer table template (all-commented).
- `machines/nas/syncthing_folders` — folder table template (all-commented).
- Sync port `22000/tcp+udp` and LAN discovery `21027/udp` in
  `machines/nas/{tcp,udp}_ports`, seeded commented so operators opt in.

The command prints this machine's syncthing device ID — save it, remote
peers need it. To fetch it later, either read it from the GUI (Actions →
Show ID) on the running VM, or re-derive from the workstation:

```bash
tmp=$(mktemp -d)
cp machines/nas/syncthing_cert.pem $tmp/cert.pem
cp machines/nas/syncthing_key.pem  $tmp/key.pem
nix run nixpkgs#syncthing -- --home=$tmp device-id
rm -rf $tmp
```

## 2. Collect peer device IDs

For each peer you want to sync with, get its 63-character device ID:

- **Another VM in this repo** — follow §1 for that machine; the ID prints at
  create time.
- **A phone / desktop syncthing** — open the app, Actions → Show ID.
- **Any running syncthing** —
  `syncthing --home=<config-dir> device-id`.

## 3. Populate `syncthing_devices`

`machines/<name>/syncthing_devices` — one line per peer:

```
<peer-name>  <device-id>  [address]...
```

- `<peer-name>` is a local alias, referenced from `syncthing_folders`.
- `[address]` is optional and pins where THIS machine reaches that peer:
  `tcp://host:port`, `quic://host:port`, or the literal `dynamic` (default —
  use discovery). Omit the column entirely for automatic discovery.

Example:

```
laptop     3TYBOKV-RPKZLFT-GFQDTZW-S7XYPHO-2Q3LVFT-WUCQ5BR-LBFVJHX-NRZ3QQL
phone      7CFNTQM-IMTJBHJ-3UWRDIU-ZGQJFR6-VCXZ3NB-XUH3KZO-N52ITXR-LAIYUAU  tcp://10.13.17.3:22000
```

## 4. Populate `syncthing_folders`

`machines/<name>/syncthing_folders` — one line per folder:

```
<folder-id>  <path>  [peer-name]...
```

- `<folder-id>` is short and unique; must match the id used on other peers
  sharing this folder.
- `<path>` is absolute on this VM. With the `nas` profile bundled, point at
  `/srv/<share>` to sync a bind-mounted dataset that Samba/NFS/copyparty
  also serves. Standalone: anywhere under `/var/lib/syncthing/` writable by
  the syncthing user.
- `[peer-name]...` — zero or more peer aliases from `syncthing_devices`.

Example:

```
docs      /srv/docs      laptop phone
backup    /srv/backup    laptop
```

## 5. Apply

```bash
just upgrade <name>           # or: just sync-identity <name>  (LXC only, faster)
```

`syncthing-config` runs after `syncthing.service` is up and reconciles
devices/folders. If reconciliation fails, `syncthing.service` is stopped via
`BindsTo` — fix the file and re-run.

## 6. Verify

On the VM:

```bash
sudo systemctl status syncthing-config --no-pager
sudo -u <user> STHOMEDIR=/var/lib/syncthing/.config/syncthing syncthing cli config devices list
sudo -u <user> STHOMEDIR=/var/lib/syncthing/.config/syncthing syncthing cli config folders list
```

`<user>` is `nas` when bundled with the nas profile, otherwise `syncthing`.
Both lists should match `syncthing_devices` / `syncthing_folders` exactly
(plus the local device in `devices list`, which is never deleted).

Confirm no leftover "new device" prompts remain in the GUI on the peers.

## Composition with wireguard

When the `wireguard` profile is also enabled AND `wg0` is up at reconcile
time, `syncthing-config` confines syncthing to the tunnel:

- `listenAddresses` bound to `tcp://<wg-ip>:22000` and `quic://<wg-ip>:22000`
  only — the LAN interface stops accepting the sync port.
- `globalAnnounceEnabled`, `localAnnounceEnabled`, `relaysEnabled`,
  `natEnabled` all set to `false` — no `discovery.syncthing.net`, no LAN
  broadcast, no relays, no UPnP/NAT-PMP.
- Peers must know your wg IP and be routable to it — pin their wg address in
  `syncthing_devices` (see §3) to keep outbound over wg too.

Without `wg0` present, the reconciler restores syncthing's stock defaults
(all interfaces, discovery + relays + NAT-PMP on) — so removing the
`wireguard` profile later cleanly rolls back.

You also need to allow the sync port on the wg side. In
`machines/<name>/wireguard.nft`:

```nft
chain wg-input {
  ct state established,related accept
  ip saddr $laptop tcp dport 22000 accept    # syncthing from laptop peer
  ip saddr $laptop udp dport 22000 accept
  drop
}
```

See [WIREGUARD.md § Peer ACL](WIREGUARD.md#peer-acl-wireguardnft) for the
full chain reference. `tcp_ports`/`udp_ports` don't apply on the wg side.

## Composition with nas

Bundling `nas,syncthing` sets:

- syncthing runs as the shared `nas` user (uid 1500) so files written into
  `/srv/<share>` have the same ownership as those written by Samba/NFS/copyparty.
- Folder paths default to `/srv/<share>` conventionally — syncing files that
  are simultaneously exposed over SMB/NFS/WebDAV.

No extra configuration required beyond adding both profiles at create time.

## Exposing the GUI via traefik

The GUI listens on `127.0.0.1:8384` only. To expose it, add a router to
`machines/<name>/traefik/dynamic/*.yml`:

```yaml
http:
  routers:
    syncthing:
      rule: "Host(`syncthing.example.com`)"
      entryPoints: [websecure]
      # wg-required is the sole auth layer — syncthing can't consume an
      # injected X-Remote-User. Layer a GUI password on top via
      # services.syncthing.settings.gui.{user,password} if you want
      # defense-in-depth.
      middlewares: [wg-required]
      service: syncthing
      tls:
        certResolver: letsencrypt
        domains:
          - main: "*.example.com"
  services:
    syncthing:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8384"
```

Then `just sync-identity <name>`; traefik hot-reloads the file provider.
Requires the `traefik` + `wireguard` profiles (for `wg-required`); see
[TRAEFIK.md](TRAEFIK.md).

## Troubleshooting

**`syncthing-config` fails with "could not reach syncthing REST API after 60s"**
- The reconciler couldn't authenticate with the running daemon. Check
  `STHOMEDIR` in the journal output (`sudo journalctl -u syncthing-config`);
  it must match the daemon's `configDir` (defaults to
  `/var/lib/syncthing/.config/syncthing`).
- `/etc/syncthing` (or `/var/identity/syncthing` on KVM) must be mode `0755`
  so the syncthing user can read the manifests inside.

**Peer shows as "new device" in GUI even though it's in `syncthing_devices`**
- The reconciler couldn't parse the file. Verify with
  `sudo systemctl status syncthing-config` and re-run
  `sudo systemctl restart syncthing-config`.
- Confirm the file's ownership lets the syncthing user read it —
  `sudo -u <syncthing-user> cat /etc/syncthing/syncthing_devices` should
  succeed.

**GUI returns "Host check error" through traefik**
- The `insecureSkipHostcheck` GUI setting isn't in effect. Restart
  `syncthing.service` (the setting is applied by `syncthing-init` after
  the daemon starts).

**Peer connects over LAN instead of wg**
- Confirm `wg0` was up when `syncthing-config` last ran — check the journal
  for `binding listen addresses to wg0 (…)`. If it says "wg0 not present",
  restart the service after `wg-quick-wg0` is up:
  `sudo systemctl restart syncthing-config`.
- Confirm the peer's address is pinned in `syncthing_devices` (see §3);
  without a pin, syncthing picks the "best" advertised address, which may
  be LAN.
