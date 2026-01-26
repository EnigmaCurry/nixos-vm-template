---
name: upgrade-vm
description: Upgrade a VM to a new image while preserving /var data. Use when user wants to update a VM's base image without losing data.
allowed-tools: Read, Bash, AskUserQuestion
---

# Upgrade VM Skill

Upgrade a VM to a rebuilt base image while preserving all /var data.

## Instructions

### Step 1: Get VM Name

Run `just list` to show existing VMs. Ask which VM to upgrade.

### Step 2: Explain What Will Happen

Tell the user:
- The VM will be stopped
- The profile image will be rebuilt with latest changes
- A new boot disk will replace the old one
- All /var data (home directories, logs, app data) will be preserved
- Any snapshots will be deleted
- The VM will be restarted

### Step 3: Confirm

Ask for confirmation to proceed.

### Step 4: Upgrade

Run:
```bash
yes | just upgrade {NAME}
```

This may take several minutes to rebuild and transfer the image.

### Step 5: Report Results

Confirm the upgrade completed and the VM is running.
