---
name: purge-vm
description: Completely remove a VM including its machine config. Use when user wants to permanently delete everything about a VM.
allowed-tools: Read, Bash, AskUserQuestion
---

# Purge VM Skill

Completely remove a VM including its disks AND machine configuration. This cannot be undone.

## Instructions

### Step 1: Get VM Name

Run `just list-machines` to show existing machine configs. Ask which VM to purge.

### Step 2: Confirm Purge

**IMPORTANT:** Warn the user clearly:
- The VM will be stopped and removed
- All VM disks will be deleted
- All data in /var and /home will be PERMANENTLY LOST
- The machine config (machines/{name}/) will ALSO be deleted
- This CANNOT be undone - unlike `destroy`, there's no way to recreate the VM

Ask for explicit confirmation.

### Step 3: Purge

Run:
```bash
yes | just purge {NAME}
```

The `yes |` is required to bypass the interactive confirmation prompt.

### Step 4: Report Results

Confirm the VM and its config were completely removed.
