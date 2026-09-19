# WireGuard VPN

Set up a WireGuard tunnel across your managed VMs and remote clients using the
[`wireguard`](PROFILES.md#available-profiles) profile. Each peer's config lives
in `machines/<name>/wireguard.conf` (mode 0600) on the workstation and is
synced into the guest at create/upgrade time. The private key is pinned in that
file, so `recreate` and `upgrade` preserve the tunnel identity.

The fastest path is `just wireguard-init`, which mints all keys and configs at
once. The [By hand](#by-hand) appendix keeps the manual steps as a fallback.

## Preconditions

- Proxmox LXC backend configured — see [PROXMOX_LXC.md](PROXMOX_LXC.md).
- The Proxmox host kernel has the `wireguard` module (`modprobe wireguard` on
  the host if `lsmod | grep -q wireguard` is empty).
- A reachable endpoint for the hub — public IP or DDNS name with UDP 51820
  forwarded through any NAT.

## 1. Run the wizard

```bash
just wireguard-init
```

It prompts for:

- **Subnet** — CIDR of the VPN, default `10.0.0.0/24`.
- **Topology** — hub-and-spoke (one listener, spokes route through it) or
  full mesh (every peer connects to every other).
- **Peers** — for each: name, role (listener with a public Endpoint vs
  roaming client), `ListenPort` and Endpoint if listener, and the peer's
  tunnel address (auto-suggested for `/24` subnets).

It writes to `./wireguard-YYYYMMDD-HHMMSS/` (path is prompted, so you can
change it) — one `.key` / `.pub` / `.conf` per peer plus a `README.txt`.

If any peer name matches an existing entry under
`$XDG_CONFIG_HOME/nixos-vm-template/machines/<backend>/<host>/`, the wizard
offers to copy that peer's `.conf` straight into
`machines/<name>/wireguard.conf` and reminds you to `just upgrade <name>`.

The wizard also writes `.wg-state.edn` alongside the configs — a small
metadata file (subnet, topology, per-peer name/address/pubkey/endpoint) used
by `wireguard-add-peer` to add a peer later. Private keys stay in
`<peer>.key`, never in the state file.

## 2. Add a peer later

```bash
just wireguard-add-peer                       # newest ./wireguard-*/ in CWD
just wireguard-add-peer ./wireguard-20260101-120000
```

Reads `.wg-state.edn`, prompts for one new peer (name, role, address,
endpoint), then:

- Moves every existing `.conf`/`.key`/`.pub`/`README.txt`/`.wg-state.edn`
  into `<out-dir>/backup-<timestamp>/`.
- Regenerates **every** peer's config so the new peer is fully connected.
- Rewrites `.wg-state.edn`.
- Offers to copy any changed config into `machines/<name>/wireguard.conf`
  for matching peers.

Because existing peers' configs change too (they gain a `[Peer]` block for
the newcomer), redeploy any peer you didn't apply through the wizard
(`just upgrade <name>` for repo VMs, `sudo wg-quick down wg0 && sudo
wg-quick up wg0` for generic clients).

## 3. Deploy each peer's config

- **A VM in this repo** — copy `<peer>.conf` to
  `machines/<peer>/wireguard.conf` (the wizard offers to do this for you) and
  run `just upgrade <peer>`. The nas hub also needs `nas` in its profile and
  UDP `51820` (or your `ListenPort`) in `machines/<peer>/udp_ports`.
- **A generic Linux client** — write it to `/etc/wireguard/wg0.conf`
  (mode 0600), then `sudo wg-quick up wg0` and `sudo systemctl enable
  wg-quick@wg0`.
- **A phone** — import `<peer>.conf` into the WireGuard app (or scan its QR
  code with `nix shell nixpkgs#qrencode -c qrencode -t ansiutf8 < peer.conf`).

## 4. Verify

From any peer:

```bash
sudo wg show                        # every peer should have a recent handshake
ping <hub-tunnel-address>           # reach the hub over the tunnel
```

## 5. Serve Samba over the VPN

Add a user and grant access on the nas hub:

```
# machines/<hub>/nas_passwd  (mode 0600)
alice  s3cret

# machines/<hub>/nas_acl
alice  *  rw
```

Apply:

```bash
just upgrade <hub>
```

From a remote peer over the VPN:

```bash
smbclient -U alice //<hub-tunnel-address>/nas
# or persistent mount:
sudo mount -t cifs //<hub-tunnel-address>/nas /mnt -o username=alice,uid=$(id -u)
```

See [PROXMOX_LXC.md](PROXMOX_LXC.md) for the full `nas_acl` grammar.

## Troubleshooting

**No handshakes** (`latest handshake:` missing in `wg show`)
- UDP `ListenPort` blocked at the hub's NAT/firewall. Test with `sudo nc -ul
  51820` on the hub and `nc -u <hub-endpoint> 51820` from the peer.
- Client `Endpoint` points to a stale IP or wrong port.
- `AllowedIPs` on the hub doesn't cover the client's tunnel address.

**Tunnel up, Samba unreachable**
- Confirm Samba is listening: `sudo ss -tlnp | grep :445` on the hub.
- ACL entry missing — check `machines/<hub>/nas_acl` and re-apply.

**Config change not applied after edit**
- `just upgrade <name>` reinjects `wireguard.conf` and restarts wg-quick.
- Ad-hoc reload inside the guest: `sudo systemctl restart wg-quick-wg0` — the
  change reverts on next recreate unless `machines/<name>/wireguard.conf` is
  updated too.

## By hand

The wizard automates these steps; use them if you'd rather build the config
piece by piece, or need to add a single peer to an existing deployment.

**Extra precondition:** `nix shell nixpkgs#wireguard-tools` for `wg genkey` /
`wg pubkey`.

### 1. Create the nas + wireguard container

```bash
just create mynas nas,wireguard
```

Seeds `machines/mynas/wireguard.conf` (fresh keypair, `Address = 10.0.0.2/24`,
`ListenPort = 51820`, commented `[Peer]` template) plus `udp_ports` (`51820`
already listed) and the nas identity files.

Note the public key for later:

```bash
grep '^# Public key' machines/mynas/wireguard.conf
```

### 2. Make the nas the hub

Edit `machines/mynas/wireguard.conf` and change the address to `.1`:

```ini
[Interface]
PrivateKey = <keep the seeded value>
Address    = 10.0.0.1/24
ListenPort = 51820
```

### 3. Mint keys for each remote peer

On the workstation, once per client:

```bash
umask 077
wg genkey | tee peer1.key | wg pubkey > peer1.pub
```

### 4. Add `[Peer]` blocks to the hub config

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

### 5. Apply on the hub

```bash
just upgrade mynas
```

### 6. Configure each remote peer

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

### Full mesh

The wizard emits full-mesh configs directly; the manual differences are:

- Every peer has a `[Peer]` block for every other peer.
- Set `Endpoint = <host>:<port>` on each block where that peer accepts inbound
  connections; omit it for roaming clients that only dial out.
- Keep `AllowedIPs` narrow (`10.0.0.X/32`) per peer so the routing table stays
  unambiguous.
