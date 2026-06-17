# Claude Code Integration

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

For simple operations, use `just` commands directly (see
[COMMANDS.md](COMMANDS.md)):

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
