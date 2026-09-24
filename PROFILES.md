# Profiles

Profiles are composable mixins that you combine as needed. The `core` profile
is always included automatically. Specify multiple profiles with commas:

```bash
just create myvm docker,python           # Docker + Python
just create devbox docker,podman,dev     # Full dev environment
just create claude-vm claude,dev,docker  # Claude Code with dev tools
```

## Available Profiles

| Profile | Description |
|---------|-------------|
| **core** | SSH server, admin/user accounts, firewall (always included) |
| **docker** | Docker daemon (both users have docker access) |
| **podman** | Podman + distrobox, buildah, skopeo (rootless containers) |
| **nvidia** | NVIDIA drivers + container toolkit (requires docker) |
| **python** | Python with uv package manager and build tools |
| **rust** | Rust toolchain from Nix packages |
| **dev** | Development tools (neovim, tmux, etc.) |
| **home-manager** | Home-manager with sway-home modules (emacs, shell config, etc.) |
| **claude** | Claude Code CLI (Anthropic's AI coding assistant) |
| **open-code** | Open Code CLI (open-source AI coding assistant) |
| **traefik** | Traefik reverse proxy. Static config in `machines/<name>/traefik/traefik.yml` and dynamic (file-provider) rules in `machines/<name>/traefik/dynamic/*.yml` — both staged verbatim onto the VM (`/var/identity/traefik/` immutable, `/etc/traefik/` mutable). Absent `traefik.yml` → the service silently no-ops at boot. `just create` seeds a commented static template and a `.disabled` dynamic example. `net.ipv4.ip_nonlocal_bind = 1` is set so an `entryPoints.<name>.address` bound to a wireguard IP works even before wg0 is up. Persistent state (e.g. `acme.json`) lives in `/var/lib/traefik/`. See [TRAEFIK.md](TRAEFIK.md). |
| **wireguard** | WireGuard VPN on `wg0`. Config in `machines/<name>/wireguard.conf` (mode 0600; private key pinned so recreate preserves the tunnel identity). Enables IPv4 forwarding and marks wg0 trusted (bypasses `tcp_ports`/`udp_ports` on the wg side). Peer ACL lives in `machines/<name>/wireguard.nft` — two nftables chains: `wg-input` (traffic to this peer's own services) and `wg-forward` (traffic transiting through when this peer is a hub). **Default is deny-everything**: if the file is missing or a chain body is absent, the service synthesizes a drop-only chain for that direction. Peer names come from `# hostname: X` comments in `wireguard.conf` and are exposed as `$name`. `just create` seeds both files with commented examples. Opens UDP 51820 by default. See [WIREGUARD.md](WIREGUARD.md). |
| **syncthing** | Peer-to-peer file sync. GUI on `127.0.0.1:8384` (expose via traefik + wg-auth). Sync port `22000/tcp+udp` and LAN discovery `21027/udp` are seeded commented into `tcp_ports`/`udp_ports` at create time. Device identity is pinned: `just create` runs `syncthing generate` once and stores `syncthing_cert.pem` / `syncthing_key.pem` (0600) in `machines/<name>/` so the device ID survives recreate. Peer table (`syncthing_devices` — `<peer-name> <device-id> [addr]...`) and folder table (`syncthing_folders`) are **authoritative** per-machine text files — a boot service (`syncthing-config`) reconciles syncthing's running config to match, adding what's missing and deleting what isn't listed (GUI edits are wiped on the next `sync-identity`). Composes with **nas**: when both are enabled, syncthing runs as the shared `nas` user (uid 1500) so folder paths under `/srv/*` produce files that Samba/NFS/copyparty can read/write without permission drift. Composes with **wireguard**: when `wg0` is up at reconcile time, syncthing is confined to the tunnel — `listenAddresses` binds to the wg IP only, and global announce / local announce / relays / NAT-PMP are turned off (peers must know your wg IP; pin theirs in `syncthing_devices`). |
| **nas** | **`proxmox-lxc` backend only.** Serves every host ZFS dataset bind-mounted under `/srv/*` over NFSv4 (kernel `nfsd`), Samba (SMB), and copyparty (web UI + WebDAV on port 3923) — same files, same shared `nas` owner (uid/gid 1500). Users, per-share access, and host allowlists are per-machine files: `nas_passwd` (0600, plaintext `<user> <password>`), `nas_acl` (`<user> <share> r\|rw`; `*` = guest or all shares), and `nas_hosts` (`<host-token> <share>...`; tokens are `wg:<peer>`, `wg:*`, or literal CIDR). **Deny by default** on both axes — no `nas_acl` rule = no user access, no `nas_hosts` rule = no network reachability. A boot service (`nas-shares`) validates all three files and regenerates NFS exports, Samba shares, and copyparty config from the live `/srv/*` bind mounts; failed validation stops smbd/nfsd/copyparty rather than serving stale config. Forces a privileged container with apparmor-unconfined (kernel `nfsd`). Discovery via WS-Discovery (wsdd) + mDNS (avahi). See [PROXMOX_LXC.md](PROXMOX_LXC.md). |
| **cloud-init** | Turns the built image into a clonable Proxmox template. Built via `just cloud-template <name>`, not `just create` (the wizard filters it out). Requires `mutable`; other modes are rejected at build. See [PROXMOX_INSTALL.md](PROXMOX_INSTALL.md) for the end-to-end flow. |
| **moonshine-nvidia** | [Moonshine](https://github.com/hgaiser/moonshine) headless game-streaming server. Requires `pipewire` + a Proxmox VM with NVIDIA GPU passthrough (see [PROXMOX.md](PROXMOX.md#gpu-passthrough)). Mutually exclusive with `sunshine-plasma-nvidia`. |
| **sunshine-plasma-nvidia** | [Sunshine](https://github.com/LizardByte/Sunshine) desktop-streaming server bundled with KDE Plasma 6 Wayland (SDDM autologin), Flatpak, and the [Bazaar](https://github.com/kolunmi/bazaar) app store. For streaming a full KDE desktop rather than individual games. Requires `pipewire` + a Proxmox VM with NVIDIA GPU passthrough. Mutually exclusive with `moonshine-nvidia`. First-boot Flatpak install runs in the background; Bazaar appears in the menu after a few minutes. |

> **Tip for agentic use:** Consider enabling
> [semi-mutable mode](MODES.md#semi-mutable-vms) for `claude` or `open-code` VMs
> (`echo "semi" > machines/<name>/mutable`). This gives a writable `/nix`
> overlay so that software can be installed on the fly with
> `nix profile install`, and nix-based projects can build and evaluate
> flakes — all while keeping the root filesystem immutable and
> host-upgradeable.

## Common Combinations

| Use Case | Profiles |
|----------|----------|
| Docker server | `docker` |
| Development VM | `docker,podman,dev` |
| Full dev environment | `docker,podman,dev,home-manager` |
| Python development | `docker,python` |
| Claude Code (full) | `claude,dev,docker,podman,home-manager` |
| Claude with GPU | `claude,dev,docker,nvidia` |
| Open Code (full) | `open-code,dev,docker,podman,home-manager` |

## Zram Compressed Swap

Zram creates a compressed swap device in RAM, allowing the system to handle
memory pressure by compressing inactive pages rather than killing processes
(OOM). This is useful for development workloads that may have unpredictable
memory spikes.

**Enabled by default in:** `dev`, `claude`, `open-code`

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `vm.zram.enable` | `false` | Enable zram compressed swap |
| `vm.zram.memoryPercent` | `100` | Percentage of RAM to use for zram (e.g., 50 = half of RAM) |
| `vm.zram.algorithm` | `zstd` | Compression algorithm (`zstd`, `lz4`, `lzo`) |

When enabled, swappiness is set to 100 to prefer compressing memory over
OOM killing.

### Enabling in a Custom Profile

To enable zram in your own profile, add to your profile's nix file:

```nix
{
  vm.zram.enable = true;
  vm.zram.memoryPercent = 50;  # Use half of RAM for compressed swap
}
```

### Effective Memory

Zram compresses inactive pages and stores them in RAM as swap. This
lets the system handle more memory pressure before OOM killing.
Compression ratios vary by workload (typically 2:1 to 4:1).

With a 4GB VM and an assumed 3:1 compression ratio:

| `memoryPercent` | Zram Swap Size | Effective Capacity |
|-----------------|----------------|-------------------|
| 50 | 2GB | ~5.3GB |
| 75 | 3GB | ~6GB |
| 100 | 4GB | ~6.7GB |

The zram device itself lives in RAM, so higher values trade active
memory for more compressed swap capacity.
