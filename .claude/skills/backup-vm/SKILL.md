---
name: backup-vm
description: Create or restore VM backups. Use for full VM backups that can survive VM destruction.
allowed-tools: Read, Bash, AskUserQuestion
---

# Backup VM Skill

Create and restore VM backups.

## Instructions

### Step 1: Choose Action

Ask what they want to do:
- **Create** a backup of a VM
- **List** available backups
- **Restore** a VM from backup

### Step 2: Execute Action

#### Create Backup

Run `just list` to show existing VMs. Ask which VM to backup.

```bash
just backup {NAME}
```

#### List Backups

```bash
just backups
```

#### Restore Backup

First list backups to show available options:
```bash
just backups
```

Ask which VM to restore. The restore command will show available backups for that VM.

**Warn the user:** Restoring will replace the current VM with the backup contents. All current data will be lost.

```bash
just restore-backup {NAME}
```

This will show available backups and prompt for selection.

### Step 3: Report Results

Confirm the action completed. For backups, note where they're stored. For restores, remind them to start the VM.

## Notes

- Backups are stored on the configured backup storage (PVE_BACKUP_STORAGE for Proxmox)
- Backups persist even if the VM is destroyed
- Restoring a backup recreates the VM in its backed-up state
