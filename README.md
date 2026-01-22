# nixos-vm-template

Build and manage immutable NixOS virtual machines on libvirt/KVM.

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

## Features

- Build script to create your own customized NixOS images
- Thinly provisioned storage - many VMs can share a common base image
- Immutable, container-like root filesystem (read-only)
- Even `/etc` is read-only, you need to rebuild the image to reconfigure it
- Separate `/var` disk for all mutable state
- Bind mounted `/home` to `/var/home` (persistent read/write user data)
- Snapshots (QCOW2)
- Backups (`/var` disk archive exported to `.tar.zst` file)
- Multiple VM profiles to customize the VM role (base, core, docker, dev)
- UEFI boot with systemd-boot
- SSH key-only authentication

## Requirements

- Linux host with KVM support
- libvirt and QEMU
- `nix` package manager (with flakes enabled)
- `just` (command runner)

## Installation

### Install Nix

```bash
curl -L https://nixos.org/nix/install | sh -s -- --daemon
```

> [!NOTE] 
> The Nix installer works fine on most Linux distributions out
> of the box. If you run Fedora Atomic, or another OSTree distro, see [DEVELOPMENT.md](DEVELOPMENT.md)

Enable flakes by adding to `~/.config/nix/nix.conf`:

```
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
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

### Install libvirt and dependencies

Choose the instructions for your distribution:

#### Fedora

```bash
sudo dnf install libvirt qemu-kvm virt-manager guestfs-tools edk2-ovmf
sudo systemctl enable --now libvirtd
```

#### Debian / Ubuntu

```bash
sudo apt install libvirt-daemon-system qemu-kvm virt-manager libguestfs-tools ovmf
sudo systemctl enable --now libvirtd
```

#### Arch Linux

```bash
sudo pacman -S libvirt qemu-full virt-manager guestfs-tools edk2-ovmf dnsmasq
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

### Create a dedicated user account (recommended)

When you create VMs, the build script generates sensitive files in the `machines/` directory, including SSH host keys. It's recommended to create a dedicated user account for managing your VMs, so these files are protected from other users reading them:

```bash
# Create a new user (e.g., "libvirt-admin")
sudo useradd -m -s /bin/bash libvirt-admin

# Add the user to the libvirt group
sudo usermod -aG libvirt libvirt-admin

# Switch to the new user
sudo -iu libvirt-admin

# Enable nix flakes
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

# Clone this repository into the new user's home directory
git clone https://github.com/EnigmaCurry/nixos-vm-template
cd nixos-vm-template
```

This keeps your VM configurations and secrets isolated from your main user account. All subsequent commands in this guide should be run as this dedicated user.

## Quick Start

```bash
# Clone the repository
git clone https://github.com/EnigmaCurry/nixos-vm-template
cd nixos-vm-template

# Create a VM named "test" with the default "core" profile
just create test

# Start the VM
just start test

# Check VM status and get IP address
just status test

# SSH into the VM
ssh admin@<ip>   # Has sudo access
ssh user@<ip>    # No sudo access
```

## Commands

### Building

| Command | Description |
|---------|-------------|
| `just build [profile]` | Build a profile image (default: core) |
| `just build-all` | Build all profiles (base, core, docker, dev) |
| `just list-profiles` | List available profiles |

```bash
just build              # Build the default "core" profile
just build docker       # Build the "docker" profile
```

### VM Lifecycle

| Command | Description |
|---------|-------------|
| `just create <name> [profile] [memory] [vcpus] [var_size] [network]` | Create a new VM |
| `just start <name>` | Start a VM |
| `just stop <name>` | Gracefully stop a VM |
| `just force-stop <name>` | Force stop a VM |
| `just upgrade <name>` | Rebuild image, preserve /var data |
| `just recreate <name> [var_size] [network]` | Fresh start, replace all disks (data lost) |
| `just network-config <name> [network]` | Change network mode (nat or bridge) |
| `just passwd <name>` | Set or clear root password for console access |
| `just destroy <name>` | Remove VM and disks (preserves machine config) |
| `just purge <name>` | Remove VM, disks, and machine config |

```bash
just create webserver docker 4096 4 50G   # Create "webserver" with docker profile, 4GB RAM, 4 CPUs, 50GB /var
just create devbox dev 8192 8             # Create "devbox" with dev profile, 8GB RAM, 8 CPUs

just network-config webserver nat         # Switch "webserver" to NAT networking
just network-config webserver bridge      # Switch "webserver" to bridged networking

just passwd webserver                     # Set root password (interactive, leave blank to disable)

just upgrade webserver                    # Rebuild and apply changes (preserves /var data)
```

The `network` parameter can be `nat` (default) or `bridge`. See [Bridged Networking](#bridged-networking) for details.

### Upgrade vs Recreate

- **`just upgrade <name>`** - Updates the VM to a new image while preserving all data
  in `/var` (home directories, logs, application data). Use this for routine
  updates.

- **`just recreate <name>`** - Deletes everything and starts fresh. Both the boot disk
  and `/var` disk are replaced. All data is lost. Use this when you want a
  clean slate.

### VM Information

| Command | Description |
|---------|-------------|
| `just list` | List all VMs |
| `just status <name>` | Show VM status and IP address |
| `just list-machines` | List all machine configs |

```bash
just list               # Show all VMs and their states
just status webserver   # Get IP address and status of "webserver"
```

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

Snapshots capture the `/var` disk and UEFI NVRAM state. The root filesystem
is immutable, so there's nothing to snapshot there. Note that `upgrade` and
`recreate` will delete all snapshots.

### Backups

| Command                      | Description                             |
|------------------------------|-----------------------------------------|
| `just backup <name>`         | Create backup of VM                     |
| `just restore-backup <name>` | Restore backup of VM (choose from list) |

```bash
just backup webserver           # Create timestamped backup in output/backups/
just restore-backup webserver   # Interactive restore from available backups
```

Backup files are `.tar.zst` archives that contain the unique VM data
for `/var` only. They are not full OS images. When restoring a backup
you must rebuild the OS with nix (`just build` and/or `just upgrade <vm>`).

```
# Showing contents of an example archive:

$ zstdcat output/backups/test-20260121-171147.tar.zst | tar -tv
drwxr-xr-x enigma/enigma     0 2026-01-21 17:04 ./
-rw-r--r-- qemu/qemu 8745189376 2026-01-21 17:11 ./var.qcow2
-rw-r--r-- qemu/qemu     196704 2026-01-21 17:04 ./boot.qcow2
-rw-r--r-- qemu/qemu     524358 2026-01-21 17:11 ./OVMF_VARS.qcow2
```

Notice the `boot.qcow2` is pretty tiny, that's because it's
incomplete, and that's fine. `boot.qcow2` is just an overlay device on
top of the shared base image from `just build`. The important part is
that the archive has a full back up `/var`. The VM archive can be
restored on any computer, and the full OS image can be rebuilt by
running `just build` and/or `just upgrade <vm>`. After this, the
`boot.qcow2` will be re-created from scratch, discarding the version
from the archive.

### Maintenance

| Command               | Description                      |
|-----------------------|----------------------------------|
| `just console <name>` | Attach to VM serial console      |
| `just clean`          | Remove built images and VM disks |
| `just shell`          | Enter Nix development shell      |

## Profiles

- **base** - Minimal NixOS system
- **core** - Base + SSH server with admin/user accounts
- **docker** - Core + Docker (admin user has docker access)
- **dev** - Core + development tools and Docker (both users have docker access)
- **claude** - Dev + Claude Code CLI (Anthropic's AI coding assistant)

## Machine Configuration

Each VM has a machine config directory at `machines/<name>/` containing:

- `profile` - Which profile to use
- `hostname` - VM hostname
- `machine-id` - Unique machine identifier
- `uuid` - Libvirt VM UUID (preserves DHCP lease across upgrades)
- `mac-address` - Network MAC address
- `network` - Network mode (`nat` or `bridge`)
- `ssh_host_ed25519_key` - SSH host key
- `admin_authorized_keys` - SSH public keys for admin user
- `user_authorized_keys` - SSH public keys for regular user
- `tcp_ports` - TCP ports to open in firewall (one per line)
- `udp_ports` - UDP ports to open in firewall (one per line)
- `root_password_hash` - Root password hash for console login (empty = disabled)
- `resolv.conf` - DNS configuration (default: Cloudflare 1.1.1.1, 1.0.0.1)

These files are generated during `just create` and preserved across
`just upgrade` and `just recreate`.

### Custom Firewall Ports

To open additional ports for a specific VM, create `tcp_ports` and/or
`udp_ports` files in the machine config directory before running
`just create` or `just recreate`:

```bash
# Open TCP ports 8080 and 3000
echo "8080" > machines/myvm/tcp_ports
echo "3000" >> machines/myvm/tcp_ports

# Open UDP port 53
echo "53" > machines/myvm/udp_ports
```

Lines starting with `#` are treated as comments.

### Root Password

By default, all accounts are locked for password authentication (SSH
keys are the only way to log in). To enable root console access for
debugging, you can set a root password:

```bash
just passwd myvm              # Set root password (interactive)
just upgrade myvm             # Apply the change
```

The password hash is stored in `machines/<name>/root_password_hash`.
When this file is empty, root password login is disabled. When it
contains a hash, root can log in at the VM console with that password.
This does not affect SSH access, which always uses key-based
authentication.

## Bridged Networking

By default, VMs use NAT networking via libvirt's `virbr0` bridge. This
gives VMs internet access but they're not directly accessible from
other machines on your LAN.

For bridged networking, VMs connect directly to your physical network
and get IP addresses from your network's DHCP server. This requires
setting up a bridge interface on the host.

### Setting Up a Bridge with NetworkManager

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

After this, your host's IP address will be on `br0` instead of your
physical interface. Verify with:

```bash
ip addr show br0
```

### Creating a Bridged VM

Once `br0` is configured, create a VM with bridged networking:

```bash
just create myvm core 2048 2 20G bridge
```

You'll be prompted to select from available bridge interfaces. The VM
will get an IP address from your network's DHCP server and be
accessible from other machines on your LAN.

### Changing Network Mode

To change an existing VM from NAT to bridged (or vice versa):

```bash
# Interactive mode - prompts for network type and bridge selection
just network-config myvm

# Or specify directly
just network-config myvm bridge

# Apply the change (preserves /var data)
just upgrade myvm
```

The VM will be briefly stopped during the upgrade, then restarted with
the new network configuration.

## Architecture

```
VM Disk Layout:
  vda (boot) - Read-only root filesystem (QCOW2 with backing file)
  vdb (var)  - Read-write /var filesystem

Filesystem Mounts:
  /      - Read-only (from vda)
  /boot  - Read-only (EFI partition on vda)
  /var   - Read-write (from vdb)
  /home  - Bind mount of /var/home
  /tmp   - tmpfs
```

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md)
