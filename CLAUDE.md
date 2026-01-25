# NixOS Immutable VM Image Builder

## Claude Directives

- Always run `git pull` before making any changes to ensure you have the latest code.
- When working on a branch other than `master`, automatically commit and push changes when done with a task.

## Project Overview

This project builds NixOS virtual machine images for libvirt with an immutable (read-only) root filesystem design. The architecture enables multiple VMs to share a single read-only base image while maintaining separate writable state.

## Architecture

### Filesystem Layout

- **/** (root) - Read-only, contains the immutable NixOS system
- **/var** - Read-write, mounted from a separate disk, stores all mutable state
- **/home** - Bind mount of `/var/home`
- **/var/log/journal** - journald persistent storage location
- **/var/identity** - Per-VM identity files (machine-id, SSH keys, resolv.conf, etc.)
- **/etc** - Read-only (part of root filesystem)
- **/run** - Writable tmpfs for runtime state

### Overriding /etc Files (Placeholder + Bind Mount Pattern)

Since /etc is read-only, per-VM configuration files must use the **placeholder + bind mount** pattern:

1. Create a placeholder file in the base image using `environment.etc`:
   ```nix
   environment.etc."resolv.conf" = lib.mkForce {
     text = "# Placeholder - replaced by bind mount";
     mode = "0644";
   };
   ```

2. Bind mount the actual file over the placeholder:
   ```nix
   fileSystems."/etc/resolv.conf" = {
     device = "/run/resolv.conf";  # or /var/identity/resolv.conf
     options = [ "bind" "nofail" ];
   };
   ```

3. Use a systemd service to populate the source file before the bind mount.

See `modules/identity.nix` for machine-id, `modules/dns-identity.nix` for resolv.conf, and `modules/hosts-identity.nix` for /etc/hosts as examples.

### Machine Identity

Host-specific identity files are stored in `machines/<name>/` and copied to `/var/identity/` on the VM's /var disk:

- `machine-id` - Unique machine identifier
- `ssh_host_ed25519_key` - SSH host key
- `resolv.conf` - DNS configuration
- `hosts` - Extra /etc/hosts entries (optional, one per line like /etc/hosts)
- `tcp_ports` / `udp_ports` - Firewall port configuration
- `admin_authorized_keys` / `user_authorized_keys` - SSH public keys

### Disk Layout

- **Disk 1 (Boot/Root)** - Per-VM QCOW2 image using the shared base image as a backing file, UEFI boot with systemd-boot
- **Disk 2 (State)** - Read-write QCOW2 image mounted at /var

### Multi-VM Design

Each VM instance has:
- Its own boot disk (QCOW2) that uses the shared base image as a **backing file**
- Its own dedicated /var disk for persistent state
- Its own machine identity files defined in per-machine configuration

The base image remains untouched. Each VM's boot disk stores only the delta from the base image (copy-on-write). Upgrades require rebuilding the base image and recreating the per-VM boot disks with the new backing file.

## Directory Structure

```
.
├── flake.nix           # Main flake defining VM image builds
├── flake.lock
├── Justfile            # Command wrapper for all build operations
├── modules/            # Shared NixOS modules
│   ├── base.nix        # Core system configuration
│   ├── filesystem.nix  # Read-only root, /var mount, /home bind mount
│   ├── boot.nix        # UEFI + systemd-boot configuration
│   ├── overlay-etc.nix # /etc overlayfs configuration
│   ├── journald.nix    # journald /var/log/journal configuration
│   └── ...
├── machines/           # Per-VM configurations
│   └── default/        # Default VM configuration
│       ├── meta.nix    # Machine metadata (system architecture)
│       └── default.nix # Selects modules, defines machine identity
└── libvirt/            # Generated libvirt XML definitions
```

## Technology Stack

- **Nix Flakes** - Experimental flakes support enabled throughout
- **nixos-generators** - For building libvirt-compatible VM images
- **libvirt/QEMU/KVM** - Virtualization platform
- **UEFI + systemd-boot** - Boot configuration (no legacy BIOS)
- **Justfile** - Task runner for build commands

## Machine Configuration

Each machine in `machines/<name>/` has two files:

**meta.nix** - Machine metadata imported by flake.nix before evaluation:
```nix
{
  system = "x86_64-linux";  # or "aarch64-linux"
}
```

**default.nix** - NixOS module with machine-specific configuration:
- Sets `nixpkgs.hostPlatform` from meta.nix
- Defines machine identity (hostname, machine-id, SSH keys)
- Selects additional modules to load
- Configures machine-specific settings

To add a new machine, create `machines/<name>/meta.nix` and `machines/<name>/default.nix`, then add the name to the `machines` list in flake.nix.

## Nix Conventions

- Use flakes exclusively (`flake.nix` as entry point)
- Enable experimental features: `nix-command` and `flakes`
- Prefer `lib.mkOption` and `lib.mkEnableOption` for module options
- Use `lib.mkDefault` and `lib.mkForce` appropriately for option priorities
- Organize imports in modules, not in flake.nix where possible
- Machine architecture is specified per-machine in meta.nix, not globally

## Key NixOS Options

```nix
# Read-only root
fileSystems."/".options = [ "ro" ];

# Bind mount /home to /var/home
fileSystems."/home" = {
  device = "/var/home";
  options = [ "bind" ];
};

# UEFI boot
boot.loader.systemd-boot.enable = true;
boot.loader.efi.canTouchEfiVariables = false;  # Read-only root

# Disable automatic garbage collection (breaks on read-only root)
nix.gc.automatic = false;

# journald persistent storage
services.journald.storage = "persistent";

# Placeholder + bind mount pattern for /etc files
environment.etc."machine-id" = {
  text = "placeholder";
  mode = "0444";
};
fileSystems."/etc/machine-id" = {
  device = "/var/identity/machine-id";
  options = [ "bind" ];
};
```

## Build Commands

All commands are wrapped in the Justfile:

```bash
just build              # Build the base VM image
just build-libvirt-xml  # Generate libvirt XML definitions
just create-vm NAME     # Create a new VM with boot disk (backing file) and /var disk
just define-vm NAME     # Define a VM in libvirt
just start-vm NAME      # Start a VM
just list               # List available recipes
```

### Justfile Environment Variables

The Justfile supports environment variable overrides for tool commands, useful for running from containers (e.g., distrobox) or custom setups:

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST_CMD` | `""` | Prefix for all host commands (e.g., `host-spawn`) |
| `SUDO` | `sudo` | Sudo command (set to `""` to disable) |
| `JUST` | `just` | Path to just binary (for recursive recipe calls) |
| `NIX` | `HOST_CMD + " nix"` | Nix command |
| `VIRSH` | `HOST_CMD + " " + SUDO + " virsh"` | Virsh command (includes sudo) |
| `QEMU_IMG` | `HOST_CMD + " qemu-img"` | qemu-img command |
| `GUESTFISH` | `HOST_CMD + " guestfish"` | guestfish command |
| `CP` | `HOST_CMD + " cp"` | cp command |
| `READLINK` | `HOST_CMD + " readlink"` | readlink command |
| `LIBGUESTFS_BACKEND` | `direct` | libguestfs backend (direct avoids SELinux issues) |
| `LIBVIRT_URI` | `qemu:///system` | Libvirt connection URI |
| `OVMF_CODE` | `/usr/share/edk2/ovmf/OVMF_CODE.fd` | OVMF firmware path |
| `OVMF_VARS` | `/usr/share/edk2/ovmf/OVMF_VARS.fd` | OVMF variables template path |

## libvirt XML Requirements

The generated libvirt XML must include:
- Boot disk using QCOW2 with backing file reference to base image
- Read-only flag on the boot disk: `<readonly/>`
- Separate disk definition for /var (read-write)
- UEFI firmware configuration (OVMF)
- Appropriate virtio drivers

## QCOW2 Backing File Setup

```bash
# Create per-VM boot disk with backing file
qemu-img create -f qcow2 -b /path/to/base-image.qcow2 -F qcow2 vm-boot.qcow2

# Create /var disk
qemu-img create -f qcow2 vm-var.qcow2 20G
```

## Development Notes

- Test images locally with `just build && just create test && just start test`
- The root filesystem (including /etc) is read-only; use placeholder + bind mount pattern for per-VM /etc files
- All persistent data must be on /var
- Machine identity files go in `machines/<name>/` and are copied to `/var/identity/` during VM creation
- Use `just upgrade <name>` to sync identity file changes without losing /var data
- Nix garbage collection is disabled to prevent errors on read-only filesystem
- journald writes to /var/log/journal for log persistence across reboots
