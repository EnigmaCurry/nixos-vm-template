# nixos-vm-template

Build and manage immutable NixOS virtual machines on libvirt/KVM or Proxmox VE.

> [!NOTE]
> This code is written using Claude Code and other AI tools. It is reviewed
> and tested by a human being.

## Why Immutable VMs?

Virtual machines accumulate state over time. Install packages, update
configs, add data - and eventually you have a unique snowflake that's
difficult to reproduce or reason about. Snapshots and backups help,
but they capture *everything* - OS, configs, and data all mixed
together.

A better approach: separate the OS from your data.

**Two disks instead of one:**
- **Boot disk** - The operating system (read-only)
- **Data disk** - Your files and application state (`/var`, `/home`)

**Benefits:**
- Snapshots and backups target only what matters - your data
- The OS is immutable - no configuration drift, no surprise changes
- Upgrades are atomic - rebuild the image, swap the boot disk, reboot
- Multiple VMs can share the same base image (thin provisioning)
- Corruption-resistant - the root filesystem can't be modified at runtime

**The tradeoff:** You can't `apt install` or `dnf install` on a running
VM. System changes require rebuilding the image. This is a feature,
not a bug - it forces infrastructure-as-code practices and ensures
every VM is reproducible from source.

This project builds NixOS images with this architecture. NixOS is
ideal for this because the entire system configuration is declared in
code and built offline. The result is a VM that boots fast, runs
predictably, and can be recreated identically at any time.

## Mutable VMs

While immutable VMs are the default, sometimes you need a traditional
read-write NixOS system. Mutable VMs provide:

- **Single disk** instead of boot + var disks
- **Full nix toolchain** - run `nix-env`, `nixos-rebuild`, etc.
- **Standard NixOS experience** - install packages, modify configs at runtime
- **Same profiles** - all composable profiles work with mutable VMs
- **Works with both backends** - libvirt and Proxmox

**When to use mutable VMs:**
- You need to run `nixos-rebuild switch` inside the VM
- You want to experiment with NixOS configuration interactively
- You need full `nix` command access
- You're doing NixOS development or testing

**Tradeoffs:**
- No thin provisioning (each VM gets a full disk copy)
- Cannot use `just upgrade` from the host (must upgrade inside VM)
- Loses the corruption-resistance of a read-only root

### Creating a Mutable VM

Use `just mutable` to toggle mutable mode for an existing machine config:

```bash
just mutable myvm      # Interactive prompt to enable/disable
just recreate myvm     # Apply the change
```

Or create the `mutable` file manually before creating a new VM:

```bash
# Libvirt
mkdir -p machines/myvm
echo "true" > machines/myvm/mutable
just create myvm docker,dev

# Proxmox
mkdir -p machines/myvm
echo "true" > machines/myvm/mutable
BACKEND=proxmox just create myvm docker,dev
```

### Upgrading Mutable VMs

Mutable VMs cannot be upgraded from the host with `just upgrade`. Instead,
upgrade from inside the VM:

```bash
# SSH into the VM
just ssh admin@myvm

# Standard NixOS upgrade
sudo nixos-rebuild switch --upgrade

# Or with a flake
sudo nixos-rebuild switch --flake github:owner/repo#config
```

### Mutable VM Internals

| Feature | Immutable VM | Mutable VM |
|---------|--------------|------------|
| Disk layout | Boot disk + var disk | Single disk |
| Root filesystem | Read-only | Read-write |
| Identity files | `/var/identity/` | `/etc/` (hostname, machine-id, SSH keys) |
| Firewall rules | `/var/identity/tcp_ports` | `/etc/firewall-ports/tcp_ports` |
| Root password | `/var/identity/root_password_hash` | `/etc/root_password_hash` |
| Upgrade method | `just upgrade` from host | `nixos-rebuild` inside VM |
| Thin provisioning | Yes (QCOW2 backing files) | No (full disk copy) |

## Features

- Works on any Linux host distribution (e.g., Fedora, Debian, Arch Linux)
- **Two backends**: local libvirt/KVM or remote Proxmox VE
- It is a build script to create your own customized NixOS VM images
- Immutable, container-like root filesystem (read-only)
- Even `/etc` is read-only, you need to rebuild the image to reconfigure it
- Separate `/var` disk for all mutable state
- Bind mounted `/home` to `/var/home` and `/root` to `/var/root` (persistent)
- **Optional mutable mode**: standard read-write NixOS for full flexibility
- Snapshots and backups
- Composable VM profiles to customize the VM role (docker, podman, dev, claude, etc.)
- UEFI boot with systemd-boot
- SSH key-only authentication
- QEMU guest agent for IP detection and guest commands
- Optional zram compressed swap for memory overcommit

## Backends

This project supports two backends, selected via the `BACKEND` environment variable:

| Backend | Description | Default |
|---------|-------------|---------|
| `libvirt` | Local libvirt/KVM with QCOW2 backing files | Yes |
| `proxmox` | Remote Proxmox VE via SSH | No |

```bash
# Use libvirt (default)
just create myvm

# Use Proxmox
BACKEND=proxmox just create myvm
```

You can set `BACKEND` in a `.env` file in the project root to avoid
repeating it:

```bash
echo "BACKEND=proxmox" >> .env
```

## Requirements (Common)

- Linux build machine with KVM support
- `nix` package manager (with flakes enabled)
- `just` (command runner)
- `qemu-img` and `guestfish` (for disk creation)

## Installation

### Install Nix

Prefer your OS package:

```bash
## Normal Fedora workstation/server (not Atomic nor OSTree based)
sudo dnf install nix
sudo systemctl enable --now nix-daemon
```

Or use the nix installer, but it only works on non-SELinux
distributions:

```
## Generic Nix installer
curl -L https://nixos.org/nix/install | sh -s -- --daemon
```

> [!NOTE]
> The Nix installer works fine on most non-SELinux
> distributions out of the box. If you run Fedora Atomic, or another
> OSTree distro, see [DEVELOPMENT.md](DEVELOPMENT.md)

### Enable Nix Flakes support

Create the nix config file `~/.config/nix/nix.conf`:

```
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" \
    >> ~/.config/nix/nix.conf
```

### Install just

```bash
# With your package manager
sudo dnf install just      # Fedora
sudo apt install just      # Debian/Ubuntu
sudo pacman -S just        # Arch Linux

# Or with Nix (works on any distro)
nix profile install nixpkgs#just

# Or with cargo
cargo install just
```

## Libvirt Backend

### Additional Requirements

- libvirt and QEMU
- OVMF (UEFI firmware)

#### Fedora

```bash
sudo dnf install git libvirt qemu-kvm virt-manager guestfs-tools edk2-ovmf
sudo systemctl enable --now libvirtd
```

#### Debian / Ubuntu

```bash
sudo apt install git libvirt-daemon-system qemu-kvm virt-manager libguestfs-tools ovmf
sudo systemctl enable --now libvirtd
```

#### Arch Linux

```bash
sudo pacman -S git libvirt qemu-full virt-manager guestfs-tools edk2-ovmf dnsmasq
sudo systemctl enable --now libvirtd
```

### Host Firewall (UFW)

If your host has UFW enabled, it will block DHCP and NAT traffic on the
libvirt bridge. Allow traffic on `virbr0`:

```bash
sudo ufw allow in on virbr0
sudo ufw allow out on virbr0
sudo ufw route allow in on virbr0
sudo ufw route allow out on virbr0
```

### Quick Start (Libvirt)

```bash
git clone https://github.com/EnigmaCurry/nixos-vm-template ~/nixos-vm-template
cd ~/nixos-vm-template

# Create a VM interactively (prompts for name, profile, resources, etc.)
just create

# Check VM status and get IP address
just status myvm

# SSH into the VM
just ssh myvm              # As 'user' (no sudo)
just ssh admin@myvm        # As 'admin' (has sudo)
```

### Libvirt Storage

The libvirt backend uses QCOW2 backing files for thin provisioning.
Multiple VMs sharing the same profile share a single base image, with
each VM's boot disk storing only the delta (copy-on-write). This means
ten VMs built from the same profile consume roughly the space of one
full image plus their individual deltas.

The Proxmox backend does not use backing files — each VM receives a
full (flattened) copy of the boot disk. Storage-level deduplication
(e.g., ZFS) can offset this, but there is no per-profile thin
provisioning at the QCOW2 layer.

### Bridged Networking (Libvirt)

By default, VMs use NAT networking via libvirt's `virbr0` bridge. This
gives VMs internet access but they're not directly accessible from
other machines on your LAN.

For bridged networking, VMs connect directly to your physical network
and get IP addresses from your network's DHCP server. This requires
setting up a bridge interface on the host.

#### Setting Up a Bridge with NetworkManager

First, identify your physical network interface:

```bash
ip link show
# Look for your ethernet interface (e.g., enp6s0, eth0, eno1)
```

Create the bridge and attach your physical interface to it:

```bash
# Create the bridge
sudo nmcli connection add type bridge ifname br0 con-name br0

# Add your physical interface to the bridge (replace enp6s0 with your interface)
sudo nmcli connection add type bridge-slave ifname enp6s0 master br0 con-name br0-slave

# Find your current connection name for the physical interface
nmcli -t -f NAME,DEVICE connection show --active | grep enp6s0

# Bring down the old connection and bring up the bridge
# WARNING: This will briefly disconnect your network!
sudo nmcli connection down "Wired connection 1" && sudo nmcli connection up br0
```

#### Creating a Bridged VM

```bash
just create myvm core 2048 2 20G bridge
```

You'll be prompted to select from available bridge interfaces.

#### Changing Network Mode

```bash
just network-config myvm bridge
just upgrade myvm             # Apply the change
```

## Proxmox VE Backend

The Proxmox backend builds VM images locally, then transfers them to a
remote Proxmox VE node via SSH. All Proxmox operations use `qm` and
`pvesh` commands over SSH — no API tokens needed.

### Additional Requirements

**Build machine:** `rsync`, `ssh`, `jq`

**Proxmox node:** SSH access as root, `nbd` kernel module (for identity
sync), `qemu-nbd` (standard on PVE)

### SSH Configuration

The Proxmox backend connects via SSH. Configure your connection in
`~/.ssh/config` and use ssh-agent for key authentication:

```
Host pve
    HostName 192.168.1.100
    User root
    Port 22
```

Then set `PVE_HOST` to the SSH config host name:

```bash
# Start ssh-agent and add your key
eval $(ssh-agent)
ssh-add ~/.ssh/id_ed25519

# Test the connection
ssh pve
```

### Environment Variables

Set these in your `.env` file or as environment variables:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PVE_HOST` | Yes | - | SSH config host name (or hostname/IP for simple setups) |
| `PVE_NODE` | Yes | `$PVE_HOST` | PVE node name (must match Proxmox hostname) |
| `PVE_STORAGE` | No | `local` | Target storage for VM disks |
| `PVE_BRIDGE` | No | `vmbr0` | Default network bridge |
| `PVE_DISK_FORMAT` | No | `qcow2` | Disk format for import (qcow2 or raw) |
| `PVE_BACKUP_STORAGE` | No | `local` | Storage for vzdump backups |
| `PVE_VMID` | No | (auto) | Specify VMID for next create |

Example `.env`:

```bash
BACKEND=proxmox
PVE_HOST=pve
PVE_NODE=pve
PVE_STORAGE=local-zfs
PVE_BRIDGE=vmbr0
PVE_DISK_FORMAT=qcow2
PVE_BACKUP_STORAGE=pbs
```

### Quick Start (Proxmox)

```bash
git clone https://github.com/EnigmaCurry/nixos-vm-template ~/nixos-vm-template
cd ~/nixos-vm-template

# Test SSH connection to Proxmox
BACKEND=proxmox just test-connection

# Create a VM interactively (prompts for name, profile, resources, etc.)
BACKEND=proxmox just create

# Check status (requires QEMU guest agent to report IP)
BACKEND=proxmox just status myvm

# SSH into the VM
BACKEND=proxmox just ssh myvm
```

### How It Works

1. **Build**: Nix builds the NixOS image locally as a QCOW2 file
2. **Flatten**: The boot disk is flattened (backing file removed) for transfer
3. **Transfer**: `rsync` sends the boot and var disks to a staging directory on PVE
4. **Import**: `qm importdisk` imports the disks into the configured storage
5. **Configure**: The VM is created with OVMF UEFI, q35 machine type, serial console, and virtio disks

### VMID Management

Each VM's Proxmox VMID is stored in `machines/<name>/vmid`. By default,
VMIDs are auto-allocated from Proxmox via `pvesh get /cluster/nextid`.
To specify a VMID manually:

```bash
PVE_VMID=200 BACKEND=proxmox just create myvm
```

The script validates that the VMID is either available or already
belongs to a VM with the same name.

### Identity Sync

The `just upgrade` command syncs identity files to the VM's `/var` disk
without downloading it. It uses `qemu-nbd` on the PVE node to mount the
var disk in place, rsyncs only the small identity files, then unmounts.
This works regardless of var disk size.

### Disk Format

Set `PVE_DISK_FORMAT` based on your storage backend:

| Storage Type | Recommended Format | Why |
|--------------|-------------------|-----|
| Directory/NFS | `qcow2` | Thin provisioning, snapshot support |
| ZFS | `raw` | ZFS handles thin provisioning natively |
| LVM-thin | `raw` | Storage layer provides thin + snapshots |
| Ceph/RBD | `raw` | Ceph handles it natively |

### Proxmox Networking

The `network` parameter maps to Proxmox bridges:

| Network parameter | Proxmox net0 bridge |
|-------------------|---------------------|
| `nat` | `$PVE_BRIDGE` (default `vmbr0`) |
| `bridge:<name>` | `<name>` directly |

For Proxmox, use `bridge:<name>` to specify a bridge directly (the
interactive `bridge` menu only lists local bridges, not remote PVE bridges):

```bash
# Use default bridge (vmbr0)
BACKEND=proxmox just create myvm core 2048 2 30G nat

# Use a specific Proxmox bridge
BACKEND=proxmox just create myvm core 2048 2 30G bridge:vmbr1
```

### Backups (Proxmox)

Proxmox backups use `vzdump` and are stored on `PVE_BACKUP_STORAGE`:

```bash
BACKEND=proxmox just backup myvm       # Create vzdump backup
BACKEND=proxmox just backups           # List backups (managed VMs only)
BACKEND=proxmox just restore-backup myvm  # Restore from backup
```

## Commands

### Building

| Command | Description |
|---------|-------------|
| `just build [profiles]` | Build a profile image (default: core). Supports comma-separated profiles. |
| `just build-all` | Build common base profiles |
| `just list-profiles` | List available profiles |

```bash
just build              # Build the default "core" profile
just build docker       # Build the "docker" profile (core is always included)
just build docker,python,rust  # Build a combined image with multiple profiles
```

### VM Lifecycle

| Command | Description |
|---------|-------------|
| `just config [name]` | Configure a VM interactively (prompts for all settings) |
| `just create [name]` | Create a new VM interactively (runs config, builds image, starts VM) |
| `just clone <source> <dest> [memory] [vcpus] [network]` | Clone a VM (copy /var, fresh identity) |
| `just start <name>` | Start a VM |
| `just stop <name>` | Gracefully stop a VM (ACPI shutdown) |
| `just reboot <name>` | Reboot a VM (ACPI reboot) |
| `just force-stop <name>` | Force stop a VM |
| `just upgrade <name>` | Rebuild image, preserve /var data |
| `just resize <name>` | Interactively resize memory, vcpus, and /var disk |
| `just resize-var <name> <size>` | Resize just the /var disk |
| `just recreate <name> [var_size] [network]` | Fresh start, replace all disks (data lost) |
| `just network-config <name> [network]` | Change network mode (nat or bridge) |
| `just mutable <name>` | Toggle mutable mode (single read-write disk) |
| `just passwd <name>` | Set or clear root password for console access |
| `just destroy <name>` | Remove VM and disks (preserves machine config) |
| `just purge <name>` | Remove VM, disks, and machine config |

The `config` and `create` commands are interactive and prompt for all settings
(name, profile, memory, vcpus, disk size, network mode). No arguments are required:

```bash
just config                # Configure a new VM interactively
just create                # Create and start a new VM interactively
```

For scripted/non-interactive use, use the batch variants:

```bash
just config-batch webserver docker 4096 4 50G nat
just create-batch webserver docker 4096 4 50G nat
just create-batch devbox docker,podman,dev 8192 8  # Full dev environment with Docker and Podman
just create-batch claude-vm claude,dev,docker,podman 8192 4  # Claude Code with full dev stack

just network-config webserver nat         # Switch to NAT networking
just network-config webserver bridge      # Interactive bridge selection (local bridges)
just network-config webserver bridge:br0  # Specify bridge directly

just passwd webserver                     # Set root password (interactive, leave blank to disable)

just upgrade webserver                    # Rebuild and apply changes (preserves /var data)
```

### Upgrade vs Recreate

- **`just upgrade <name>`** - Updates the VM to a new image while preserving all data
  in `/var` (home directories, logs, application data). Use this for routine
  updates.

- **`just recreate <name>`** - Deletes everything and starts fresh. Both the boot disk
  and `/var` disk are replaced. All data is lost. Use this when you want a
  clean slate.

### Cloning

`just clone <source> <dest>` duplicates a VM by copying its `/var` disk
(preserving all data, home directories, and application state) while
generating fresh identity files (machine-id, MAC address, UUID, hostname,
SSH host key). The source VM must be shut off.

```bash
just clone webserver webserver2              # Clone with default resources
just clone webserver webserver2 4096 4       # Clone with 4GB RAM, 4 CPUs
just clone webserver webserver2 2048 2 nat   # Clone and override network mode
```

The cloned VM inherits the source's profile, SSH authorized keys, firewall
ports, DNS configuration, and root password hash. It gets its own unique
identity so both VMs can run simultaneously without conflicts.

### Resizing

VMs can be resized after creation to adjust memory, vCPUs, and /var disk
size. The VM must be stopped before resizing.

```bash
just resize myvm                    # Interactive: prompts for new memory, vcpus, disk size
just resize-var myvm 100G           # Direct: resize just the /var disk to 100G
just resize-var myvm 100            # Same as above (G suffix is default)
```

**Notes:**
- Memory is specified in MB (e.g., `4096` = 4GB RAM)
- Disk sizes without a suffix default to gigabytes (e.g., `50` means `50G`)
- Only increasing disk size is supported (shrinking is not allowed)
- The partition and filesystem are automatically grown on next boot
- No data is lost during resize

### VM Information

| Command | Description |
|---------|-------------|
| `just list` | List managed VMs |
| `just status <name>` | Show VM status and IP address |
| `just list-machines` | List all machine configs |

### Snapshots

| Command | Description |
|---------|-------------|
| `just snapshot <name> <snapshot>` | Create a snapshot |
| `just restore-snapshot <name> <snapshot>` | Restore to a snapshot |
| `just snapshots <name>` | List snapshots for a VM |

```bash
just snapshot webserver before-upgrade    # Create snapshot named "before-upgrade"
just restore-snapshot webserver before-upgrade   # Restore to that snapshot
```

Note that `upgrade` and `recreate` will delete all snapshots.

### Backups

| Command                      | Description                             |
|------------------------------|-----------------------------------------|
| `just backup <name>`         | Create backup of VM                     |
| `just backups`               | List available backups                  |
| `just restore-backup <name>` | Restore backup of VM (choose from list) |

### Maintenance

| Command               | Description                      |
|-----------------------|----------------------------------|
| `just test-connection` | Test connection to backend (libvirt or proxmox) |
| `just console <name>` | Attach to VM serial console      |
| `just ssh <name>`     | SSH into VM (as user)            |
| `just ssh admin@<name>` | SSH into VM (as admin, has sudo) |
| `just clean`          | Remove built images and VM disks |
| `just shell`          | Enter Nix development shell      |

## Profiles

Profiles are composable mixins that you combine as needed. The `core` profile
is always included automatically. Specify multiple profiles with commas:

```bash
just create myvm docker,python           # Docker + Python
just create devbox docker,podman,dev     # Full dev environment
just create claude-vm claude,dev,docker  # Claude Code with dev tools
```

### Available Profiles

| Profile | Description |
|---------|-------------|
| **core** | SSH server, admin/user accounts, firewall (always included) |
| **docker** | Docker daemon (both users have docker access) |
| **podman** | Podman + distrobox, buildah, skopeo (rootless containers) |
| **nvidia** | NVIDIA drivers + container toolkit (requires docker) |
| **python** | Python with uv package manager and build tools |
| **rust** | Rust with rustup |
| **dev** | Development tools (neovim, tmux, etc.) |
| **home-manager** | Home-manager with sway-home modules (emacs, shell config, etc.) |
| **claude** | Claude Code CLI (Anthropic's AI coding assistant) |
| **open-code** | Open Code CLI (open-source AI coding assistant) |

### Common Combinations

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

With typical 3:1 compression ratios, a 4GB VM can handle additional memory
pressure before OOM:

| `memoryPercent` | Zram Size | Effective Capacity |
|-----------------|-----------|-------------------|
| 50 | 2GB | ~5.5GB (4GB + ~1.5GB compressed) |
| 75 | 3GB | ~6.25GB (4GB + ~2.25GB compressed) |
| 100 | 4GB | ~7GB (4GB + ~3GB compressed) |

Higher values provide more headroom but consume more RAM for the zram device
itself. The default of 50% in dev profiles balances memory efficiency with
safety margin.

## Machine Configuration

Each VM has a machine config directory at `machines/<name>/` containing:

- `profile` - Which profile to use
- `mutable` - If contains "true", creates a mutable VM (single read-write disk)
- `hostname` - VM hostname
- `machine-id` - Unique machine identifier
- `uuid` - VM UUID (preserves DHCP lease across upgrades)
- `mac-address` - Network MAC address
- `network` - Network mode (`nat` or `bridge:<name>`)
- `ssh_host_ed25519_key` - SSH host key
- `admin_authorized_keys` - SSH public keys for admin user
- `user_authorized_keys` - SSH public keys for regular user
- `tcp_ports` - TCP ports to open in firewall (one per line)
- `udp_ports` - UDP ports to open in firewall (one per line)
- `root_password_hash` - Root password hash for console login (empty = disabled)
- `resolv.conf` - DNS configuration (default: Cloudflare 1.1.1.1, 1.0.0.1)
- `hosts` - Extra /etc/hosts entries (optional)
- `vmid` - Proxmox VMID (proxmox backend only)

These files are generated during `just create` and preserved across
`just upgrade` and `just recreate`.

### Custom Firewall Ports

To open additional ports for a specific VM, edit `tcp_ports` and/or
`udp_ports` in the machine config directory:

```bash
# Open TCP ports 8080 and 3000
echo "8080" >> machines/myvm/tcp_ports
echo "3000" >> machines/myvm/tcp_ports

# Open UDP port 53
echo "53" >> machines/myvm/udp_ports

# Apply changes
just upgrade myvm
```

Lines starting with `#` are treated as comments.

**How firewall rules are applied:**

| VM Type | Rule Location | Applied By | Update Method |
|---------|---------------|------------|---------------|
| Immutable | `/var/identity/tcp_ports`, `/var/identity/udp_ports` | `firewall-identity.service` at boot | `just upgrade` syncs from machine config |
| Mutable | `/etc/firewall-ports/tcp_ports`, `/etc/firewall-ports/udp_ports` | `firewall-ports.service` at boot | `just recreate` (or edit files in VM) |

Both services use iptables to insert rules into the `nixos-fw` chain at boot.
For mutable VMs, you can also edit the files directly inside the VM and reboot,
or manually run `systemctl restart firewall-ports` to apply changes.

### Root Password

By default, all accounts are locked for password authentication (SSH
keys are the only way to log in). To enable root console access for
debugging, you can set a root password:

```bash
just passwd myvm              # Set root password (interactive)
just upgrade myvm             # Apply the change
```

The password hash is stored in `machines/<name>/root_password_hash`.
When this file is empty, root password login is disabled.

## Architecture

```
VM Disk Layout:
  vda (boot) - Read-only root filesystem
  vdb (var)  - Read-write /var filesystem

Filesystem Mounts:
  /      - Read-only (from vda)
  /boot  - Read-only (EFI partition on vda)
  /var   - Read-write (from vdb)
  /home  - Bind mount of /var/home
  /root  - Bind mount of /var/root
  /tmp   - tmpfs
```

### Libvirt Specifics

- Boot disk uses QCOW2 with backing file (thin provisioning)
- Multiple VMs share a single base image
- OVMF UEFI firmware with QCOW2 NVRAM (supports snapshots)

### Proxmox Specifics

- Boot disk flattened and imported via `qm importdisk`
- Serial console (no VGA framebuffer)
- QEMU guest agent enabled for IP detection
- Identity sync via `qemu-nbd` mount on PVE node

## Troubleshooting

### libguestfs / supermin failure on Ubuntu

If `just create` fails with a `supermin` error like:

```
libguestfs: error: /usr/bin/supermin exited with error status 1.
```

This is because Ubuntu ships kernel images in `/boot/` without
world-read permissions. `guestfish` uses `supermin` to build a
lightweight appliance VM (booted with the host kernel) for safe disk
manipulation without root access. Without read access to the kernel,
it can't build the appliance.

Fix it:

```bash
sudo chmod 644 /boot/vmlinuz-*
```

To persist across kernel updates:

```bash
echo 'DPkg::Post-Invoke {"chmod 644 /boot/vmlinuz-*"};' \
  | sudo tee /etc/apt/apt.conf.d/99-vmlinuz-permissions
```

Fedora and Arch don't have this issue (kernels are world-readable by
default).

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md)

## Claude Code Integration

This project includes [Claude Code](https://claude.ai/claude-code) skills
for interactive VM management. If you have Claude Code installed, you can
use these slash commands:

| Command | Description |
|---------|-------------|
| `/setup-context` | Configure the backend (.env file) for libvirt or Proxmox |
| `/create-vm` | Create a new VM with guided prompts |
| `/clone-vm` | Clone an existing VM with fresh identity |
| `/destroy-vm` | Destroy a VM (optionally purge config too) |
| `/upgrade-vm` | Upgrade VM to new image, preserving /var data |
| `/snapshot-vm` | Create, list, or restore snapshots |
| `/backup-vm` | Create, list, or restore backups |

These skills provide guided workflows with prompts and confirmations,
making complex operations safer and easier.

For simple operations, use `just` commands directly:

```bash
just create              # Create a new VM (interactive)
just start myvm          # Start a VM
just stop myvm           # Stop a VM (ACPI shutdown)
just reboot myvm         # Reboot a VM (ACPI reboot)
just status myvm         # Show VM status and IP
just ssh myvm            # SSH as 'user'
just ssh admin@myvm      # SSH as 'admin' (has sudo)
just console myvm        # Attach to serial console
just list                # List all VMs
```
