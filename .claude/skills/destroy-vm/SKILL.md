---
name: destroy-vm
description: Destroy a VM and its disks. Use when user wants to remove a VM but keep its machine config for later recreation.
allowed-tools: Read, Bash, AskUserQuestion
---

# Destroy VM Skill

Destroy a VM and delete its disks while preserving the machine config.

## Instructions

### Step 1: Get VM Name

Run `just list` to show existing VMs. Ask which VM to destroy.

### Step 2: Confirm Destruction

**IMPORTANT:** Warn the user clearly:
- All VM disks will be deleted
- All data in /var and /home will be PERMANENTLY LOST
- The machine config (machines/{name}/) will be preserved
- They can recreate the VM later with `just recreate {name}`

Ask for explicit confirmation.

### Step 3: Destroy

Run:
```bash
yes | just destroy {NAME}
```

### Step 4: Report Results

Confirm the VM was destroyed. Mention they can recreate it with `just recreate {name}` or fully remove it with `just purge {name}`.

---

## Purge Option

If the user wants to completely remove everything including machine config, use:
```bash
yes | just purge {NAME}
```

This deletes the VM, disks, AND machine config. Cannot be undone.
