---
name: create-vm
description: Create a new NixOS VM on the configured backend (libvirt or proxmox). Use this when the user wants to create a new virtual machine.
allowed-tools: Read, Bash, AskUserQuestion
---

# Create VM Skill

Create a new NixOS VM on the configured backend.

## Instructions

### Step 1: Determine Backend

Read the `.env` file to determine which backend is configured (libvirt or proxmox).

### Step 2: Get Available Profiles

Run `just list-profiles` to get the list of available profiles. Use this to populate the profile selection.

### Step 3: Gather VM Settings

Ask the user for the following settings:

1. **Name** (required) - Free text input, single word VM name. Do not offer multiple choice, let them type it.

2. **Profile** - Multiple choice from the output of `just list-profiles`. Common profiles:
   - `core` - Base system with SSH (recommended for most uses)
   - `docker` - Core + Docker
   - `dev` - Development environment with Docker and Podman

3. **Memory** - RAM in MB. Offer choices:
   - 1024 (1 GB)
   - 4096 (4 GB)
   - 8192 (8 GB)
   - Or type a custom value

4. **vCPUs** - Number of virtual CPU cores. Offer choices:
   - 1
   - 2
   - 4
   - Or type a custom value (any integer >= 1)

5. **Var Size** - Size of /var partition in gigabytes. Offer choices:
   - 20
   - 50
   - 100
   - Or type a custom value (any integer >= 1)

6. **Network** - Depends on the backend:
   - **libvirt**: Offer `nat` or `bridge`
   - **proxmox**: Offer `bridge:vmbr0`, `bridge:vmbr1`, or type custom

### Step 4: Create the VM

Run the create command:

```bash
just create {NAME} {PROFILE} {MEMORY} {VCPUS} {VAR_SIZE} {NETWORK}
```

For var_size, append `G` to the number (e.g., `20G`, `50G`).

### Step 5: Report Results

Tell the user the VM has been created and provide:
- The VM name
- How to start it: `just start {NAME}`
- How to check status: `just status {NAME}`
- How to SSH into it: `just ssh {NAME}` or `just ssh admin@{NAME}`
