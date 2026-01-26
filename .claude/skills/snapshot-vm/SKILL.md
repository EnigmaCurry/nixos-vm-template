---
name: snapshot-vm
description: Create, list, or restore VM snapshots. Use for point-in-time snapshots of VM state.
allowed-tools: Read, Bash, AskUserQuestion
---

# Snapshot VM Skill

Manage VM snapshots - create, list, or restore.

## Instructions

### Step 1: Get VM Name

Run `just list` to show existing VMs. Ask which VM to manage snapshots for.

### Step 2: Choose Action

Ask what they want to do:
- **Create** a new snapshot
- **List** existing snapshots
- **Restore** to a previous snapshot

### Step 3: Execute Action

#### Create Snapshot

Ask for a snapshot name (e.g., "before-upgrade", "working-state").

```bash
just snapshot {NAME} {SNAPSHOT_NAME}
```

#### List Snapshots

```bash
just snapshots {NAME}
```

#### Restore Snapshot

First list snapshots:
```bash
just snapshots {NAME}
```

Ask which snapshot to restore to. Warn that this will revert the VM to that point in time.

```bash
just restore-snapshot {NAME} {SNAPSHOT_NAME}
```

### Step 4: Report Results

Confirm the action completed successfully.

## Notes

- Snapshots are deleted during `upgrade` and `recreate` operations
- Snapshots capture both boot and /var disk state
