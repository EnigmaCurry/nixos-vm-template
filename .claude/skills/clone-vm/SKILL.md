---
name: clone-vm
description: Clone an existing VM to create a new VM with copied /var data but fresh identity.
allowed-tools: Read, Bash, AskUserQuestion
---

# Clone VM Skill

Clone an existing VM, copying its /var disk while generating a fresh identity.

## Instructions

### Step 1: Get Source VM

Run `just list` to show existing VMs. Ask the user which VM to clone.

### Step 2: Get Destination Name

Ask for the new VM name (free text, single word).

### Step 3: Optional Overrides

Ask if they want to override resources (memory, vcpus, network) or keep the source VM's settings.

If they want to override, ask for:
- Memory (MB): 1024, 4096, 8192, or custom
- vCPUs: 1, 2, 4, or custom
- Network: depends on backend (libvirt: nat/bridge, proxmox: bridge:vmbr0/bridge:vmbr1/custom)

### Step 4: Clone

Run:
```bash
just clone {SOURCE} {DEST} {MEMORY} {VCPUS} {NETWORK}
```

Leave memory/vcpus/network empty to use source VM's values.

### Step 5: Report Results

Tell the user the clone was created and how to start it.
