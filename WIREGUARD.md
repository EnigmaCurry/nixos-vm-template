# WireGuard VPN

Set up a WireGuard tunnel across your managed VMs and remote clients using the
[`wireguard`](PROFILES.md#available-profiles) profile. Each peer's config lives
in `machines/<name>/wireguard.conf` (mode 0600) on the workstation and is
synced into the guest at create/upgrade time. The private key is pinned in that
file, so `recreate` and `upgrade` preserve the tunnel identity.

The fastest path is `just wireguard <hub>`. First run mints all keys and
configs at once under `machines/<hub>/wireguard/`; subsequent runs open a
menu (add peer, change endpoint, edit addresses, rename, remove). The
[By hand](#by-hand) appendix keeps the manual steps as a fallback.

**Do not hand-edit the generated `.conf` files.** They are regenerated
from `machines/<hub>/wireguard/.wg-state.edn` every time `just wireguard`
runs and any manual edits will be discarded. Use the menu instead.

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
just wireguard <hub>
```

`<hub>` must be an existing machine (create it first with
`just create <hub> wireguard`).

**First run** — with no state in `machines/<hub>/wireguard/`, the command
prompts for:

- **Subnet** — CIDR of the VPN, default `10.0.0.0/24`.
- **Hub peer** — `ListenPort` (default `51820`), public `Endpoint` (host or
  IP that spokes dial), and tunnel address (default `.1` on a `/24`). The
  hub's peer name is fixed to `<hub>`.
- **Spoke peers** — for each: name and tunnel address (auto-suggested for
  `/24` subnets).

It writes to `machines/<hub>/wireguard/` — one `.key` / `.pub` / `.conf` per
peer plus `README.txt` and `.wg-state.edn` — and copies the hub's config
to `machines/<hub>/wireguard.conf` so `just upgrade <hub>` picks it up.

If any spoke peer name matches another entry under
`$XDG_CONFIG_HOME/nixos-vm-template/machines/<backend>/<host>/`, the wizard
offers to copy that spoke's `.conf` straight into
`machines/<spoke>/wireguard.conf` and reminds you to `just upgrade <spoke>`.

Private keys stay in `<peer>.key`, never in the state file.

## 2. Add or edit peers later

Run the same command:

```bash
just wireguard <hub>
```

With existing state it drops into a menu:

- **Add spoke peer** — mints a keypair and appends the peer.
- **Add / remove address** — manage the multi-address list on any peer
  (add IPv6, add a secondary v4, etc.).
- **Rename a spoke**.
- **Remove a spoke**.
- **Change hub endpoint** or **listen-port**.
- **Apply changes and regenerate** — commits the queued changes.
- **Quit without saving**.

Changes are queued in memory; nothing on disk moves until you pick Apply.
When you do:

- Moves every existing `.conf`/`.key`/`.pub`/`README.txt`/`.wg-state.edn`
  plus `machines/<hub>/wireguard.conf` into
  `machines/<hub>/wireguard/backup-<timestamp>/`.
- Regenerates **every** peer's config so the new topology is consistent.
- Rewrites `.wg-state.edn` and `machines/<hub>/wireguard.conf`.
- Offers to copy any changed spoke config into `machines/<name>/wireguard.conf`
  for matching peers.

Because existing peers' configs change too, redeploy any peer you didn't
apply through the wizard (`just upgrade <name>` for repo VMs, `sudo
wg-quick down wg0 && sudo wg-quick up wg0` for generic clients).

## 3. Deploy each peer's config

- **The hub** — `just upgrade <hub>`. UDP `51820` (or your `ListenPort`) is
  already in `machines/<hub>/udp_ports` from the `wireguard` profile. Any
  peer that expects inbound wg traffic needs allow rules in
  `machines/<peer>/wireguard.nft` (see [Peer ACL](#peer-acl-wireguardnft) —
  default is deny).
- **Another VM in this repo** — the wizard offers to copy `<peer>.conf` to
  `machines/<peer>/wireguard.conf` for you; then `just upgrade <peer>`.
  Profile choice is made at `just create` time — see
  [By hand § 1](#1-create-the-nas--wireguard-container).
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

### Restricting shares to specific wg peers

`nas_acl` gates *who* can access each share (per-user, password-checked).
`nas_hosts` is the required network-layer gate underneath — a blank
file is **deny-all** (no share reachable). Every access is listed
explicitly, so a peer can't even attempt to open a share intended for
someone else.

One line per host, whitespace-separated: the host token followed by
every share that host is granted access to.

```
# <host-token>   <share>...
#
# <cidr>      literal CIDR, e.g. 192.168.1.0/24 or 10.0.0.5/32
# 0.0.0.0/0   any IPv4 host (fully open network layer)
# wg:<peer>   that wg peer's tunnel IP(s) (from wireguard.conf)
# wg:*        every wg peer currently in wireguard.conf
#
# The share list may be a specific share, or `*` = every /srv/* mount.
# Bare `*` is NOT accepted as a host — use 0.0.0.0/0 or wg:*.

wg:mike           mike-private family-shared mixed-share
wg:sarah          family-shared
wg:kids           family-shared
wg:*              public-over-wg
192.168.1.0/24    media-store mixed-share public-over-wg
0.0.0.0/0         guest pubdocs
wg:admin          *
```

- A host may appear on **at most one line** — put all of its shares
  together. Multiple hosts may reference the same share; the share's
  allow list is the union of every host that mentions it.
- **Deny-all default.** Shares no line mentions are unreachable (Samba
  `hosts allow = 127.0.0.1` only, no NFS export). Uncomment one of the
  quick-start examples in the seeded template to open things up.
- Emits Samba `hosts allow`/`hosts deny` per share, and substitutes
  the NFS export's client list to match.
- Password auth (`nas_acl`) still applies on top — this is a network
  gate underneath, not a replacement.

Apply:

```bash
just upgrade <hub>
```

Validation is pre-flight and strict: a duplicate host, unknown
`wg:` peer, unknown host token, or a `wg:` token when wireguard isn't
enabled fails the `nas-shares` unit before any config is written.
Samba/NFS/copyparty are `BindsTo`-coupled to `nas-shares`, so a bad
file **stops the file server** rather than serving stale/partial
config — you'll see the error inline in `just upgrade` output. See
[NAS_HOSTS.md](NAS_HOSTS.md) for the full policy table.

### Peer ACL on the hub

The wg-side firewall on the hub is default-deny. Drop something like this into
`machines/<hub>/wireguard.nft`, replace the peer names to match the ones you
gave the wizard, then re-run `just upgrade <hub>`:

```nft
# Group the peers allowed to reach hub services.
# Names come from `# hostname: <name>` in machines/<hub>/wireguard.conf.
set nas_clients {
  type ipv4_addr
  elements = { $flux, $appleM1, $pixel6 }
}

# Traffic from wg0 hitting THIS hub's services.
chain wg-input {
  ct state established,related accept
  # 22 = SSH, 445 = Samba, 3923 = copyparty (WebDAV).
  # (:443 for these peers is redirected to :3923 in wg-prerouting below,
  #  so it doesn't need a rule here — the rewrite fires before input.)
  ip saddr @nas_clients tcp dport { 22, 445, 3923 } accept
  drop
}

# Spoke-to-spoke traffic through the hub. Empty (only reply traffic) —
# spokes cannot reach each other unless you add allow rules here.
chain wg-forward {
  ct state established,related accept
  drop
}

# Optional: redirect wg-side :443 to a local reverse proxy on :3923.
# The rewritten dport still has to be allowed in wg-input above.
chain wg-prerouting {
  ip saddr @nas_clients tcp dport 443 redirect to :3923
}
```

See [Peer ACL](#peer-acl-wireguardnft) for the full chain reference.

## Peer ACL (`wireguard.nft`)

Every VM with the `wireguard` profile loads an nftables table
(`inet wireguard`) at boot that governs wg0 traffic on that peer.
The rules body lives at `machines/<name>/wireguard.nft` and is seeded
(all-commented) by `just create` alongside `wireguard.conf`.

**Three chains.**

- **`wg-input`** — traffic from wg0 hitting **this peer's** own services
  (SSH, Samba, NFS, whatever the VM runs). Applies to every peer,
  including hubs. Because `wg0` is set trusted, this chain is the sole
  authority for wg-side port exposure — `tcp_ports`/`udp_ports` do
  **not** apply to wg traffic. Default-drop.
- **`wg-forward`** — traffic transiting between wg peers through this
  peer. Only meaningful when this peer is a hub; on spokes leave the
  chain with only its `drop` rule. Default-drop.
- **`wg-prerouting`** — optional NAT prerouting for wg0 traffic
  (`redirect to :PORT`, `dnat to ADDR:PORT`). Fires before `wg-input`,
  so rewrites are visible to it. Only installed if this chain is present;
  unmatched packets fall through unchanged (no default deny).

**Default is deny-everything on the filter chains.** If `wireguard.nft`
is missing, or a `wg-input`/`wg-forward` chain body is missing here, the
service synthesizes a drop-only chain for that direction. A VM with the
`wireguard` profile but no ACL file has wg0 fully locked down — you
*have* to write accept rules to reach this peer over the tunnel. Delete
a chain to keep it locked down. `wg-prerouting` is opt-in: omit it and no
prerouting rewrites happen.

**Peer names.** The service parses `# hostname: <name>` comments in
this VM's `wireguard.conf` (both `[Interface]` and each `[Peer]`
block) and emits nftables `define <name> = <ipv4>` variables. Reference
them as `$name` in rules. The wizard writes these comments; hand-written
configs need to add them (or reference peers by bare IP).

**Rule syntax.** Standard nftables expressions (see `man nft`). Reply
traffic is handled by conntrack — only describe *new* connections to
permit. `wg-input` and `wg-forward` end with `drop`.

```
# machines/<peer>/wireguard.nft — examples
chain wg-input {
  ct state established,related accept
  # ICMP echo-request is auto-accepted by the hook chain before this
  # chain runs, so ping always works regardless of the rules below.
  ip saddr $laptop tcp dport 22  accept    # SSH from laptop peer
  ip saddr $laptop tcp dport 445 accept    # Samba
  ip saddr $admin                accept    # broad allow for admin peer
  drop
}

chain wg-forward {
  ct state established,related accept
  # wg-forward rules describe traffic passing THROUGH this hub between
  # two other peers. Traffic destined for this VM's own services goes
  # through wg-input instead — don't use the hub's own name here.
  ip saddr $laptop ip daddr $homeassistant               accept
  ip saddr $phone  ip daddr $homeassistant tcp dport 443 accept   # phone HTTPS
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

The connection id and interface name both take the filename stem, so rename
the `.conf` before importing to whatever you want the NM applet to show. On a
client `flux` connecting to a hub `NAS`, the wizard hands you `flux.conf`
(this client's identity); rename it to `NAS.conf` (the tunnel's name) before
import:

```bash
cp flux.conf NAS.conf
sudo nmcli connection import type wireguard file NAS.conf
```

Interface name: ≤ 15 chars; letters, digits, `_`, `-` all fine.

- **Autostart on boot:** `sudo nmcli connection modify NAS connection.autoconnect yes`
- **Caveat:** NM ignores `PreUp`/`PostUp`/`PreDown`/`PostDown` hooks in `.conf`.
  Use `wg-quick@wg0.service` if you need those.

Verify:

```bash
nmcli connection show NAS
ip link show NAS
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
