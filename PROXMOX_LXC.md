# Proxmox LXC Backend

The `proxmox-lxc` backend runs NixOS inside **Proxmox LXC containers** instead of
KVM virtual machines. It builds a NixOS **rootfs tarball** locally, transfers it
to a remote Proxmox VE node over SSH, and creates the container with `pct`. All
operations use `pct`, `pvesh`, and `zfs` over SSH — no API tokens needed. See
[INSTALL.md](INSTALL.md) for Nix and `just` setup first.

Select this backend with `BACKEND=proxmox-lxc` (in your environment or `.env`).

## Why a container backend?

A KVM VM cannot bind-mount a host directory — it can only share one over a
virtual disk or a network protocol. A **Proxmox LXC can**: `pct set -mpN
<hostpath>,mp=<ctpath>` mounts a host path (e.g. a ZFS dataset) straight into the
container. That makes LXC the natural home for a **NAS** that serves a
host-native ZFS dataset, which is exactly what the built-in `nas` profile does.

The tradeoff: a container shares the host kernel, so this backend is
**mutable-only** — there is no bootloader and the root filesystem is read-write.
The immutable / semi-mutable modes of the KVM backends do not apply here. See
[MODES.md](MODES.md) for the mode model.

## Additional Requirements

**Build machine:** `rsync`, `ssh`

**Proxmox node:** SSH access as root; `pct` (standard on PVE); a **CT-capable
storage** for the rootfs (a `zfspool` or `dir` storage — check with
`ssh <host> pvesm status`); ZFS on the host if you want dataset bind mounts.

## SSH Configuration

Identical to the [Proxmox (KVM) backend](PROXMOX.md#ssh-configuration). Configure
the connection in `~/.ssh/config` and use ssh-agent:

```
Host pve
    HostName 192.168.1.100
    User root
    Port 22
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PVE_HOST` | Yes | - | SSH config host name (or hostname/IP). SSH always logs in as `root` — any `user@` prefix is stripped. |
| `PVE_NODE` | Yes | `$PVE_HOST` | PVE node name (must match the Proxmox hostname) |
| `PVE_STORAGE` | No | `local` | **CT-capable** rootfs storage (zfspool/dir, e.g. `local-zfs` or `rust`) — **not** a bare ZFS pool path |
| `PVE_BRIDGE` | No | `vmbr0` | Default network bridge |
| `PVE_BACKUP_STORAGE` | No | `local` | Storage for `vzdump` backups |
| `PVE_TEMPLATE_DIR` | No | `/var/lib/vz/template/cache` | Where the rootfs tarball is staged on the node |
| `LXC_FEATURES` | No | `nesting=1` | `pct create --features` value |

Example `.env`:

```bash
BACKEND=proxmox-lxc
PVE_HOST=pve
PVE_NODE=pve
PVE_STORAGE=local-zfs
PVE_BRIDGE=vmbr0
PVE_BACKUP_STORAGE=local
```

> [!IMPORTANT]
> `PVE_STORAGE` is a Proxmox **storage name**, not a ZFS pool path. A bare pool
> like `rust` works only if a storage of that name exists (`pvesm status`). This
> is the most common first-run mistake.

## Quick Start (Proxmox LXC)

Put the backend and your PVE settings in a `.env` once (see
[Environment Variables](#environment-variables) above); the `just` commands then
need no `BACKEND=` prefix.

```bash
git clone https://github.com/EnigmaCurry/nixos-vm-template ~/nixos-vm-template
cd ~/nixos-vm-template

# Create .env once (or use the setup-context skill)
cat > .env <<'EOF'
BACKEND=proxmox-lxc
PVE_HOST=pve
PVE_STORAGE=local-zfs
PVE_BRIDGE=vmbr0
EOF

# Test SSH connection to Proxmox
just test-connection

# Build the LXC rootfs template for a profile
just build nas

# Create a container interactively (prompts for profile, resources, privileged, mounts)
just create mynas

# SSH into the container
just ssh mynas
```

## How It Works

1. **Build**: Nix builds a NixOS LXC **rootfs tarball** (`flake.lib.mkLxcImage`,
   `vm.container = true`) — no bootloader, no virtio disks.
2. **Transfer**: `rsync` sends the tarball to `PVE_TEMPLATE_DIR` on the node.
3. **Create**: `pct create … --ostype unmanaged --features nesting=1 --rootfs
   <storage>:<size> --net0 …,hwaddr=<pinned MAC>` creates the container.
4. **Bind mounts**: each configured host dataset/path is attached with
   `pct set -mpN <hostpath>,mp=<ctpath>` (the dataset is created if missing).
5. **Inject identity**: the stopped rootfs is opened with `pct mount`; the
   hostname, machine-id, SSH keys, firewall ports, and an `/etc/nixos` flake (for
   in-container `nixos-rebuild`) are rsynced into `/etc`, then `pct unmount`.
6. **Start**: `pct start`. The IP is read with `lxc-info -iH` (no guest agent).

## Mutable-only

There is no immutable or semi-mutable mode for LXC. The container's root is
read-write and you change the system from **inside** it:

```bash
just ssh admin@mynas
sudo nixos-rebuild switch   # /etc/nixos is seeded at create time
```

`just upgrade` is intentionally disabled for this backend (it prints the
"upgrade from inside" message). To reset a container to a fresh image, use
`just recreate` (rebuilds the rootfs, re-injects identity).

### SSH Host Key on Recreate

`just recreate <name>` wipes the rootfs, which includes `/etc/ssh/`. By default
openssh generates a **new** host key on first start, so SSH clients will see a
key-changed warning after every recreate. To pin a stable host key across
recreates, generate one on the workstation and let create/recreate install it:

```bash
cd machines/proxmox-lxc/<host>/<name>
ssh-keygen -t ed25519 -N '' -f ssh_host_ed25519_key   # overwrites the template
BACKEND=proxmox-lxc just recreate <name>
```

The machine dir ships with a `#`-comment-only template for `ssh_host_ed25519_key`
(mode 0600) and `ssh_host_ed25519_key.pub`. Comment/blank lines are stripped
when installing, so a comment-only template acts as absent — the container
generates its own key and the workstation holds no copy.

Only `create`/`recreate` apply the workstation-provided key. `sync-identity` /
`clone` never rotate a running container's host key; if the machine dir contains
a real key at that moment, they print a WARNING pointing to `just recreate`.

## Host ZFS Bind Mounts

The container's distinguishing feature. Mounts are stored one per line in
`machines/proxmox-lxc/<host>/<name>/mounts` as `<host-spec>:<container-path>`:

```
# A bare dataset name is created on the host if missing, then bind-mounted:
rust/nas:/srv/nas
# An absolute host path is bind-mounted as-is:
/mnt/media:/srv/media
```

The `just create` wizard prompts for these interactively. Each line becomes a
`pct` mountpoint (`mp0`, `mp1`, …). Datasets are **created if missing** but never
destroyed on teardown — your data outlives the container.

## The `nas` Profile

`nas` is an LXC-only profile (it asserts `vm.container`, so building it on a KVM
backend fails). It serves `/srv/nas` over **NFS** (kernel `nfsd`) and **Samba**:

```bash
just build nas
just create mynas   # wizard offers a default rust/nas:/srv/nas mount
```

Each bind-mounted dataset under `/srv/<name>` becomes one share named `<name>`,
served over **NFS, Samba, and copyparty** (web UI + WebDAV) — a boot service
(`nas-shares`) discovers the mountpoints and generates the config for all three.
Add another dataset → you automatically get another share on every protocol.

**Required setup:** every share is deny-all until you grant network access in
`machines/<name>/nas_hosts` (see below). A fresh `nas` container serves nothing
over Samba/NFS/copyparty until at least one rule is added there.

**Discovery (browse without an IP):** the profile advertises the server via
**WS-Discovery** (`wsdd` — shows up in Windows "Network" and modern Linux file
managers) and **mDNS** (`avahi` — `<hostname>.local` resolution and macOS Finder /
Avahi browsers). Legacy NetBIOS (`nmbd`) is disabled — modern SMB2/3 clients
ignore it. Both WSD and mDNS are link-local multicast, so the client must be on
the **same LAN segment**. Test by name (no IP):

```bash
ping nas.local                     # mDNS resolution
smbclient -L nas.local -N          # list shares by name
# …or just browse the network in your file manager.
```

Because kernel `nfsd` does not work in an unprivileged container, the `nas`
profile automatically runs the container **privileged** and appends
`lxc.apparmor.profile: unconfined` to its `pct` config.

### Automatic `.zfs` masking

Each share's ZFS snapshot control directory (`.zfs`) is masked inside the
container. `nas-shares` bind-mounts an empty read-only directory
(`/run/nas-shares/empty`) over every `/srv/<share>/.zfs`, so Samba, NFS,
copyparty, and syncthing all see an empty directory — direct URL / WebDAV /
`smbclient` lookups of `<share>/.zfs/snapshot/<name>/` resolve to nothing.
Root on the **PVE host** is unaffected (different mount namespace); browse
snapshots at `/<dataset>/.zfs/snapshot/` there for maintenance.

Idempotent across `nas-shares` re-runs. Triggered by container restart —
`just sync-identity <name>` or `just upgrade <name>` picks up any new share
that needs masking.

### Required: `nas_hosts` (network-layer scoping)

**Every share is deny-all until you write a rule in `nas_hosts`.** This is
the network-layer gate that sits underneath the per-user gate (`nas_acl`)
and governs **all three protocols** — Samba, NFS, and copyparty. Without it,
no share is reachable no matter what `nas_passwd`/`nas_acl` say.

The file lives at `machines/<name>/nas_hosts` and is seeded on `just create
<name> nas` with commented quick-start examples. One line per host, listing
every share that host is allowed to reach:

```
# <host-token>   <share>...
#
#   <cidr>      literal CIDR (e.g. 192.168.1.0/24 or 10.0.0.5/32)
#   0.0.0.0/0   any IPv4 host (fully open network layer)
#   wg:<peer>   that wg peer's tunnel IP(s) — requires the wireguard profile
#   wg:*        every wg peer currently in wireguard.conf
#
# Share token `*` = every /srv/* mount (expanded at emit time).

192.168.0.0/16    *              # every share reachable from the LAN
wg:mike           media backups  # mike (over wg) sees two shares
wg:*              nas            # every wg peer reaches the 'nas' share
```

To get the pre-`nas_hosts` "open on the LAN" behaviour, uncomment the
`0.0.0.0/0  *` or `<lan-cidr>  *` line the wizard seeds. To lock things
down per peer, list peers with the specific shares they need. Validation
is pre-flight and strict: any error stops Samba/NFS/copyparty rather than
letting them start with a partial or stale config. See
[NAS_HOSTS.md](NAS_HOSTS.md) for the full grammar, policy table, and
error/warning reference.

Apply edits with `just sync-identity <name>`.

### Per-user access (`nas_passwd` + `nas_acl`) — Samba **and** copyparty

Per-user access for **both Samba and copyparty** (the web/WebDAV server) is driven
by two files in the machine config (`machines/proxmox-lxc/<host>/<name>/`), synced
into the container on create/recreate (and `just sync-identity <name>`). The `just
create` wizard seeds commented templates.

**`nas_passwd`** (mode 0600) — the users, one `<user> <password>` per line:

```
# user   password
alice    s3cret
bob      hunter2
```

**`nas_acl`** (no secrets) — grants, one `<user> <share> <access>` per line:

```
# user   share   access      (access = r | rw)
alice    *       rw          # alice: read-write on EVERY share
bob      nas     r           # bob: read-only on share 'nas'
*        media   r           # guest (anonymous): read-only on 'media'
```

- `user` = a name (must be in `nas_passwd`), or `*` = guest/anonymous.
  `share` = a share name or `*` (all). `access` = `r` (read-only) | `rw`.
- **Mapping:** `r` → Samba read-only / copyparty `r`; `rw` → Samba write list /
  copyparty `rwmd` (read+write+move+delete).
- **Deny by default (unconditional):** a user/guest gets only what an explicit
  rule grants — no rule means **no access**, over both Samba and copyparty. (There
  is no "open when unconfigured" fallback.)
- One password per user (the passwd DB), shared by Samba and copyparty; `nas_acl`
  only decides which shares and read-vs-write.
- Apply edits without recreating: `just sync-identity <name>` (re-injects + reloads).

> [!WARNING]
> `nas_passwd` holds **plaintext** passwords (0600) on the workstation and inside
> the container. Everything runs as the unprivileged `nas` user; files are
> `nas`-owned (access is gated, not per-file ownership). The ACL governs Samba +
> copyparty per-user; **NFS has no per-user auth** — see [NFS access](#nfs-access)
> below. Homelab-grade.

### Web UI + WebDAV (copyparty)

The `nas` profile also runs **copyparty** on **port 3923**, serving the same
`/srv/<name>` shares over a web UI and **WebDAV**, with the same users and
permissions from `nas_passwd`/`nas_acl` (deny-by-default; `r` = read, `rw` =
read/write/move/delete).

```
http://<ip>:3923/             # web UI (log in as a nas_passwd user)
http://<ip>:3923/<share>      # a share; also the WebDAV URL
```

It runs as the `nas` user, so uploads are `nas`-owned like everything else. Port
3923 is seeded into `tcp_ports` (firewall) alongside the SMB/NFS ports.

### NFS access

NFS has **no per-user authentication** (`sec=sys` — the client just asserts its
uid), so its access control is entirely host-based and comes from the same
`nas_hosts` file described above. Every host granted a share via `nas_hosts`
gets an NFS export line generated for that share; no rules → no exports.

- **Flat shared access:** exports use `all_squash`, mapping *every* client UID
  (and root) to a single unprivileged **`nas`** owner (uid/gid 1500). Samba does
  the same via `force user = nas`, and the share dirs are `nas:nas` `2775`. So any
  user on an allowed host — and any Samba user — can read/write **every** file
  regardless of their own UID, and ownership never causes permission surprises.
- Clients mount by full path: `mount <ip>:/srv/<share> /mnt`.
- Because `nas_hosts` is the single gate for both SMB and NFS, granting a share
  to a host there opens it on both protocols at once. There is no built-in way
  to grant SMB but not NFS (or vice versa) — that split would need the
  container firewall (`tcp_ports`/`udp_ports`) to block the other protocol's
  port for everyone, or a separate share.

> [!NOTE]
> If a share already holds files owned by someone other than `nas` (e.g. earlier
> root-owned writes), run a one-time `chown -R nas:nas /srv/<name>` inside the
> container — `nas-shares` only fixes the share root, not pre-existing contents.

## Privileged vs Unprivileged

Containers default to **unprivileged** (better isolation). A per-machine
`privileged` flag (set by the wizard, or `machines/.../<name>/privileged` =
`1`/`0`) forces a privileged container. The `nas` profile forces privileged
automatically. Kernel services like `nfsd` require privileged + apparmor
unconfined.

## Networking

The container uses `--ostype unmanaged` and NixOS-managed networking
(systemd-networkd DHCP on `eth0`). The container's MAC is **pinned** per machine
(`machines/.../mac-address`), so create a **DHCP reservation** for it on your
router if you want a stable address. Bridge selection works like the
[Proxmox KVM backend](PROXMOX.md#proxmox-networking).

> [!NOTE]
> Static IP assignment inside the container is a planned follow-up; for now use a
> DHCP reservation against the pinned MAC.

## Firewall

There are two firewall layers, and they're kept in sync:

- **Inside the container** (NixOS) — opened by the profiles (`openFirewall` / NFS ports).
- **The Proxmox CT firewall** — the backend creates the container with `firewall=1`
  on `eth0` and programs `policy_in DROP` + the machine's `tcp_ports`/`udp_ports`.
  These only actually *enforce* if the **datacenter firewall** is enabled
  (`pvesh get /cluster/firewall/options`); with it off, the rules are inert.

**`tcp_ports`/`udp_ports` are the single source of truth** for both layers — they
open the container firewall (via the `firewall-ports` service, from the injected
`/etc/firewall-ports`) *and* the Proxmox CT firewall (via `sync-firewall`). The
**`nas` profile seeds its ports into these files at create time** — SMB `445`,
NFSv4 `2049`, copyparty web+WebDAV `3923`, WS-Discovery `5357` (tcp); mDNS `5353`,
WS-Discovery `3702` (udp).
They're written **once**, visible and **editable**, so you can remove any you
don't want exposed. Edit them, then `just sync-identity <name>` to apply.
(NFS is **v4-only** — just `2049/tcp`, no rpcbind/statd/lockd/mountd.)

> [!NOTE]
> mDNS (5353) and WS-Discovery (3702) are **multicast** — a `dport ACCEPT` usually
> passes them, but multicast through the PVE firewall can be finicky. If `.local`
> discovery stops working once the datacenter firewall is on, that's the place to look.

## VMID Management

Identical to the [Proxmox KVM backend](PROXMOX.md#vmid-management): each
container's VMID is stored in `machines/.../vmid`, prompted on create with the
next available ID as default.

## Backups (Proxmox LXC)

Backups use `vzdump` and restore with `pct restore`:

```bash
just backup mynas        # vzdump snapshot
just backups             # list backups (managed containers)
just restore-backup mynas
```

## Limitations / Notes

- **Kernel-bound profiles don't apply** in a container (shared host kernel):
  `nvidia`, `pipewire`, `zram`. They are excluded from the LXC wizard.
- **`pct exec` uses a minimal PATH** — NixOS binaries live under
  `/run/current-system/sw/bin/…`. Use full paths, or `pct enter <vmid>` for an
  interactive shell.
- Bind-mounted host datasets appear as real `zfs` mounts inside the container.
