# WireGuard VPN

Set up a WireGuard tunnel across your managed VMs and remote clients using the
[`wireguard`](PROFILES.md#available-profiles) profile. Each peer's config lives
in `machines/<name>/wireguard.conf` (mode 0600) on the workstation and is
synced into the guest at create/upgrade time. The private key is pinned in that
file, so `recreate` and `upgrade` preserve the tunnel identity.

The fastest path is `just wireguard-init`, which mints all keys and configs at
once. The [By hand](#by-hand) appendix keeps the manual steps as a fallback.

This walkthrough uses the Proxmox LXC backend because the hub is built on the
[`nas`](PROFILES.md#available-profiles) profile (Samba + NFS), which is
LXC-only. WireGuard itself is backend-agnostic — the `wireguard` profile works
the same way on any libvirt or Proxmox KVM VM. On KVM, skip the nas/Samba
sections below and use a plain `wireguard` VM as the hub (or any other
profile that suits the services you want to expose over the tunnel).

## Preconditions

- Proxmox LXC backend configured — see [PROXMOX_LXC.md](PROXMOX_LXC.md).
  (Not needed if you're only running WireGuard on KVM VMs.)
- On Proxmox LXC: the Proxmox host kernel has the `wireguard` module
  (`modprobe wireguard` on the host if `lsmod | grep -q wireguard` is empty).
  KVM guests bring their own kernel, so this doesn't apply there.
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
  run `just upgrade <peer>`. The hub also needs UDP `51820` (or your
  `ListenPort`) in `machines/<peer>/udp_ports`, and any peer that expects
  inbound wg traffic needs allow rules in `machines/<peer>/wireguard.nft`
  (see [Peer ACL](#peer-acl-wireguardnft) — default is deny). Profile
  choice is made at `just create` time — see [By hand § 1](#1-create-the-nas--wireguard-container).
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

## Peer ACL (`wireguard.nft`)

Every VM with the `wireguard` profile loads an nftables table
(`inet wireguard`) at boot that governs wg0 traffic on that peer.
The rules body lives at `machines/<name>/wireguard.nft` and is seeded
(all-commented) by `just create` alongside `wireguard.conf`.

**Two chains, both default-drop.**

- **`wg-input`** — traffic from wg0 hitting **this peer's** own services
  (SSH, Samba, NFS, whatever the VM runs). Applies to every peer,
  including hubs. Because `wg0` is set trusted, this chain is the sole
  authority for wg-side port exposure — `tcp_ports`/`udp_ports` do
  **not** apply to wg traffic.
- **`wg-forward`** — traffic transiting between wg peers through this
  peer. Only meaningful when this peer is a hub; on spokes leave the
  chain with only its `drop` rule.

**Default is deny-everything.** If `wireguard.nft` is missing, or a
chain body is missing here, the service synthesizes a drop-only chain
for that direction. A VM with the `wireguard` profile but no ACL file
has wg0 fully locked down — you *have* to write accept rules to reach
this peer over the tunnel. Delete a chain to keep it locked down.

**Peer names.** The service parses `# hostname: <name>` comments in
this VM's `wireguard.conf` (both `[Interface]` and each `[Peer]`
block) and emits nftables `define <name> = <ipv4>` variables. Reference
them as `$name` in rules. The wizard writes these comments; hand-written
configs need to add them (or reference peers by bare IP).

**Rule syntax.** Standard nftables expressions (see `man nft`). Reply
traffic is handled by conntrack — only describe *new* connections to
permit. Both chains end with `drop`.

```
# machines/<peer>/wireguard.nft — examples
chain wg-input {
  ct state established,related accept
  ip saddr $laptop tcp dport 22  accept    # SSH from laptop peer
  ip saddr $laptop tcp dport 445 accept    # Samba
  ip saddr $admin               accept    # broad allow for admin peer
  drop
}

chain wg-forward {
  ct state established,related accept
  ip saddr $laptop ip daddr $nas               accept   # laptop -> nas
  ip saddr $phone  ip daddr $nas tcp dport 445 accept   # phone -> nas Samba
  drop
}
```

Apply changes with `just upgrade <name>` (immutable) or
`just sync-identity <name>` + `sudo systemctl restart wireguard-nft`
inside the guest (mutable). Verify:

```bash
sudo nft list table inet wireguard    # sees $peer defines + both chains
```

## Troubleshooting

**No handshakes** (`latest handshake:` missing in `wg show`)
- UDP `ListenPort` blocked at the hub's NAT/firewall. Test with `sudo nc -ul
  51820` on the hub and `nc -u <hub-endpoint> 51820` from the peer.
- Client `Endpoint` points to a stale IP or wrong port.
- `AllowedIPs` on the hub doesn't cover the client's tunnel address.

**Tunnel up, Samba unreachable**
- Confirm Samba is listening: `sudo ss -tlnp | grep :445` on the hub.
- ACL entry missing — check `machines/<hub>/nas_acl` and re-apply.
- Peer ACL dropping the traffic — check `sudo nft list table inet
  wireguard` on the hub. The `wg-input` chain must explicitly allow the
  spoke (e.g. `ip saddr $laptop tcp dport 445 accept`); see
  [Peer ACL](#peer-acl-wireguardnft).

**Spoke-to-spoke traffic silently dropped**
- Expected when the hub's `wireguard.nft` `wg-forward` chain has no
  matching allow rule (default is deny). Uncomment or add rules, then
  `just upgrade <hub>` (or restart the `wireguard-nft` unit on the hub).
- Rules using `$peer` names silently drop packets if the hub's
  `wireguard.conf` has no matching `# hostname: <peer>` comment — check
  with `sudo nft list table inet wireguard` and confirm the `define
  <peer> = ...` line is present.

**Config change not applied after edit**
- `just upgrade <name>` reinjects `wireguard.conf` and restarts wg-quick.
- Ad-hoc reload inside the guest: `sudo systemctl restart wg-quick-wg0` — the
  change reverts on next recreate unless `machines/<name>/wireguard.conf` is
  updated too.

## Linux NetworkManager client

Import `<peer>.conf` as a system connection so the NM applet lists it as a
toggleable VPN:

```bash
sudo nmcli connection import type wireguard file <peer>.conf
```

The connection id and interface name both take the filename stem. To rename
both (the applet displays the interface name, not the connection id):

```bash
sudo nmcli connection modify <peer> connection.id NAS
sudo nmcli connection down NAS 2>/dev/null
sudo nmcli connection modify NAS connection.interface-name nas
sudo nmcli connection up NAS
```

Interface name: ≤ 15 chars, `[a-z0-9_-]`.

- **Autostart on boot:** `sudo nmcli connection modify NAS connection.autoconnect yes`
- **Caveat:** NM ignores `PreUp`/`PostUp`/`PreDown`/`PostDown` hooks in `.conf`.
  Use `wg-quick@wg0.service` if you need those.

Verify:

```bash
nmcli connection show NAS
ip link show nas
sudo wg show
```

## Windows / macOS client

The official [WireGuard](https://www.wireguard.com/install/) client (Windows:
installer or Microsoft Store; macOS: Mac App Store) lives in the system tray
/ menu bar. "Import tunnel(s) from file" ingests `<peer>.conf` from the
wizard's output directory; each tunnel then gets an Activate/Deactivate
toggle from the tray/menu icon.

- **Auto-start on boot / login:**
  - Windows: the installer registers a `WireGuardTunnel$<name>` service per
    tunnel — set it to Automatic (or tick "Enable on boot" in the client).
  - macOS: tick "On-Demand" (or "Include this tunnel when enabling
    On-Demand") per tunnel; the NetworkExtension keeps it up across reboots
    and can auto-activate on specific Wi-Fi/Ethernet networks.
- **Split vs full tunnel:** a spoke config from the wizard uses
  `AllowedIPs = <subnet>`, so only that subnet routes through the tunnel.
  For full-tunnel VPN, edit the tunnel and change `AllowedIPs` to
  `0.0.0.0/0, ::/0`.
- **macOS requirement:** 10.14+ (uses NetworkExtension; no kernel extension).

## By hand

The wizard automates these steps; use them if you'd rather build the config
piece by piece, or need to add a single peer to an existing deployment.

**Extra precondition:** `nix shell nixpkgs#wireguard-tools` for `wg genkey` /
`wg pubkey`.

### 1. Create the nas + wireguard container

```bash
just create mynas nas,wireguard
```

There is a single `wireguard` profile for every peer (client or hub
alike); role differentiation happens in `wireguard.nft`. On a hub, add
allow rules to `wg-forward`; on a spoke, leave that chain default-drop.
On a multi-NIC VM (multiple bridges, wlan0+eth0), be aware that IP
forwarding is enabled globally by the profile — non-wg forwarding
paths aren't filtered by this ACL.

Seeds `machines/mynas/wireguard.conf` (fresh keypair, `Address = 10.0.0.2/24`,
`ListenPort = 51820`, commented `[Peer]` template) plus `udp_ports` (`51820`
already listed), an all-commented `wireguard.nft` (peer ACL — see
[Peer ACL](#peer-acl-wireguardnft)), and the nas identity files.

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
