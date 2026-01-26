---
name: recreate-vm
description: Recreate a VM from its existing machine config. Use when user wants to rebuild a destroyed VM or reset a VM to fresh state.
allowed-tools: Read, Bash, AskUserQuestion
---

# Recreate VM Skill

Recreate a VM from its existing machine configuration. This destroys current disks and creates fresh ones.

## Instructions

### Step 1: Get VM Name

Run `just list-machines` to show existing machine configs. Ask which VM to recreate.

### Step 2: Confirm Recreation

**IMPORTANT:** Warn the user clearly:
- If the VM currently exists, it will be stopped and its disks deleted
- All data in /var and /home will be PERMANENTLY LOST
- Fresh disks will be created using the machine's profile
- The machine config (identity, SSH keys, etc.) will be preserved

Ask for explicit confirmation.

### Step 3: Gather Options (Optional)

Ask if they want to customize:

1. **Var Size** - Size of /var partition (default: 30G). Offer choices:
   - 30 (default)
   - 50
   - 100
   - Or type a custom value

2. **Network** - Network configuration (optional, uses existing config if not specified)

### Step 4: Recreate

Run:
```bash
yes | just recreate {NAME} {VAR_SIZE}
```

Or with network:
```bash
yes | just recreate {NAME} {VAR_SIZE} {NETWORK}
```

The `yes |` is required to bypass the interactive confirmation prompt.

For var_size, append `G` to the number (e.g., `30G`, `50G`).

### Step 5: Report Results

Confirm the VM was recreated and is running. Provide:
- How to check status: `just status {NAME}`
- How to SSH into it: `just ssh {NAME}` or `just ssh admin@{NAME}`
