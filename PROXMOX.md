# Proxmox VE Backend

The Proxmox backend builds VM images locally, then transfers them to a
remote Proxmox VE node via SSH. All Proxmox operations use `qm` and
`pvesh` commands over SSH — no API tokens needed. See [INSTALL.md](INSTALL.md)
for Nix and `just` setup first.

Select this backend with `BACKEND=proxmox` (in your environment or `.env`).

## Additional Requirements

**Build machine:** `rsync`, `ssh`, `jq`

**Proxmox node:** SSH access as root, `nbd` kernel module (for identity
sync), `qemu-nbd` (standard on PVE)

## SSH Configuration

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

## Environment Variables

Set these in your `.env` file or as environment variables:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PVE_HOST` | Yes | - | SSH config host name (or hostname/IP). SSH always logs in as `root` — any `user@` prefix is stripped. |
| `PVE_NODE` | Yes | `$PVE_HOST` | PVE node name (must match Proxmox hostname) |
| `PVE_STORAGE` | No | `local` | Target storage for VM disks |
| `PVE_BRIDGE` | No | `vmbr0` | Default network bridge |
| `PVE_DISK_FORMAT` | No | `auto` | Disk format for import (`auto`, `qcow2`, or `raw`). `auto` detects from the PVE storage type. |
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

## Quick Start (Proxmox)

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

## How It Works

1. **Build**: Nix builds the NixOS image locally as a QCOW2 file
2. **Flatten**: The boot disk is flattened (backing file removed) for transfer
3. **Transfer**: `rsync` sends the boot and var disks to a staging directory on PVE
4. **Import**: `qm importdisk` imports the disks into the configured storage
5. **Configure**: The VM is created with OVMF UEFI, q35 machine type, serial console, and virtio disks

## VMID Management

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

## Identity Sync

The `just upgrade` command syncs identity files to the VM's `/var` disk
without downloading it. It uses `qemu-nbd` on the PVE node to mount the
var disk in place, rsyncs only the small identity files, then unmounts.
This works regardless of var disk size.

## Disk Format

`PVE_DISK_FORMAT=auto` (the default) queries the PVE storage type over SSH
and picks the right format. Set it to `qcow2` or `raw` to override.

| Storage Type | Auto-detected Format | Why |
|--------------|---------------------|-----|
| `dir` / `nfs` / `cifs` / `cephfs` / `btrfs` | `qcow2` | File-backed; qcow2 gives thin + snapshots |
| `zfspool` | `raw` | zvol; ZFS handles thin + snapshots natively |
| `lvm` / `lvmthin` | `raw` | Storage layer provides thin + snapshots |
| `rbd` (Ceph) / `iscsi` | `raw` | Block storage; qcow2 unsupported |

## Proxmox Networking

During `just create`, an interactive bridge picker lists all bridges on
the Proxmox node with their details (IP, subnet, ports, comment):

```
Select network bridge:
  vmbr0 (10.0.0.1/24, enp6s0)
  vmbr1 (10.56.0.1/24, NAT bridge)
```

After selecting a bridge, you'll be prompted for DHCP vs static IP
(see [Static IP Configuration](LIBVIRT.md#static-ip-configuration)).

For batch/scripted use, specify the bridge directly:

```bash
# Use default bridge (vmbr0)
BACKEND=proxmox just create-batch myvm core 2048 2 30G bridge:vmbr0

# Use a specific bridge with static IP
BACKEND=proxmox just create-batch myvm core 2048 2 30G bridge:vmbr1 "10.56.0.5/24,10.56.0.1"
```

## GPU passthrough

The Proxmox backend can pass host PCI devices through to a VM via the
per-machine file `machines/<name>/pci_devices`. Each non-comment line
becomes one `--hostpci<N>` argument to `qm set`; run `just upgrade
<name>` (or `just recreate`) to apply changes.

```
# machines/moon/pci_devices
# Common forms — see `man qm` for the full hostpci syntax.
0000:01:00.0                    # bare BDF (GPU function)
0000:01:00.1                    # sibling audio function (HDMI audio)
0000:02:00,pcie=1,x-vga=1       # full slot, PCIe + primary VGA
```

For NVIDIA GPUs pass **both** the VGA function (`00.0`) and the HDMI
audio function (`00.1`), or audio in the guest will break.

When you `just create` a VM with the `moonshine-nvidia` or
`sunshine-plasma-nvidia` profile, the wizard queries the Proxmox node
for display-class devices (and their sibling audio functions) and lets
you multi-select which to pass through. For any other profile, edit
`pci_devices` by hand.

**Host-side prerequisites** (out of scope for this repo):

- VT-d / AMD-Vi enabled in the PVE host's BIOS.
- The passed-through PCI device bound to `vfio-pci` on the host
  (typically via `/etc/modprobe.d/vfio.conf` + a kernel cmdline entry).
- See the [Proxmox PCI(e) Passthrough
  wiki](https://pve.proxmox.com/wiki/PCI_Passthrough) for the full
  host setup.

## Backups (Proxmox)

Proxmox backups use `vzdump` and are stored on `PVE_BACKUP_STORAGE`:

```bash
BACKEND=proxmox just backup myvm       # Create vzdump backup
BACKEND=proxmox just backups           # List backups (managed VMs only)
BACKEND=proxmox just restore-backup myvm  # Restore from backup
```
