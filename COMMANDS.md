# Commands

All commands are wrapped in the `Justfile`. If you set up a shell alias (see
[INSTALL.md](INSTALL.md)), replace `just` with your alias name (e.g. `vm` or
`pve`). For the Proxmox backend, prefix commands with `BACKEND=proxmox` or set
it in your `.env`.

## Building

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

See [PROFILES.md](PROFILES.md) for the list of available profiles.

## VM Lifecycle

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

## VM Information

| Command | Description |
|---------|-------------|
| `just list` | List managed VMs |
| `just status <name>` | Show VM status and IP address |
| `just list-machines` | List all machine configs |

## Snapshots

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

## Backups

| Command                      | Description                             |
|------------------------------|-----------------------------------------|
| `just backup <name>`         | Create backup of VM                     |
| `just backups`               | List available backups                  |
| `just restore-backup <name>` | Restore backup of VM (choose from list) |

## Maintenance

| Command               | Description                      |
|-----------------------|----------------------------------|
| `just test-connection` | Test connection to backend (libvirt or proxmox) |
| `just console <name>` | Attach to VM serial console      |
| `just ssh <name>`     | SSH into VM (as user)            |
| `just ssh admin@<name>` | SSH into VM (as admin, has sudo) |
| `just clean`          | Remove built images and VM disks |
| `just shell`          | Enter Nix development shell      |

## See also

- [MODES.md](MODES.md) — `just mutable` and immutable / mutable / semi-mutable VMs
- [PROFILES.md](PROFILES.md) — profiles you can build and combine
- [CONFIGURATION.md](CONFIGURATION.md) — the `machines/<name>/` config files
