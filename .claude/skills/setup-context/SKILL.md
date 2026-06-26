---
name: setup-context
description: Set up a new nixos-vm-template context for managing VMs on a hypervisor (libvirt, proxmox KVM, or proxmox-lxc containers). Use this when the user wants to configure a new VM management context, create an alias, or set up environment variables for a backend.
allowed-tools: Read, Write, AskUserQuestion, Bash
---

# Setup Context Skill

Configure the `.env` file for managing VMs on a hypervisor.

## Instructions

### Step 1: Ask for Backend Type

Use AskUserQuestion to ask which backend:
- **libvirt** - Local QEMU/KVM via libvirt
- **proxmox** - Remote Proxmox VE server via SSH (KVM VMs)
- **proxmox-lxc** - Remote Proxmox VE server via SSH (LXC containers; mutable-only, supports host ZFS bind mounts and the `nas` profile)

### Step 2: Gather Backend-Specific Settings

#### For libvirt backend:

Most users can accept defaults. Only ask about non-default settings if user indicates special requirements (like running from a container).

Create `.env` with just:
```bash
BACKEND=libvirt
```

#### For proxmox backend:

Ask the user (as plain text prompts, not multiple choice):
- **PVE_HOST** (required) - SSH config host name (e.g., `pve`) or hostname/IP
- **PVE_STORAGE** - Storage for VM disks (default: local)
- **PVE_BRIDGE** - Network bridge (default: vmbr0)

Explain that they should configure their SSH connection in `~/.ssh/config`:
```
Host pve
    HostName 192.168.1.100
    User root
    Port 22
```

And use ssh-agent for key authentication:
```bash
eval $(ssh-agent)
ssh-add ~/.ssh/id_ed25519
```

#### For proxmox-lxc backend:

Same SSH setup as proxmox. Ask the user (plain text prompts):
- **PVE_HOST** (required) - SSH config host name (e.g., `pve`) or hostname/IP
- **PVE_STORAGE** - CT-capable rootfs storage (a `zfspool` or `dir` storage, e.g. `local-zfs` or a pool name like `rust`; NOT a bare ZFS pool path). Check with `ssh <host> pvesm status`.
- **PVE_BRIDGE** - Network bridge (default: vmbr0)

Notes specific to this backend:
- LXC is **mutable-only** (read-write rootfs; `nixos-rebuild` runs inside). There is no immutable/semi-mutable mode.
- The `nas` profile (NFS + Samba) is LXC-only and runs the container **privileged** with an apparmor-unconfined override (for kernel NFS).
- Host ZFS datasets are **bind-mounted** into the container (`<dataset>:<container-path>`, e.g. `rust/nas:/srv/nas`); a bare dataset name is created on the host if missing. Configure these in the create wizard.

Example `.env`:
```bash
BACKEND=proxmox-lxc
PVE_HOST=pve
PVE_STORAGE=local-zfs
PVE_BRIDGE=vmbr0
PVE_BACKUP_STORAGE=local
```

### Step 3: Create the .env file

Create/overwrite the `.env` file at the project root.

Example `.env` for libvirt:
```bash
BACKEND=libvirt
```

Example `.env` for proxmox:
```bash
BACKEND=proxmox
PVE_HOST=pve
PVE_STORAGE=local-lvm
PVE_BRIDGE=vmbr0
PVE_BACKUP_STORAGE=local
```

### Step 4: Test Connection

After creating the `.env` file, run the connection test:

```bash
just test-connection
```

**Important:** Warn the user that they may need to authenticate multiple times during the test (SSH key passphrase prompts if not using ssh-agent, or host key verification).

If the test passes, tell the user the setup is complete and they can now use `just` commands.

## Variable Reference

### Libvirt Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKEND` | `libvirt` | Set to `libvirt` |
| `LIBVIRT_URI` | `qemu:///system` | Libvirt connection URI |
| `HOST_CMD` | (empty) | Prefix for host commands (e.g., `host-spawn` for distrobox) |

### Proxmox Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKEND` | - | Set to `proxmox` |
| `PVE_HOST` | (required) | SSH config host name (or hostname/IP) |
| `PVE_NODE` | `$PVE_HOST` | Proxmox node name (for clusters) |
| `PVE_STORAGE` | `local` | Proxmox storage for VM disks |
| `PVE_BRIDGE` | `vmbr0` | Network bridge name |
| `PVE_DISK_FORMAT` | `qcow2` | Disk format (qcow2, raw, vmdk) |
| `PVE_BACKUP_STORAGE` | `local` | Proxmox storage for backups |

### Proxmox-LXC Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKEND` | - | Set to `proxmox-lxc` |
| `PVE_HOST` | (required) | SSH config host name (or hostname/IP) |
| `PVE_NODE` | `$PVE_HOST` | Proxmox node name (for clusters) |
| `PVE_STORAGE` | `local` | CT-capable rootfs storage (zfspool/dir; NOT a bare pool path) |
| `PVE_BRIDGE` | `vmbr0` | Network bridge name |
| `PVE_BACKUP_STORAGE` | `local` | Proxmox storage for backups |
| `PVE_TEMPLATE_DIR` | `/var/lib/vz/template/cache` | Where the LXC template tarball is staged |
| `LXC_FEATURES` | `nesting=1` | `pct create --features` value |
