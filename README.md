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
- Static IP or DHCP for bridged VMs (interactive or batch)
- Interactive bridge management (create, add ports, activate)
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

## Two Ways to Use This

There are two distinct workflows, depending on whether you want to *run*
the published VM images or *build your own*:

| | Production deployment | Development |
|---|---|---|
| **Goal** | Deploy the official, pre-built images | Customize the system and build your own images |
| **Entry point** | `bootstrap.bb` (the `bb` one-liner below) | `just` recipes in a cloned repo |
| **Where images come from** | Downloaded from the binary image repository | Built locally with Nix |
| **Requires Nix?** | **No** | **Yes** |
| **Tools needed** | `bb` + a few standard CLI tools (see below) | `nix`, `just`, `qemu-img`, `guestfish`, … |

### Production: Binary Image Repository (no Nix)

For production deployments you don't need Nix, the `just` build toolchain,
or even a local clone. The `bootstrap.bb` script downloads pre-built images
from the public binary image repository and creates VMs from them. It runs
on [babashka (`bb`)](https://github.com/babashka/babashka), a fast-starting
Clojure interpreter.

Run it straight from the web (it clones/updates a private working copy under
`~/.cache/nixos-vm-template` and re-execs the latest version):

```bash
bb -e '(load-string (slurp "https://github.com/EnigmaCurry/nixos-vm-template/raw/refs/heads/master/bootstrap.bb"))'
```

The wizard walks you through selecting a backend, downloading a profile
image, and creating or managing VMs. Machine configs are stored under
`~/.config/nixos-vm-template/machines`.

**Requirements (production):**

- `bb` ([babashka](https://github.com/babashka/babashka)) — must be installed first; it runs the one-liner
- `curl` — download images
- `qemu-img` — create the boot and `/var` disks
- `guestfish` (libguestfs-tools) — inject per-VM identity into the disks
- `readlink` (coreutils)
- **libvirt backend:** `virsh` (libvirt-clients)
- **proxmox backend:** `ssh` + `rsync` (the Proxmox node runs `qm`/`pvesh`)

The script checks for these on startup and, on Debian/Ubuntu, prints the
exact `apt-get install` line for anything missing. Notably, **`nix` is not
required** — image building happens upstream in CI, and you only consume the
results.

### Development: Local Builds (requires Nix)

To customize the images — add packages, change configuration, create new
profiles — you build them yourself from a cloned repo with Nix and `just`.
This is the workflow the rest of this README documents, starting with the
requirements below.

If you want to publish your *own* binary image repository from your fork —
so your own deployments can use the Nix-free `bootstrap.bb` workflow above —
see [CI.md](CI.md). It walks through setting up a Woodpecker CI pipeline that
builds the images and publishes them to S3-compatible storage.

## Requirements (Common, for local builds)

> [!NOTE]
> These requirements are for the **development / local-build** workflow. If
> you only want to deploy the pre-built images, see
> [Production: Binary Image Repository](#production-binary-image-repository-no-nix)
> above — it does not need Nix or `just`.

- Linux build machine with KVM support
- `nix` package manager (with flakes enabled)

- `just` (command runner)

Those are the only things you install by hand. Every other build tool —
`bb` ([babashka](https://github.com/babashka/babashka), which runs the
VM-management commands), `qemu-img`, and `guestfish` — is provided by this
flake's development shell, and the `just` recipes run themselves inside it
(`nix develop --command …`) automatically. So a bare clone plus Nix and `just`
is enough; there's no need to install the rest through your distro's package
manager or to enter `nix develop` yourself.

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

The only build tool you need on your `PATH` is `just`; install it with Nix:

```bash
nix profile add nixpkgs#just
```

Every `just` recipe runs the VM-management CLI inside the flake's development
shell automatically (via `nix develop --command`), so `bb`, `qemu-img`,
`guestfish`, and the other build tools are pulled in on demand — you don't need
to install them or enter `nix develop` yourself. The first command may take a
moment while Nix realises the dev shell; subsequent runs are cached.

> [!TIP]
> If you're iterating and want to skip the per-command `nix develop` wrapper,
> enter the shell once with `nix develop` (which puts every tool on `PATH`) and
> set `VM_CLI="bb -m vm.cli"` to make the recipes call `bb` directly.

### Run from anywhere (a shell alias)

`just` has flags to point it at a `Justfile` (`-f`), a working directory
(`-d`), and an env file (`-E`) regardless of your current directory. Wrapping
those in a shell alias lets you run the recipes from anywhere, and keeps your
backend config (`BACKEND`, `PVE_HOST`, …) in `~/.config` instead of inside the
clone. The alias name is yours to choose — `vm` is just an example:

```bash
# Add to ~/.bashrc (or ~/.zshrc)
export NIXOS_VM_TEMPLATE="$HOME/nixos-vm-template"   # wherever you cloned the repo
alias vm="just -f '$NIXOS_VM_TEMPLATE/Justfile' -d '$NIXOS_VM_TEMPLATE' -E '$HOME/.config/nixos-vm-template/env'"
```

The outer double quotes expand the variables when the alias is defined; the
inner single quotes keep the resulting paths intact at call time. Now any recipe
in this guide works as `vm <recipe>`:

```bash
vm create myvm
vm status myvm
vm ssh myvm
```

#### Tab completion and per-backend aliases

The completion script in [`completions/vm.bash`](completions/vm.bash) provides a
`nixos-vm-template-alias <alias> <env-file> [repo-root]` helper that defines an alias **and**
wires up its completion in one step. Because each alias carries its own env file,
this is also how you give each backend its own command — e.g. `vm` for libvirt
and `pve` for proxmox, each completing against its own VMs:

```bash
# Add to ~/.bashrc (replaces the manual `alias vm=…` line above)
export NIXOS_VM_TEMPLATE="$HOME/nixos-vm-template"
source "$NIXOS_VM_TEMPLATE/completions/vm.bash"

nixos-vm-template-alias vm  "$HOME/.config/nixos-vm-template/env"      # libvirt
nixos-vm-template-alias pve "$HOME/.config/nixos-vm-template/pve.env"  # proxmox
```

Put `BACKEND=libvirt` in `env` and `BACKEND=proxmox` (plus `PVE_HOST=…`) in
`pve.env`. Now `vm <Tab>` and `pve <Tab>` complete recipe names, and recipe
arguments complete to the right values — VM names, profiles (comma-separated
lists included), and network modes — each querying its own backend.

You can name the aliases anything (`nixos-vm-template-alias lab "$HOME/.config/.../lab.env"`),
and register as many backends/hosts as you like. If you prefer to define aliases
by hand, register completion for them explicitly instead: `complete -F _vm vm pve`.

On zsh, enable bash-completion compatibility first:
`autoload -U +X bashcompinit && bashcompinit` before the `source` line.

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
and get IP addresses from your network's DHCP server (or use a static
IP). This requires a bridge interface on the host.

#### Interactive Bridge Setup

When you select "Bridge" during `just create`, an interactive picker
shows available bridges with their state, IP address, and physical
interfaces:

```
Select network bridge:
  br0 (up, 10.13.14.1/24, enp6s0)
  br1 (down)
  Create new bridge
```

The wizard will guide you through:
- **Creating a bridge** if none exist (or choose "Create new bridge")
- **Adding a physical interface** if the bridge has no ports
- **Bringing the bridge up** if it's currently down

All bridge management uses NetworkManager (`nmcli`) so connections
persist across reboots.

#### Manual Bridge Setup

You can also set up bridges manually:

```bash
# Create the bridge
sudo nmcli connection add type bridge ifname br0 con-name br0 stp no

# Add your physical interface (replace enp6s0)
sudo nmcli connection add type bridge-slave ifname enp6s0 master br0

# Bring up the bridge (WARNING: briefly disconnects network!)
sudo nmcli connection down "Wired connection 1" && sudo nmcli connection up br0
```

#### Static IP Configuration

When using bridged networking, you can assign a static IP instead of
relying on DHCP. The interactive wizard prompts for DHCP vs Static
after bridge selection:

```
IP address configuration:
  DHCP (automatic)
  Static IP
```

If you choose Static IP, you'll be prompted for:
- **IP address** with CIDR notation (e.g., `10.13.14.5/24`) — the bridge
  subnet is auto-detected and shown as the example
- **Gateway** — discovered from the host routing table, or defaults to
  `.1` on the subnet
- **DNS servers** — choose from gateway, Cloudflare, Google, or custom

The CIDR mask (`/24`) is automatically appended if you enter a bare IP
address.

Static IP config is saved in `machines/<name>/static_ip` and applied
at boot. Remove this file and run `just upgrade` to switch back to
DHCP.

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

Each VM's Proxmox VMID is stored in `machines/<name>/vmid`. During
`just create` or `just clone`, you will be prompted to enter a VMID
with the next available ID from Proxmox as the default — press Enter
to accept it, or type a different ID:

```
Allocating VMID from Proxmox...
Enter VMID [105]:
```

Once assigned, the VMID is saved and reused for subsequent operations
(recreate, upgrade, etc.). The script validates that the VMID is
either available or already belongs to a VM with the same name. If
you enter a VMID that's already taken by another VM, you'll be
re-prompted.

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

During `just create`, an interactive bridge picker lists all bridges on
the Proxmox node with their details (IP, subnet, ports, comment):

```
Select network bridge:
  vmbr0 (10.0.0.1/24, enp6s0)
  vmbr1 (10.56.0.1/24, NAT bridge)
```

After selecting a bridge, you'll be prompted for DHCP vs static IP
(see [Static IP Configuration](#static-ip-configuration) above).

For batch/scripted use, specify the bridge directly:

```bash
# Use default bridge (vmbr0)
BACKEND=proxmox just create-batch myvm core 2048 2 30G bridge:vmbr0

# Use a specific bridge with static IP
BACKEND=proxmox just create-batch myvm core 2048 2 30G bridge:vmbr1 "10.56.0.5/24,10.56.0.1"
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
(name, profile, memory, vcpus, disk size, network mode, static IP). After
starting a VM, `create` waits for the IP address and prints SSH login
instructions. If the VM is already running, `create` will abort and tell you
to destroy it first. No arguments are required:

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

# With static IP (address/CIDR,gateway)
just create-batch webserver docker 4096 4 50G bridge:br0 "10.13.14.5/24,10.13.14.1"

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

### Mutable VMs

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

#### Upgrading Mutable VMs

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

#### Mutable VM Internals

| Feature | Immutable VM | Mutable VM |
|---------|--------------|------------|
| Disk layout | Boot disk + var disk | Single disk |
| Root filesystem | Read-only | Read-write |
| Identity files | `/var/identity/` | `/etc/` (hostname, machine-id, SSH keys) |
| Firewall rules | `/var/identity/tcp_ports` | `/etc/firewall-ports/tcp_ports` |
| Static IP | `/var/identity/static_ip` | `/etc/network-config/static_ip` |
| Root password | `/var/identity/root_password_hash` | `/etc/root_password_hash` |
| Upgrade method | `just upgrade` from host | `nixos-rebuild` inside VM |
| Thin provisioning | Yes (QCOW2 backing files) | No (full disk copy) |

### Semi-Mutable VMs

Semi-mutable VMs offer a middle ground: the root filesystem remains
read-only (like immutable VMs), but `/nix` is writable via an overlayfs
overlay. This lets you install packages at runtime with `nix profile
install` while keeping the base system immutable and upgradeable from
the host.

**Important caveat:** The /nix overlay is wiped on every `just upgrade`.
User-installed packages must be reinstalled after each upgrade. This is
by design — the overlay becomes inconsistent when the base image changes,
so a clean wipe is the only safe upgrade path.

- **Read-only root** - same corruption resistance as immutable VMs
- **Writable /nix** - install packages at runtime via overlay
- **Two-disk layout** - same as immutable (boot disk + var disk, thin provisioned)
- **Host-upgradeable** - `just upgrade` works (overlay is wiped on each upgrade)
- **Survives reboots** - installed packages persist across reboots

**When to use semi-mutable VMs:**
- You want an immutable base but need to install a few extra packages at runtime
- You want `nix profile install` without committing to a fully mutable system
- You want the upgrade simplicity of immutable VMs

Use `just mutable` to select semi-mutable mode for an existing machine config:

```bash
just mutable myvm      # Select "Semi-mutable" from the interactive prompt
just upgrade myvm      # Apply the change (preserves /var data)
```

Or set the `mutable` file manually before creating a new VM:

```bash
mkdir -p machines/myvm
echo "semi" > machines/myvm/mutable
just create myvm docker,dev
```

#### Upgrading Semi-Mutable VMs

Semi-mutable VMs are upgraded the same way as immutable VMs:

```bash
just upgrade myvm
```

The upgrade rebuilds the base image, replaces the boot disk, and **wipes
the /nix overlay**. Any packages installed via `nix profile install`
will need to be reinstalled after upgrade.

#### Semi-Mutable VM Internals

| Feature | Immutable VM | Semi-Mutable VM | Mutable VM |
|---------|--------------|-----------------|------------|
| Root filesystem | Read-only | Read-only | Read-write |
| /nix | Read-only | Writable (overlay) | Read-write |
| Disk layout | Boot + var | Boot + var | Single disk |
| Thin provisioning | Yes | Yes | No |
| `nix profile install` | No | Yes | Yes |
| Upgrade method | `just upgrade` | `just upgrade` (wipes overlay) | `nixos-rebuild` inside VM |
| Nix GC | Disabled | Enabled (weekly) | Enabled (weekly) |

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
| **rust** | Rust toolchain from Nix packages |
| **dev** | Development tools (neovim, tmux, etc.) |
| **home-manager** | Home-manager with sway-home modules (emacs, shell config, etc.) |
| **claude** | Claude Code CLI (Anthropic's AI coding assistant) |
| **open-code** | Open Code CLI (open-source AI coding assistant) |

> **Tip for agentic use:** Consider enabling
> [semi-mutable mode](#semi-mutable-vms) for `claude` or `open-code` VMs
> (`echo "semi" > machines/<name>/mutable`). This gives a writable `/nix`
> overlay so that software can be installed on the fly with
> `nix profile install`, and nix-based projects can build and evaluate
> flakes — all while keeping the root filesystem immutable and
> host-upgradeable.

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

## Continuous Integration

Automated image builds and S3 publishing via Woodpecker CI. See
[CI.md](CI.md) for setup instructions.

## Machine Configuration

Each VM has a machine config directory at `machines/<name>/` containing:

- `profile` - Which profile to use
- `mutable` - VM mode: "true" for mutable (single read-write disk), "semi" for semi-mutable (read-only root + writable /nix overlay), absent for immutable
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
- `static_ip` - Static IP config (`address=` and `gateway=` lines); absent = DHCP
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
| Immutable / Semi-mutable | `/var/identity/tcp_ports`, `/var/identity/udp_ports` | `firewall-identity.service` at boot | `just upgrade` syncs from machine config |
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
