#!/usr/bin/env bash
# Proxmox VE backend for NixOS VM Template
# Uses SSH to PVE node for all operations (pvesh, qm, rsync, qemu-nbd).
# Sourced by Justfile recipes - do not execute directly.

set -euo pipefail

# Source common functions
BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BACKEND_DIR/../common.sh"

# Backend-specific environment defaults
PVE_HOST="${PVE_HOST:-}"
PVE_NODE="${PVE_NODE:-$PVE_HOST}"
PVE_SSH_USER="${PVE_SSH_USER:-root}"
PVE_SSH_KEY="${PVE_SSH_KEY:-}"
PVE_SSH_PORT="${PVE_SSH_PORT:-22}"
PVE_STORAGE="${PVE_STORAGE:-local}"
PVE_BRIDGE="${PVE_BRIDGE:-vmbr0}"
PVE_STAGING_DIR="${PVE_STAGING_DIR:-/tmp/nixos-vm-staging}"

QEMU_IMG="${QEMU_IMG:-${HOST_CMD:+$HOST_CMD }qemu-img}"
GUESTFISH="${GUESTFISH:-${HOST_CMD:+$HOST_CMD }guestfish}"
export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"

# --- SSH Helpers ---

# Validate that PVE_HOST is set
_pve_validate() {
    if [ -z "$PVE_HOST" ]; then
        echo "Error: PVE_HOST is not set."
        echo "Set it via environment variable or .env file:"
        echo "  export PVE_HOST=192.168.1.100"
        echo "  BACKEND=proxmox PVE_HOST=192.168.1.100 just create myvm"
        exit 1
    fi
}

# SSH wrapper for PVE node
pve_ssh() {
    _pve_validate
    local ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)
    if [ -n "$PVE_SSH_KEY" ]; then
        ssh_opts+=(-i "$PVE_SSH_KEY")
    fi
    ssh "${ssh_opts[@]}" "${PVE_SSH_USER}@${PVE_HOST}" -p "${PVE_SSH_PORT}" "$@"
}

# rsync wrapper to PVE node
pve_rsync() {
    _pve_validate
    local rsync_opts=(-avz --progress)
    if [ -n "$PVE_SSH_KEY" ]; then
        rsync_opts+=(-e "ssh -i $PVE_SSH_KEY -o StrictHostKeyChecking=accept-new")
    else
        rsync_opts+=(-e "ssh -o StrictHostKeyChecking=accept-new")
    fi
    rsync "${rsync_opts[@]}" "$@"
}

# Get VMID for a machine by name (stored in machines/<name>/vmid)
pve_get_vmid() {
    local name="$1"
    local vmid_file="$MACHINES_DIR/$name/vmid"
    if [ ! -f "$vmid_file" ]; then
        echo "Error: VMID not found for machine '$name'"
        echo "Expected file: $vmid_file"
        echo "Create the VM first with: BACKEND=proxmox just create $name"
        exit 1
    fi
    cat "$vmid_file"
}

# Wait for a PVE task to complete
pve_wait_task() {
    local upid="$1"
    local timeout="${2:-300}"
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        local status
        status=$(pve_ssh "pvesh get /nodes/$PVE_NODE/tasks/$upid/status --output-format json" 2>/dev/null || echo '{}')
        local task_status
        task_status=$(echo "$status" | jq -r '.status // "unknown"')

        if [ "$task_status" = "stopped" ]; then
            local exit_status
            exit_status=$(echo "$status" | jq -r '.exitstatus // "unknown"')
            if [ "$exit_status" = "OK" ]; then
                return 0
            else
                echo "Error: Task failed with status: $exit_status"
                return 1
            fi
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo "Error: Task timed out after ${timeout}s: $upid"
    return 1
}

# Allocate next available VMID from Proxmox cluster
pve_next_vmid() {
    pve_ssh "pvesh get /cluster/nextid"
}

# --- Backend Primitives ---

# Create VM disks and transfer to Proxmox
backend_create_disks() {
    local name="$1"
    local var_size="${2:-20G}"
    local machine_dir="$MACHINES_DIR/$name"

    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        echo "Run 'BACKEND=proxmox just create $name' first"
        exit 1
    fi

    _pve_validate

    local profile
    profile=$(cat "$machine_dir/profile")

    echo "Creating VM disks: $name (profile: $profile)"
    mkdir -p "$OUTPUT_DIR/vms/$name"

    local profile_image
    profile_image=$($READLINK -f "$OUTPUT_DIR/profiles/$profile")/nixos.qcow2

    if [ ! -f "$profile_image" ]; then
        echo "Error: Profile image not found: $profile_image"
        echo "Run 'just build $profile' first"
        exit 1
    fi

    # Create local boot disk with backing file (for guestfish identity population)
    $QEMU_IMG create -f qcow2 \
        -b "$profile_image" \
        -F qcow2 \
        "$OUTPUT_DIR/vms/$name/boot.qcow2"

    # Create /var disk locally
    $QEMU_IMG create -f qcow2 "$OUTPUT_DIR/vms/$name/var.qcow2" "$var_size"

    # Read identity from machine config and populate /var disk
    local hostname machine_id
    hostname=$(cat "$machine_dir/hostname")
    machine_id=$(cat "$machine_dir/machine-id")

    # Build guestfish commands
    local gf_cmds="run : part-disk /dev/sda gpt : mkfs ext4 /dev/sda1 : mount /dev/sda1 /"
    gf_cmds="$gf_cmds : mkdir-p /identity"
    gf_cmds="$gf_cmds : write /identity/hostname '$hostname'"
    gf_cmds="$gf_cmds : write /identity/machine-id '$machine_id'"

    # Add admin authorized_keys
    if [ -s "$machine_dir/admin_authorized_keys" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/admin_authorized_keys /identity/"
    else
        gf_cmds="$gf_cmds : touch /identity/admin_authorized_keys"
    fi
    gf_cmds="$gf_cmds : chmod 0644 /identity/admin_authorized_keys"
    gf_cmds="$gf_cmds : chown 0 0 /identity/admin_authorized_keys"

    # Add user authorized_keys
    if [ -s "$machine_dir/user_authorized_keys" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/user_authorized_keys /identity/"
    else
        gf_cmds="$gf_cmds : touch /identity/user_authorized_keys"
    fi
    gf_cmds="$gf_cmds : chmod 0644 /identity/user_authorized_keys"
    gf_cmds="$gf_cmds : chown 0 0 /identity/user_authorized_keys"

    # Copy SSH host key
    gf_cmds="$gf_cmds : copy-in $machine_dir/ssh_host_ed25519_key /identity/"
    gf_cmds="$gf_cmds : copy-in $machine_dir/ssh_host_ed25519_key.pub /identity/"
    gf_cmds="$gf_cmds : chmod 0600 /identity/ssh_host_ed25519_key"
    gf_cmds="$gf_cmds : chmod 0644 /identity/ssh_host_ed25519_key.pub"
    gf_cmds="$gf_cmds : chown 0 0 /identity/ssh_host_ed25519_key"
    gf_cmds="$gf_cmds : chown 0 0 /identity/ssh_host_ed25519_key.pub"

    # Copy TCP ports file if present
    if [ -s "$machine_dir/tcp_ports" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/tcp_ports /identity/"
        gf_cmds="$gf_cmds : chmod 0644 /identity/tcp_ports"
        gf_cmds="$gf_cmds : chown 0 0 /identity/tcp_ports"
    fi

    # Copy UDP ports file if present
    if [ -s "$machine_dir/udp_ports" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/udp_ports /identity/"
        gf_cmds="$gf_cmds : chmod 0644 /identity/udp_ports"
        gf_cmds="$gf_cmds : chown 0 0 /identity/udp_ports"
    fi

    # Copy resolv.conf if present
    if [ -s "$machine_dir/resolv.conf" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/resolv.conf /identity/"
        gf_cmds="$gf_cmds : chmod 0644 /identity/resolv.conf"
        gf_cmds="$gf_cmds : chown 0 0 /identity/resolv.conf"
    fi

    # Copy root password hash (empty = no password)
    gf_cmds="$gf_cmds : copy-in $machine_dir/root_password_hash /identity/"
    gf_cmds="$gf_cmds : chmod 0600 /identity/root_password_hash"
    gf_cmds="$gf_cmds : chown 0 0 /identity/root_password_hash"

    # Initialize /var disk
    echo "Initializing /var disk with identity from $machine_dir/"
    eval "$GUESTFISH -a $OUTPUT_DIR/vms/$name/var.qcow2 $gf_cmds"

    # Determine VMID: user-specified > existing file > auto-allocate
    local vmid
    if [ -n "${PVE_VMID:-}" ]; then
        vmid="$PVE_VMID"
        echo "Using user-specified VMID: $vmid"
    elif [ -f "$machine_dir/vmid" ]; then
        vmid=$(cat "$machine_dir/vmid")
        echo "Using existing VMID: $vmid"
    else
        echo "Allocating VMID from Proxmox..."
        vmid=$(pve_next_vmid)
        echo "Allocated VMID: $vmid"
    fi

    # Validate VMID: must be available or belong to a VM with the same name
    local existing_name
    existing_name=$(pve_ssh "qm config $vmid --current 2>/dev/null | grep '^name:'" 2>/dev/null | sed 's/^name: //' || true)
    if [ -n "$existing_name" ]; then
        if [ "$existing_name" != "$name" ]; then
            echo "Error: VMID $vmid is already in use by VM '$existing_name' (expected '$name')"
            exit 1
        fi
    fi

    echo "$vmid" > "$machine_dir/vmid"

    # Parse network configuration
    local network_config bridge
    network_config=$(cat "$machine_dir/network" 2>/dev/null || echo "nat")
    if [[ "$network_config" == bridge:* ]]; then
        bridge="${network_config#bridge:}"
    else
        bridge="$PVE_BRIDGE"
    fi

    # Read MAC address
    local mac_address
    mac_address=$(cat "$machine_dir/mac-address")

    # Read memory and vcpus from config (defaults used if not set)
    local memory vcpus
    memory=$(cat "$machine_dir/memory" 2>/dev/null || echo "2048")
    vcpus=$(cat "$machine_dir/vcpus" 2>/dev/null || echo "2")

    # Create VM shell on Proxmox
    echo "Creating VM on Proxmox (VMID: $vmid, name: $name)..."
    pve_ssh "qm create $vmid \
        --name $name \
        --bios ovmf \
        --machine q35 \
        --agent 1 \
        --cores $vcpus \
        --memory $memory \
        --efidisk0 ${PVE_STORAGE}:1,efitype=4m,pre-enrolled-keys=0 \
        --net0 virtio=$mac_address,bridge=$bridge,firewall=1"

    # Flatten boot disk (remove backing file reference)
    echo "Flattening boot disk for transfer..."
    $QEMU_IMG convert -f qcow2 -O qcow2 \
        "$OUTPUT_DIR/vms/$name/boot.qcow2" \
        "$OUTPUT_DIR/vms/$name/boot-flat.qcow2"

    # Create staging directory on PVE node
    pve_ssh "mkdir -p $PVE_STAGING_DIR/$name"

    # rsync disks to PVE node
    echo "Transferring boot disk to Proxmox..."
    pve_rsync "$OUTPUT_DIR/vms/$name/boot-flat.qcow2" \
        "${PVE_SSH_USER}@${PVE_HOST}:${PVE_STAGING_DIR}/$name/boot.qcow2"

    echo "Transferring var disk to Proxmox..."
    pve_rsync "$OUTPUT_DIR/vms/$name/var.qcow2" \
        "${PVE_SSH_USER}@${PVE_HOST}:${PVE_STAGING_DIR}/$name/var.qcow2"

    # Import disks
    echo "Importing boot disk..."
    pve_ssh "qm importdisk $vmid ${PVE_STAGING_DIR}/$name/boot.qcow2 $PVE_STORAGE"

    echo "Importing var disk..."
    pve_ssh "qm importdisk $vmid ${PVE_STAGING_DIR}/$name/var.qcow2 $PVE_STORAGE"

    # Attach disks and set boot order
    echo "Attaching disks and configuring boot..."
    pve_ssh "qm set $vmid \
        --virtio0 ${PVE_STORAGE}:vm-${vmid}-disk-1 \
        --virtio1 ${PVE_STORAGE}:vm-${vmid}-disk-2 \
        --boot order=virtio0"

    # Cleanup staging files on PVE node
    echo "Cleaning up staging files..."
    pve_ssh "rm -rf ${PVE_STAGING_DIR}/$name"

    # Cleanup local flattened boot disk
    rm -f "$OUTPUT_DIR/vms/$name/boot-flat.qcow2"

    echo "Created VM '$name' on Proxmox (VMID: $vmid)"
    echo "  Boot disk imported to $PVE_STORAGE"
    echo "  Var disk imported to $PVE_STORAGE ($var_size)"
    echo "  Identity: hostname=$hostname"
}

# Sync identity files from machine config to existing /var disk on Proxmox
backend_sync_identity() {
    local name="$1"
    local machine_dir="$MACHINES_DIR/$name"

    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        exit 1
    fi

    _pve_validate

    local vmid
    vmid=$(pve_get_vmid "$name")

    # Check if VM is running
    local was_running=false
    if backend_is_running "$name"; then
        was_running=true
        echo "Stopping VM for identity sync..."
        backend_force_stop "$name"
        # Wait for VM to fully stop
        local wait_count=0
        while backend_is_running "$name" && [ $wait_count -lt 30 ]; do
            sleep 1
            wait_count=$((wait_count + 1))
        done
    fi

    echo "Syncing identity files from $machine_dir/ to VM '$name' (VMID: $vmid)"

    # Get the var disk path from VM config
    local vm_config var_disk_ref var_disk_path
    vm_config=$(pve_ssh "qm config $vmid")
    var_disk_ref=$(echo "$vm_config" | grep "^virtio1:" | sed 's/^virtio1: //' | cut -d',' -f1)

    if [ -z "$var_disk_ref" ]; then
        echo "Error: Could not find var disk (virtio1) for VM $vmid"
        exit 1
    fi

    # Resolve the storage path for the disk
    # For directory-based storage (e.g., local): /var/lib/vz/images/$vmid/vm-$vmid-disk-N.qcow2
    # For LVM/ZFS: need different handling
    var_disk_path=$(pve_ssh "pvesh get /nodes/$PVE_NODE/storage/$PVE_STORAGE/content/$var_disk_ref --output-format json 2>/dev/null | jq -r '.path // empty'" 2>/dev/null || echo "")

    if [ -z "$var_disk_path" ]; then
        # Fallback: construct path for directory-based storage
        local disk_file
        disk_file=$(echo "$var_disk_ref" | sed "s|${PVE_STORAGE}:||")
        var_disk_path="/var/lib/vz/images/$vmid/$disk_file"
    fi

    echo "Var disk path: $var_disk_path"

    # Use qemu-nbd on the PVE node to mount and sync identity
    local mount_point="/mnt/nixos-var-sync-$$"
    pve_ssh "modprobe nbd max_part=8 2>/dev/null || true"
    pve_ssh "mkdir -p $mount_point"

    # Connect nbd and mount
    pve_ssh "qemu-nbd -c /dev/nbd0 '$var_disk_path'"
    sleep 2
    pve_ssh "partprobe /dev/nbd0 2>/dev/null || true"
    sleep 1
    pve_ssh "mount /dev/nbd0p1 $mount_point"

    # Ensure identity directory exists on the mounted disk
    pve_ssh "mkdir -p $mount_point/identity"

    # Sync identity files via rsync
    # Create a temp directory with identity files to rsync
    local tmp_identity
    tmp_identity=$(mktemp -d)
    trap "rm -rf '$tmp_identity'" EXIT

    # Prepare identity files
    local hostname machine_id
    hostname=$(cat "$machine_dir/hostname")
    machine_id=$(cat "$machine_dir/machine-id")
    echo -n "$hostname" > "$tmp_identity/hostname"
    echo -n "$machine_id" > "$tmp_identity/machine-id"

    # Copy identity files to temp dir
    for f in ssh_host_ed25519_key ssh_host_ed25519_key.pub admin_authorized_keys user_authorized_keys tcp_ports udp_ports resolv.conf root_password_hash; do
        if [ -f "$machine_dir/$f" ]; then
            cp "$machine_dir/$f" "$tmp_identity/$f"
        fi
    done

    # rsync identity files to PVE node
    pve_rsync "$tmp_identity/" "${PVE_SSH_USER}@${PVE_HOST}:${mount_point}/identity/"

    # Fix permissions on PVE node
    pve_ssh "chmod 0600 $mount_point/identity/ssh_host_ed25519_key 2>/dev/null || true"
    pve_ssh "chmod 0644 $mount_point/identity/ssh_host_ed25519_key.pub 2>/dev/null || true"
    pve_ssh "chmod 0644 $mount_point/identity/admin_authorized_keys 2>/dev/null || true"
    pve_ssh "chmod 0644 $mount_point/identity/user_authorized_keys 2>/dev/null || true"
    pve_ssh "chmod 0644 $mount_point/identity/hostname 2>/dev/null || true"
    pve_ssh "chmod 0644 $mount_point/identity/machine-id 2>/dev/null || true"
    pve_ssh "chmod 0644 $mount_point/identity/tcp_ports 2>/dev/null || true"
    pve_ssh "chmod 0644 $mount_point/identity/udp_ports 2>/dev/null || true"
    pve_ssh "chmod 0644 $mount_point/identity/resolv.conf 2>/dev/null || true"
    pve_ssh "chmod 0600 $mount_point/identity/root_password_hash 2>/dev/null || true"
    pve_ssh "chown -R 0:0 $mount_point/identity/"

    # Unmount and disconnect nbd
    pve_ssh "umount $mount_point"
    pve_ssh "qemu-nbd -d /dev/nbd0"
    pve_ssh "rmdir $mount_point 2>/dev/null || true"

    # Cleanup temp dir
    rm -rf "$tmp_identity"
    trap - EXIT

    echo "Identity files synced."

    # Restart VM if it was running
    if [ "$was_running" = true ]; then
        echo "Restarting VM..."
        backend_start "$name"
    fi
}

# Generate/update VM config on Proxmox (memory, vcpus)
backend_generate_config() {
    local name="$1"
    local memory="${2:-2048}"
    local vcpus="${3:-2}"

    _pve_validate

    local vmid
    vmid=$(pve_get_vmid "$name")

    # Save memory/vcpus to machine config for future reference
    echo "$memory" > "$MACHINES_DIR/$name/memory"
    echo "$vcpus" > "$MACHINES_DIR/$name/vcpus"

    echo "Updating VM config on Proxmox (VMID: $vmid)..."
    pve_ssh "qm set $vmid --memory $memory --cores $vcpus"
    echo "VM config updated: memory=${memory}MB, vcpus=$vcpus"
}

# Define a VM in Proxmox (no-op - VM is defined during create_disks)
backend_define() {
    local name="$1"
    echo "VM '$name' is already defined on Proxmox (VMID: $(pve_get_vmid "$name"))"
}

# Undefine (destroy) a VM from Proxmox
backend_undefine() {
    local name="$1"

    _pve_validate

    local vmid
    vmid=$(pve_get_vmid "$name")

    echo "Destroying VM on Proxmox (VMID: $vmid)..."
    pve_ssh "qm destroy $vmid --destroy-unreferenced-disks 1 --purge 1" || true
    rm -f "$MACHINES_DIR/$name/vmid"
    echo "VM removed from Proxmox."
}

# --- Lifecycle Functions ---

# Start a VM
backend_start() {
    local name="$1"
    _pve_validate
    local vmid
    vmid=$(pve_get_vmid "$name")
    echo "Starting VM: $name (VMID: $vmid)"
    pve_ssh "qm start $vmid"
}

# Stop a VM (graceful shutdown)
backend_stop() {
    local name="$1"
    _pve_validate
    local vmid
    vmid=$(pve_get_vmid "$name")
    echo "Stopping VM: $name (VMID: $vmid)"
    pve_ssh "qm shutdown $vmid"
}

# Force stop a VM
backend_force_stop() {
    local name="$1"
    _pve_validate
    local vmid
    vmid=$(pve_get_vmid "$name")
    echo "Force stopping VM: $name (VMID: $vmid)"
    pve_ssh "qm stop $vmid" 2>/dev/null || true
}

# Suspend a VM
backend_suspend() {
    local name="$1"
    _pve_validate
    local vmid
    vmid=$(pve_get_vmid "$name")
    echo "Suspending VM '$name' (VMID: $vmid)..."
    pve_ssh "qm suspend $vmid"
}

# Resume a VM
backend_resume() {
    local name="$1"
    _pve_validate
    local vmid
    vmid=$(pve_get_vmid "$name")
    echo "Resuming VM '$name' (VMID: $vmid)..."
    pve_ssh "qm resume $vmid" || true
}

# Check if a VM is running
backend_is_running() {
    local name="$1"
    _pve_validate
    local vmid
    vmid=$(pve_get_vmid "$name")
    local status
    status=$(pve_ssh "qm status $vmid" 2>/dev/null || echo "")
    echo "$status" | grep -q "running"
}

# --- Info Functions ---

# Show VM status
backend_status() {
    local name="$1"
    _pve_validate
    local vmid
    vmid=$(pve_get_vmid "$name")
    pve_ssh "qm status $vmid --verbose"
    echo ""
    echo "IP Address(es):"
    backend_get_ip "$name" || echo "  (not available - VM may not be running or guest agent not responding)"
}

# List all VMs on Proxmox node
backend_list() {
    _pve_validate
    pve_ssh "qm list"
}

# Get IP address for a VM (via QEMU guest agent)
backend_get_ip() {
    local name="$1"
    _pve_validate
    local vmid
    vmid=$(pve_get_vmid "$name")

    local interfaces
    interfaces=$(pve_ssh "qm guest cmd $vmid network-get-interfaces" 2>/dev/null || echo "")

    if [ -z "$interfaces" ]; then
        return 1
    fi

    # Parse IPv4 address (skip loopback)
    echo "$interfaces" | jq -r '
        [.[] | select(.name != "lo") | .["ip-addresses"][]? |
         select(.["ip-address-type"] == "ipv4")] |
        first | .["ip-address"] // empty
    ' 2>/dev/null || return 1
}

# Show VM console
backend_console() {
    local name="$1"
    _pve_validate
    local vmid
    vmid=$(pve_get_vmid "$name")
    echo "Connecting to console for VM '$name' (VMID: $vmid)..."
    echo "(Use Ctrl+O to exit)"
    pve_ssh -t "qm terminal $vmid"
}

# --- Snapshot Functions ---

# Create a snapshot
backend_snapshot() {
    local name="$1"
    local snapshot_name="$2"
    _pve_validate
    local vmid
    vmid=$(pve_get_vmid "$name")
    echo "Creating snapshot '$snapshot_name' for VM '$name' (VMID: $vmid)..."
    pve_ssh "qm snapshot $vmid $snapshot_name"
    echo "Snapshot '$snapshot_name' created."
}

# Restore a snapshot
backend_restore_snapshot() {
    local name="$1"
    local snapshot_name="$2"
    _pve_validate
    local vmid
    vmid=$(pve_get_vmid "$name")
    echo "Restoring VM '$name' to snapshot '$snapshot_name'..."
    pve_ssh "qm rollback $vmid $snapshot_name"
    echo "VM '$name' restored to '$snapshot_name'."
}

# List snapshots for a VM
backend_list_snapshots() {
    local name="$1"
    _pve_validate
    local vmid
    vmid=$(pve_get_vmid "$name")
    pve_ssh "qm listsnapshot $vmid"
}

# Get snapshot count for a VM
backend_snapshot_count() {
    local name="$1"
    _pve_validate
    local vmid
    vmid=$(pve_get_vmid "$name")
    # qm listsnapshot includes a "current" entry; subtract it
    local count
    count=$(pve_ssh "qm listsnapshot $vmid" 2>/dev/null | grep -cv '^\s*`->.*current' || true)
    # Subtract the "current" line if present
    local current_lines
    current_lines=$(pve_ssh "qm listsnapshot $vmid" 2>/dev/null | grep -c 'current' || true)
    echo $(( count - current_lines ))
}

# --- Cleanup ---

# Remove local backend artifacts for a VM
backend_cleanup() {
    local name="$1"
    rm -f "$OUTPUT_DIR/vms/$name/boot-flat.qcow2"
}

# --- Composite Operations ---

# Create a new VM: build profile, create machine config, create disks, configure
create_vm() {
    local name="$1"
    local profile="${2:-core}"
    local memory="${3:-2048}"
    local vcpus="${4:-2}"
    local var_size="${5:-20G}"
    local network="${6:-nat}"

    build_profile "$profile"
    init_machine "$name" "$profile" "$network"

    # Save memory/vcpus to machine config
    echo "$memory" > "$MACHINES_DIR/$name/memory"
    echo "$vcpus" > "$MACHINES_DIR/$name/vcpus"

    backend_create_disks "$name" "$var_size"

    echo ""
    echo "VM '$name' is ready on Proxmox (VMID: $(pve_get_vmid "$name"), profile: $profile)."
    echo "Start with: BACKEND=proxmox just start $name"
    echo "Machine config: $MACHINES_DIR/$name/"
    echo "SSH as admin (sudo): ssh admin@<ip>"
    echo "SSH as user (no sudo): ssh user@<ip>"
}

# Clone a VM: copy /var disk from source, generate fresh identity
clone_vm() {
    local source="$1"
    local dest="$2"
    local memory="${3:-2048}"
    local vcpus="${4:-2}"
    local network="${5:-}"

    local source_machine_dir="$MACHINES_DIR/$source"
    local dest_machine_dir="$MACHINES_DIR/$dest"

    _pve_validate

    # Validate source machine config exists
    if [ ! -d "$source_machine_dir" ]; then
        echo "Error: Source machine config not found: $source_machine_dir"
        exit 1
    fi

    # Validate source has a VMID
    local source_vmid
    source_vmid=$(pve_get_vmid "$source")

    # Validate source VM is shut off
    if backend_is_running "$source"; then
        echo "Error: Source VM '$source' must be stopped before cloning."
        echo "Run 'BACKEND=proxmox just stop $source' first."
        exit 1
    fi

    # Validate dest doesn't already exist
    if [ -d "$dest_machine_dir" ]; then
        echo "Error: Destination machine config already exists: $dest_machine_dir"
        exit 1
    fi

    echo "Cloning VM '$source' -> '$dest'"

    # Initialize machine config (non-interactive)
    init_machine_clone "$source" "$dest" "$network"

    # Save memory/vcpus
    echo "$memory" > "$dest_machine_dir/memory"
    echo "$vcpus" > "$dest_machine_dir/vcpus"

    # Allocate VMID for clone
    local dest_vmid
    dest_vmid=$(pve_next_vmid)
    echo "$dest_vmid" > "$dest_machine_dir/vmid"
    echo "Allocated VMID for clone: $dest_vmid"

    # Use qm clone for full clone
    echo "Cloning VM on Proxmox ($source_vmid -> $dest_vmid)..."
    pve_ssh "qm clone $source_vmid $dest_vmid --full 1 --name $dest --storage $PVE_STORAGE"

    # Update network config if different
    local network_config bridge mac_address
    network_config=$(cat "$dest_machine_dir/network" 2>/dev/null || echo "nat")
    if [[ "$network_config" == bridge:* ]]; then
        bridge="${network_config#bridge:}"
    else
        bridge="$PVE_BRIDGE"
    fi
    mac_address=$(cat "$dest_machine_dir/mac-address")
    pve_ssh "qm set $dest_vmid --net0 virtio=$mac_address,bridge=$bridge,firewall=1"

    # Update memory/vcpus
    pve_ssh "qm set $dest_vmid --memory $memory --cores $vcpus"

    # Sync fresh identity onto cloned var disk
    backend_sync_identity "$dest"

    echo ""
    echo "VM '$dest' cloned from '$source' (VMID: $dest_vmid)."
    echo "Start with: BACKEND=proxmox just start $dest"
}

# Destroy a VM: force stop, undefine, remove disks (keeps machine config)
destroy_vm() {
    local name="$1"

    echo "WARNING: This will destroy VM '$name' and delete all its disks on Proxmox."
    echo "All data in /var and home directories will be PERMANENTLY LOST."
    echo "(Machine config in $MACHINES_DIR/$name/ will be preserved)"
    read -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi

    echo "Destroying VM: $name"
    backend_force_stop "$name"
    backend_undefine "$name"
    rm -rf "$OUTPUT_DIR/vms/$name"
    backend_cleanup "$name"
    echo "VM '$name' has been removed from Proxmox."
    echo "Machine config preserved: $MACHINES_DIR/$name/"
    echo "To also remove config: just purge $name"
}

# Completely remove a VM including its machine config
purge_vm() {
    local name="$1"

    echo "WARNING: This will COMPLETELY remove VM '$name'."
    echo "All data in /var and home directories will be PERMANENTLY LOST."
    echo "Machine config (SSH keys, identity) will also be deleted."
    read -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi

    echo "Purging VM: $name"
    backend_force_stop "$name"
    backend_undefine "$name"
    rm -rf "$OUTPUT_DIR/vms/$name"
    backend_cleanup "$name"
    rm -rf "$MACHINES_DIR/$name"
    echo "VM '$name' completely removed."
}

# Recreate a VM from its existing machine config
recreate_vm() {
    local name="$1"
    local var_size="${2:-20G}"
    local network="${3:-}"

    local machine_dir="$MACHINES_DIR/$name"
    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        echo "Use 'BACKEND=proxmox just create $name' for new VMs"
        exit 1
    fi
    local profile
    profile=$(cat "$machine_dir/profile")

    # Update network config if specified
    if [ -n "$network" ]; then
        network_config "$name" "$network"
    fi
    local current_network
    current_network=$(cat "$machine_dir/network" 2>/dev/null || echo "nat")

    echo "WARNING: This will recreate VM '$name' with a fresh start."
    echo "All data in /var and home directories will be PERMANENTLY LOST."
    echo "(Machine config in $MACHINES_DIR/$name/ will be preserved)"
    echo "Profile: $profile"
    echo "Network: $current_network"
    read -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi
    echo "Recreating VM '$name' with profile: $profile"

    # Destroy existing VM on Proxmox if it has a VMID
    if [ -f "$machine_dir/vmid" ]; then
        backend_force_stop "$name"
        backend_undefine "$name"
    fi

    build_profile "$profile"
    rm -rf "$OUTPUT_DIR/vms/$name"
    backend_create_disks "$name" "$var_size"
    backend_start "$name"

    echo ""
    echo "VM '$name' recreated and started."
    echo "SSH as admin (sudo): ssh admin@<ip>"
    echo "SSH as user (no sudo): ssh user@<ip>"
}

# Upgrade a VM to a new image (preserves /var data)
upgrade_vm() {
    local name="$1"
    local machine_dir="$MACHINES_DIR/$name"

    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        echo "Use 'BACKEND=proxmox just create $name' for new VMs"
        exit 1
    fi

    _pve_validate

    local profile vmid
    profile=$(cat "$machine_dir/profile")
    vmid=$(pve_get_vmid "$name")

    # Check for existing snapshots
    local snapshot_count
    snapshot_count=$(backend_snapshot_count "$name")
    if [ "$snapshot_count" -gt 0 ]; then
        echo "WARNING: VM '$name' has $snapshot_count snapshot(s) that will be DELETED:"
        backend_list_snapshots "$name" | sed 's/^/  /'
        echo ""
        read -p "Continue with upgrade and delete snapshots? [y/N] " confirm
        if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
            echo "Aborted."
            exit 1
        fi
        # Delete all snapshots
        pve_ssh "qm listsnapshot $vmid" 2>/dev/null | \
            grep -v 'current' | awk '{print $2}' | grep -v '^$' | \
            while read -r snap; do
                echo "Deleting snapshot: $snap"
                pve_ssh "qm delsnapshot $vmid $snap" || true
            done
    fi

    echo "Upgrading VM '$name' to latest $profile image (preserving /var data)"

    # Stop VM
    backend_force_stop "$name"
    # Wait for stop
    local wait_count=0
    while backend_is_running "$name" && [ $wait_count -lt 30 ]; do
        sleep 1
        wait_count=$((wait_count + 1))
    done

    # Build new profile image
    build_profile "$profile"

    # Sync identity files
    backend_sync_identity "$name"

    # Flatten new boot disk
    local profile_image
    profile_image=$($READLINK -f "$OUTPUT_DIR/profiles/$profile")/nixos.qcow2
    mkdir -p "$OUTPUT_DIR/vms/$name"

    echo "Flattening new boot disk..."
    $QEMU_IMG convert -f qcow2 -O qcow2 \
        "$profile_image" \
        "$OUTPUT_DIR/vms/$name/boot-flat.qcow2"

    # Create staging directory and transfer new boot disk
    pve_ssh "mkdir -p $PVE_STAGING_DIR/$name"
    echo "Transferring new boot disk to Proxmox..."
    pve_rsync "$OUTPUT_DIR/vms/$name/boot-flat.qcow2" \
        "${PVE_SSH_USER}@${PVE_HOST}:${PVE_STAGING_DIR}/$name/boot.qcow2"

    # Detach old boot disk
    pve_ssh "qm set $vmid --delete virtio0" || true

    # Find and remove old boot disk from storage
    local old_disk
    old_disk=$(pve_ssh "qm config $vmid" 2>/dev/null | grep "^unused" | head -1 | sed 's/^unused[0-9]*: //' || true)
    if [ -n "$old_disk" ]; then
        pve_ssh "pvesh delete /nodes/$PVE_NODE/storage/$PVE_STORAGE/content/$old_disk" 2>/dev/null || true
    fi

    # Import new boot disk
    echo "Importing new boot disk..."
    pve_ssh "qm importdisk $vmid ${PVE_STAGING_DIR}/$name/boot.qcow2 $PVE_STORAGE"

    # Find the new unused disk and attach it
    local new_disk
    new_disk=$(pve_ssh "qm config $vmid" | grep "^unused" | tail -1 | sed 's/^unused[0-9]*: //')
    if [ -n "$new_disk" ]; then
        pve_ssh "qm set $vmid --virtio0 $new_disk --boot order=virtio0"
    fi

    # Cleanup
    pve_ssh "rm -rf ${PVE_STAGING_DIR}/$name"
    rm -f "$OUTPUT_DIR/vms/$name/boot-flat.qcow2"

    # Start VM
    backend_start "$name"

    echo ""
    echo "VM '$name' upgraded and started. /var data preserved."
    echo "SSH as admin (sudo): ssh admin@<ip>"
    echo "SSH as user (no sudo): ssh user@<ip>"
}

# Backup a VM using vzdump
backup_vm() {
    local name="$1"
    _pve_validate
    local vmid
    vmid=$(pve_get_vmid "$name")

    echo "Creating backup of VM '$name' (VMID: $vmid) via vzdump..."
    pve_ssh "vzdump $vmid --mode snapshot --compress zstd --storage $PVE_STORAGE"
    echo ""
    echo "Backup complete. List backups with: BACKEND=proxmox just backups"
}

# Restore a VM from backup
restore_backup_vm() {
    local name="$1"
    local backup_file="${2:-}"
    _pve_validate

    local machine_dir="$MACHINES_DIR/$name"
    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        echo "The VM must be created first with 'BACKEND=proxmox just create $name'"
        exit 1
    fi

    local vmid
    vmid=$(pve_get_vmid "$name")

    # If no backup file specified, list available backups
    if [ -z "$backup_file" ]; then
        echo "Available backups on Proxmox for VMID $vmid:"
        local backups
        backups=$(pve_ssh "pvesh get /nodes/$PVE_NODE/storage/$PVE_STORAGE/content --content backup --vmid $vmid --output-format json" 2>/dev/null || echo "[]")

        if [ "$backups" = "[]" ] || [ -z "$backups" ]; then
            echo "  No backups found."
            exit 1
        fi

        echo "$backups" | jq -r '.[] | "  \(.volid) (\(.size | . / 1048576 | floor)MB, \(.ctime | todate))"'
        echo ""
        echo "Specify backup file to restore:"
        echo "  BACKEND=proxmox just restore-backup $name <volid>"
        exit 0
    fi

    echo "WARNING: This will replace VM '$name' with backup contents."
    echo "All current data will be LOST."
    echo "Backup: $backup_file"
    read -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi

    # Stop VM if running
    backend_force_stop "$name"

    # Destroy existing VM
    pve_ssh "qm destroy $vmid --destroy-unreferenced-disks 1 --purge 1" || true

    # Restore from backup
    echo "Restoring VM from backup..."
    pve_ssh "qmrestore $backup_file $vmid --storage $PVE_STORAGE"

    echo ""
    echo "Restore complete. Start VM with: BACKEND=proxmox just start $name"
}

# SSH into a VM
ssh_vm() {
    local input="$1"
    local ssh_user="user"
    local name="$input"
    if [[ "$input" == *@* ]]; then
        ssh_user="${input%%@*}"
        name="${input#*@}"
    fi
    local ip
    ip=$(backend_get_ip "$name")
    if [ -z "$ip" ]; then
        echo "Error: Could not determine IP address for VM '$name'"
        echo "Is the VM running? Check with: BACKEND=proxmox just status $name"
        echo "Is the QEMU guest agent responding? It may need a moment after boot."
        exit 1
    fi
    echo "Connecting to $name at $ip as $ssh_user..."
    $SSH -o StrictHostKeyChecking=accept-new "$ssh_user"@"$ip"
}
