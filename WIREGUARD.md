# WireGuard VPN

Set up a WireGuard tunnel across your managed VMs and remote clients using the
[`wireguard`](PROFILES.md#available-profiles) profile. Each peer's config lives
in `machines/<name>/wireguard.conf` (mode 0600) on the workstation and is
synced into the guest at create/upgrade time. The private key is pinned in that
file, so `recreate` and `upgrade` preserve the tunnel identity.

The walkthrough below builds a **hub-and-spoke** VPN (all peers connect through
the nas host) and then serves Samba shares over the tunnel. A short
[full-mesh](#full-mesh) section covers direct peer-to-peer paths.

## Preconditions

- Proxmox LXC backend configured — see [PROXMOX_LXC.md](PROXMOX_LXC.md).
- The Proxmox host kernel has the `wireguard` module (`modprobe wireguard` on
  the host if `lsmod | grep -q wireguard` is empty).
- A reachable endpoint for the hub — public IP or DDNS name with UDP 51820
  forwarded through any NAT.
- `wireguard-tools` available locally to mint peer keys:
  `nix shell nixpkgs#wireguard-tools`.

## 1. Create the nas + wireguard container

```bash
just create mynas nas,wireguard
```

Seeds:

- `machines/mynas/wireguard.conf` — fresh keypair, `Address = 10.0.0.2/24`,
  `ListenPort = 51820`, commented `[Peer]` template.
- `machines/mynas/udp_ports` — `51820` already listed.
- The nas identity files (`nas_passwd`, `nas_acl`, `nfs_clients`).

Note the public key for later:

```bash
grep '^# Public key' machines/mynas/wireguard.conf
```

## 2. Make the nas the hub

Edit `machines/mynas/wireguard.conf` and change the address to `.1`:

```ini
[Interface]
PrivateKey = <keep the seeded value>
Address    = 10.0.0.1/24
ListenPort = 51820
```

## 3. Mint keys for each remote peer

On the workstation, once per client (laptop, phone, another VM):

```bash
umask 077
wg genkey | tee peer1.key | wg pubkey > peer1.pub
```

## 4. Add [Peer] blocks to the hub config

Append to `machines/mynas/wireguard.conf` — one block per remote:

```ini
[Peer]
# laptop
PublicKey  = <contents of peer1.pub>
AllowedIPs = 10.0.0.2/32

[Peer]
# phone
PublicKey  = <contents of peer2.pub>
AllowedIPs = 10.0.0.3/32
```

## 5. Apply on the hub

```bash
just upgrade mynas
```

`upgrade` rebuilds the profile image and re-syncs identity files (including
`wireguard.conf`) into the container.

## 6. Configure each remote peer

**Another VM in this repo:** drop the following into
`machines/<clientname>/wireguard.conf` and `just upgrade <clientname>`.

**A generic Linux client:** write it to `/etc/wireguard/wg0.conf`
(mode 0600), then `sudo wg-quick up wg0` and `sudo systemctl enable
wg-quick@wg0`.

```ini
[Interface]
PrivateKey = <contents of peer1.key>
Address    = 10.0.0.2/32

[Peer]
PublicKey           = <nas public key from step 1>
Endpoint            = nas.example.com:51820
AllowedIPs          = 10.0.0.0/24
PersistentKeepalive = 25
```

## 7. Verify

From any peer:

```bash
sudo wg show                        # every peer should have a recent handshake
ping 10.0.0.1                       # reach the hub over the tunnel
```

## 8. Serve Samba over the VPN

Add a user and grant access on the nas:

```
# machines/mynas/nas_passwd  (mode 0600)
alice  s3cret

# machines/mynas/nas_acl
alice  *  rw
```

Apply:

```bash
just upgrade mynas
```

From a remote peer over the VPN:

```bash
smbclient -U alice //10.0.0.1/nas
# or persistent mount:
sudo mount -t cifs //10.0.0.1/nas /mnt -o username=alice,uid=$(id -u)
```

See [PROXMOX_LXC.md](PROXMOX_LXC.md) for the full `nas_acl` grammar.

## Full mesh

Hub-and-spoke forces all peer-to-peer traffic through the hub. To let clients
talk directly to each other:

- Every peer must have a `[Peer]` block for every other peer.
- Set `Endpoint = <host>:<port>` on each block where that peer accepts inbound
  connections; omit it for roaming clients that only dial out.
- Keep `AllowedIPs` narrow (`10.0.0.X/32`) per peer so the routing table stays
  unambiguous.

## Troubleshooting

**No handshakes** (`latest handshake:` missing in `wg show`)
- UDP 51820 blocked at the hub's NAT/firewall. Test with `sudo nc -ul 51820`
  on the hub and `nc -u <hub-endpoint> 51820` from the peer.
- Client `Endpoint` points to a stale IP or wrong port.
- `AllowedIPs` on the hub doesn't cover the client's tunnel address.

**Tunnel up, Samba unreachable**
- Confirm Samba is listening: `sudo ss -tlnp | grep :445` on the nas.
- ACL entry missing — check `machines/mynas/nas_acl` and re-apply.

**Config change not applied after edit**
- `just upgrade <name>` reinjects `wireguard.conf` and restarts wg-quick.
- Ad-hoc reload inside the guest: `sudo systemctl restart wg-quick-wg0` — the
  change reverts on next recreate unless `machines/<name>/wireguard.conf` is
  updated too.
