#!/usr/bin/env bash
# Libvirt/QEMU backend for NixOS VM Template
# Sourced by Justfile recipes - do not execute directly.

set -euo pipefail

# Source common functions
BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BACKEND_DIR/common.sh"

# Backend-specific environment defaults
VIRSH="${VIRSH:-${HOST_CMD:+$HOST_CMD }${SUDO:+$SUDO }virsh}"
QEMU_IMG="${QEMU_IMG:-${HOST_CMD:+$HOST_CMD }qemu-img}"
GUESTFISH="${GUESTFISH:-${HOST_CMD:+$HOST_CMD }guestfish}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
LIBVIRT_DIR="${LIBVIRT_DIR:-libvirt}"
export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"

# Auto-detect OVMF firmware paths
_detect_ovmf_code() {
    for f in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd; do
        [ -f "$f" ] && echo "$f" && return
    done
}
_detect_ovmf_vars() {
    for f in /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd; do
        [ -f "$f" ] && echo "$f" && return
    done
}
OVMF_CODE="${OVMF_CODE:-$(_detect_ovmf_code)}"
OVMF_VARS="${OVMF_VARS:-$(_detect_ovmf_vars)}"

# --- Connection Test ---

# Test connection to libvirt
test_connection() {
    echo "Testing libvirt connection ($LIBVIRT_URI)..."
    echo ""

    # Test virsh connectivity
    if ! $VIRSH -c "$LIBVIRT_URI" version >/dev/null 2>&1; then
        echo "Libvirt connection FAILED."
        echo ""
        echo "Troubleshooting:"
        echo "  1. Ensure libvirtd is running: sudo systemctl start libvirtd"
        echo "  2. Check your user is in the libvirt group: groups \$USER"
        echo "  3. Try: virsh -c $LIBVIRT_URI version"
        exit 1
    fi

    echo "Libvirt connection: OK"
    $VIRSH -c "$LIBVIRT_URI" version
    echo ""

    # Check OVMF firmware
    if [ -n "$OVMF_CODE" ] && [ -f "$OVMF_CODE" ]; then
        echo "OVMF firmware: OK ($OVMF_CODE)"
    else
        echo "Warning: OVMF firmware not found."
        echo "UEFI VMs may not work. Install edk2-ovmf (Fedora) or ovmf (Debian/Ubuntu)."
    fi

    # Check qemu-img
    if $QEMU_IMG --version >/dev/null 2>&1; then
        echo "qemu-img: OK"
    else
        echo "Warning: qemu-img not found."
    fi

    # Check guestfish
    if $GUESTFISH --version >/dev/null 2>&1; then
        echo "guestfish: OK"
    else
        echo "Warning: guestfish not found. Install guestfs-tools."
    fi

    echo ""
    echo "Connection test passed."
}

# --- Backend primitives ---

# Create VM disks and copy identity from machine config
backend_create_disks() {
    local name="$1"
    local var_size
    var_size=$(normalize_size "${2:-30G}")
    local machine_dir="$MACHINES_DIR/$name"

    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        echo "Run 'just create $name' first"
        exit 1
    fi

    local profile
    profile=$(cat "$machine_dir/profile")

    # Check if this is a mutable VM
    if is_mutable "$name"; then
        backend_create_disks_mutable "$name" "$var_size"
        return
    fi

    echo "Creating VM disks: $name (profile: $profile, immutable)"
    mkdir -p "$OUTPUT_DIR/vms/$name"

    local profile_image
    profile_image=$($READLINK -f "$OUTPUT_DIR/profiles/$profile")/nixos.qcow2

    if [ ! -f "$profile_image" ]; then
        echo "Error: Profile image not found: $profile_image"
        echo "Run 'just build $profile' first"
        exit 1
    fi

    # Create boot disk with backing file
    $QEMU_IMG create -f qcow2 \
        -b "$profile_image" \
        -F qcow2 \
        "$OUTPUT_DIR/vms/$name/boot.qcow2"

    # Create /var disk
    $QEMU_IMG create -f qcow2 "$OUTPUT_DIR/vms/$name/var.qcow2" "$var_size"

    # Read identity from machine config
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

    # Copy hosts file if present
    if [ -s "$machine_dir/hosts" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/hosts /identity/"
        gf_cmds="$gf_cmds : chmod 0644 /identity/hosts"
        gf_cmds="$gf_cmds : chown 0 0 /identity/hosts"
    fi

    # Copy root password hash (empty = no password)
    gf_cmds="$gf_cmds : copy-in $machine_dir/root_password_hash /identity/"
    gf_cmds="$gf_cmds : chmod 0600 /identity/root_password_hash"
    gf_cmds="$gf_cmds : chown 0 0 /identity/root_password_hash"

    # Initialize /var disk
    echo "Initializing /var disk with identity from $machine_dir/"
    eval "$GUESTFISH -a $OUTPUT_DIR/vms/$name/var.qcow2 $gf_cmds"

    echo "Created VM disks in $OUTPUT_DIR/vms/$name/"
    echo "  boot.qcow2 (backing: $profile_image)"
    echo "  var.qcow2 ($var_size, ext4)"
    echo "  Identity: hostname=$hostname"
}

# Create VM disk for mutable mode (single read-write disk, full copy)
backend_create_disks_mutable() {
    local name="$1"
    local disk_size
    disk_size=$(normalize_size "${2:-30G}")
    local machine_dir="$MACHINES_DIR/$name"

    local profile
    profile=$(cat "$machine_dir/profile")

    echo "Creating VM disk: $name (profile: $profile, mutable)"
    mkdir -p "$OUTPUT_DIR/vms/$name"

    # Use mutable image variant
    local profile_image
    profile_image=$($READLINK -f "$OUTPUT_DIR/profiles/${profile}-mutable")/nixos.qcow2

    if [ ! -f "$profile_image" ]; then
        echo "Error: Mutable profile image not found: $profile_image"
        echo "Run 'just build $profile' first (mutable image will be built automatically)"
        exit 1
    fi

    # Copy the image (not backing file - this is a standalone mutable system)
    echo "Copying base image (this may take a moment)..."
    $CP "$profile_image" "$OUTPUT_DIR/vms/$name/disk.qcow2"
    chmod 644 "$OUTPUT_DIR/vms/$name/disk.qcow2"

    # Resize to requested size
    echo "Resizing disk to $disk_size..."
    $QEMU_IMG resize "$OUTPUT_DIR/vms/$name/disk.qcow2" "$disk_size"

    # Set hostname and machine-id inside the image
    local hostname machine_id
    hostname=$(cat "$machine_dir/hostname")
    machine_id=$(cat "$machine_dir/machine-id")

    echo "Setting hostname and machine-id..."
    $GUESTFISH -a "$OUTPUT_DIR/vms/$name/disk.qcow2" <<EOF
run
mount /dev/disk/by-label/nixos /
write /etc/hostname "$hostname"
write /etc/machine-id "$machine_id"
EOF

    echo "Created VM disk in $OUTPUT_DIR/vms/$name/"
    echo "  disk.qcow2 ($disk_size, standalone mutable)"
    echo "  Hostname: $hostname"
    echo ""
    echo "NOTE: This is a mutable VM. Upgrades must be done inside the VM with:"
    echo "  sudo nixos-rebuild switch --flake <your-flake>#<config>"
}

# Sync identity files from machine config to existing /var disk
backend_sync_identity() {
    local name="$1"
    local machine_dir="$MACHINES_DIR/$name"
    local var_disk="$OUTPUT_DIR/vms/$name/var.qcow2"

    if [ ! -f "$var_disk" ]; then
        echo "Error: /var disk not found: $var_disk"
        exit 1
    fi

    echo "Syncing identity files from $machine_dir/ to /var disk"

    local gf_cmds="run : mount /dev/sda1 /"

    local hostname machine_id
    hostname=$(cat "$machine_dir/hostname")
    machine_id=$(cat "$machine_dir/machine-id")
    gf_cmds="$gf_cmds : write /identity/hostname '$hostname'"
    gf_cmds="$gf_cmds : write /identity/machine-id '$machine_id'"

    # Update authorized_keys files
    if [ -s "$machine_dir/admin_authorized_keys" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/admin_authorized_keys /identity/"
        gf_cmds="$gf_cmds : chmod 0644 /identity/admin_authorized_keys"
        gf_cmds="$gf_cmds : chown 0 0 /identity/admin_authorized_keys"
    fi

    if [ -s "$machine_dir/user_authorized_keys" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/user_authorized_keys /identity/"
        gf_cmds="$gf_cmds : chmod 0644 /identity/user_authorized_keys"
        gf_cmds="$gf_cmds : chown 0 0 /identity/user_authorized_keys"
    fi

    # Update TCP ports file
    if [ -s "$machine_dir/tcp_ports" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/tcp_ports /identity/"
        gf_cmds="$gf_cmds : chmod 0644 /identity/tcp_ports"
        gf_cmds="$gf_cmds : chown 0 0 /identity/tcp_ports"
    fi

    # Update UDP ports file
    if [ -s "$machine_dir/udp_ports" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/udp_ports /identity/"
        gf_cmds="$gf_cmds : chmod 0644 /identity/udp_ports"
        gf_cmds="$gf_cmds : chown 0 0 /identity/udp_ports"
    fi

    # Update resolv.conf
    if [ -s "$machine_dir/resolv.conf" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/resolv.conf /identity/"
        gf_cmds="$gf_cmds : chmod 0644 /identity/resolv.conf"
        gf_cmds="$gf_cmds : chown 0 0 /identity/resolv.conf"
    fi

    # Update hosts file
    if [ -s "$machine_dir/hosts" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/hosts /identity/"
        gf_cmds="$gf_cmds : chmod 0644 /identity/hosts"
        gf_cmds="$gf_cmds : chown 0 0 /identity/hosts"
    fi

    # Update root password hash
    if [ -f "$machine_dir/root_password_hash" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/root_password_hash /identity/"
        gf_cmds="$gf_cmds : chmod 0600 /identity/root_password_hash"
        gf_cmds="$gf_cmds : chown 0 0 /identity/root_password_hash"
    fi

    eval "$GUESTFISH -a $var_disk $gf_cmds"
    echo "Identity files synced."
}

# Generate libvirt XML for a VM
backend_generate_config() {
    local name="$1"
    local memory="${2:-}"
    local vcpus="${3:-}"

    # Read from machine config if not provided
    local machine_dir="$MACHINES_DIR/$name"
    if [ -z "$memory" ]; then
        memory=$(cat "$machine_dir/memory" 2>/dev/null || echo "2048")
    fi
    if [ -z "$vcpus" ]; then
        vcpus=$(cat "$machine_dir/vcpus" 2>/dev/null || echo "2")
    fi

    # Save memory/vcpus to machine config for future reference
    echo "$memory" > "$machine_dir/memory"
    echo "$vcpus" > "$machine_dir/vcpus"

    echo "Generating libvirt XML for: $name"
    mkdir -p "$LIBVIRT_DIR"

    local ovmf_vars_dest mac_address vm_uuid
    ovmf_vars_dest=$($READLINK -f "$OUTPUT_DIR/vms/$name")/OVMF_VARS.qcow2
    mac_address=$(cat "$MACHINES_DIR/$name/mac-address")

    # Generate UUID if not present
    if [ ! -f "$MACHINES_DIR/$name/uuid" ]; then
        cat /proc/sys/kernel/random/uuid > "$MACHINES_DIR/$name/uuid"
        echo "Generated: $MACHINES_DIR/$name/uuid"
    fi
    vm_uuid=$(cat "$MACHINES_DIR/$name/uuid")

    # Parse network configuration
    local network_config network_type network_source
    network_config=$(cat "$MACHINES_DIR/$name/network" 2>/dev/null || echo "nat")
    if [[ "$network_config" == "nat" ]]; then
        network_type="network"
        network_source="network='default'"
    elif [[ "$network_config" == bridge:* ]]; then
        local bridge_name="${network_config#bridge:}"
        network_type="bridge"
        network_source="bridge='$bridge_name'"
    else
        echo "Error: Invalid network config '$network_config'"
        exit 1
    fi

    # Convert NVRAM template to QCOW2 (required for snapshots with UEFI)
    $QEMU_IMG convert -f raw -O qcow2 "$OVMF_VARS" "$ovmf_vars_dest" 2>/dev/null || \
        echo "Warning: Could not convert OVMF_VARS to QCOW2 from $OVMF_VARS"

    local owner_uid owner_gid
    owner_uid=$(id -u)
    owner_gid=$(id -g)

    # Choose template based on mutable mode
    if is_mutable "$name"; then
        local disk
        disk=$($READLINK -f "$OUTPUT_DIR/vms/$name/disk.qcow2")

        sed -e "s|@@VM_NAME@@|$name|g" \
            -e "s|@@UUID@@|$vm_uuid|g" \
            -e "s|@@MEMORY@@|$memory|g" \
            -e "s|@@VCPUS@@|$vcpus|g" \
            -e "s|@@DISK@@|$disk|g" \
            -e "s|@@OVMF_CODE@@|$OVMF_CODE|g" \
            -e "s|@@OVMF_VARS@@|$ovmf_vars_dest|g" \
            -e "s|@@MAC_ADDRESS@@|$mac_address|g" \
            -e "s|@@NETWORK_TYPE@@|$network_type|g" \
            -e "s|@@NETWORK_SOURCE@@|$network_source|g" \
            -e "s|@@OWNER_UID@@|$owner_uid|g" \
            -e "s|@@OWNER_GID@@|$owner_gid|g" \
            "$LIBVIRT_DIR/template-mutable.xml" > "$LIBVIRT_DIR/$name.xml"
    else
        local boot_disk var_disk
        boot_disk=$($READLINK -f "$OUTPUT_DIR/vms/$name/boot.qcow2")
        var_disk=$($READLINK -f "$OUTPUT_DIR/vms/$name/var.qcow2")

        sed -e "s|@@VM_NAME@@|$name|g" \
            -e "s|@@UUID@@|$vm_uuid|g" \
            -e "s|@@MEMORY@@|$memory|g" \
            -e "s|@@VCPUS@@|$vcpus|g" \
            -e "s|@@BOOT_DISK@@|$boot_disk|g" \
            -e "s|@@VAR_DISK@@|$var_disk|g" \
            -e "s|@@OVMF_CODE@@|$OVMF_CODE|g" \
            -e "s|@@OVMF_VARS@@|$ovmf_vars_dest|g" \
            -e "s|@@MAC_ADDRESS@@|$mac_address|g" \
            -e "s|@@NETWORK_TYPE@@|$network_type|g" \
            -e "s|@@NETWORK_SOURCE@@|$network_source|g" \
            -e "s|@@OWNER_UID@@|$owner_uid|g" \
            -e "s|@@OWNER_GID@@|$owner_gid|g" \
            "$LIBVIRT_DIR/template.xml" > "$LIBVIRT_DIR/$name.xml"
    fi

    echo "Generated: $LIBVIRT_DIR/$name.xml"
}

# Define a VM in libvirt
backend_define() {
    local name="$1"
    echo "Defining VM in libvirt: $name"
    $VIRSH -c "$LIBVIRT_URI" define "$LIBVIRT_DIR/$name.xml"
    echo "VM defined. Start with: just start $name"
}

# Undefine a VM from libvirt (also removes snapshot metadata)
backend_undefine() {
    local name="$1"
    echo "Undefining VM from libvirt: $name"
    $VIRSH -c "$LIBVIRT_URI" undefine "$name" --nvram --snapshots-metadata || \
        $VIRSH -c "$LIBVIRT_URI" undefine "$name" --snapshots-metadata || \
        $VIRSH -c "$LIBVIRT_URI" undefine "$name"
}

# Start a VM
backend_start() {
    local name="$1"

    # Read the VM's network config
    local network_config
    network_config=$(cat "$MACHINES_DIR/$name/network" 2>/dev/null || echo "nat")
    if [[ "$network_config" == "nat" ]]; then
        # Ensure the default NAT network is defined and active
        if ! $VIRSH -c "$LIBVIRT_URI" net-info default &>/dev/null; then
            echo "Defining default NAT network..."
            cat > /tmp/libvirt-default-net.xml <<'NETXML'
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
NETXML
            $VIRSH -c "$LIBVIRT_URI" net-define /tmp/libvirt-default-net.xml
            rm -f /tmp/libvirt-default-net.xml
        fi
        $VIRSH -c "$LIBVIRT_URI" net-start default 2>/dev/null || true
        $VIRSH -c "$LIBVIRT_URI" net-autostart default 2>/dev/null || true
    fi
    echo "Starting VM: $name"
    $VIRSH -c "$LIBVIRT_URI" start "$name"
}

# Stop a VM (graceful shutdown)
backend_stop() {
    local name="$1"
    echo "Stopping VM: $name"
    $VIRSH -c "$LIBVIRT_URI" shutdown "$name"
}

# Force stop a VM
backend_force_stop() {
    local name="$1"
    echo "Force stopping VM: $name"
    $VIRSH -c "$LIBVIRT_URI" destroy "$name" 2>/dev/null || true
}

# Show VM status
backend_status() {
    local name="$1"
    $VIRSH -c "$LIBVIRT_URI" dominfo "$name"
    echo ""
    echo "IP Address(es):"
    $VIRSH -c "$LIBVIRT_URI" domifaddr "$name" 2>/dev/null || echo "  (not available - VM may not be running or guest agent not installed)"
}

# List all VMs
backend_list() {
    $VIRSH -c "$LIBVIRT_URI" list --all
}

# Show VM console
backend_console() {
    local name="$1"
    $VIRSH -c "$LIBVIRT_URI" console "$name"
}

# Get IP address for a VM
backend_get_ip() {
    local name="$1"
    $VIRSH -c "$LIBVIRT_URI" domifaddr "$name" 2>/dev/null | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}'
}

# Create a snapshot
backend_snapshot() {
    local name="$1"
    local snapshot_name="$2"
    echo "Creating snapshot '$snapshot_name' for VM '$name'..."
    $VIRSH -c "$LIBVIRT_URI" snapshot-create-as "$name" "$snapshot_name"
    echo "Snapshot '$snapshot_name' created."
}

# Restore a snapshot
backend_restore_snapshot() {
    local name="$1"
    local snapshot_name="$2"
    echo "Restoring VM '$name' to snapshot '$snapshot_name'..."
    $VIRSH -c "$LIBVIRT_URI" snapshot-revert "$name" "$snapshot_name"
    echo "VM '$name' restored to '$snapshot_name'."
}

# List snapshots for a VM
backend_list_snapshots() {
    local name="$1"
    $VIRSH -c "$LIBVIRT_URI" snapshot-list "$name"
}

# Get snapshot count for a VM
backend_snapshot_count() {
    local name="$1"
    $VIRSH -c "$LIBVIRT_URI" snapshot-list "$name" --name 2>/dev/null | grep -c . || true
}

# Suspend a VM
backend_suspend() {
    local name="$1"
    echo "Suspending VM '$name'..."
    $VIRSH -c "$LIBVIRT_URI" suspend "$name"
}

# Resume a VM
backend_resume() {
    local name="$1"
    echo "Resuming VM '$name'..."
    $VIRSH -c "$LIBVIRT_URI" resume "$name" || true
}

# Check if a VM is running
backend_is_running() {
    local name="$1"
    $VIRSH -c "$LIBVIRT_URI" domstate "$name" 2>/dev/null | grep -q "running"
}

# Remove backend artifacts (XML) for a VM
backend_cleanup() {
    local name="$1"
    rm -f "$LIBVIRT_DIR/$name.xml"
}

# --- Composite operations ---

# Create a new VM: build profile, create machine config, create disks, generate XML, define
create_vm() {
    local name="$1"
    local profile="${2:-core}"
    local memory="${3:-2048}"
    local vcpus="${4:-2}"
    local var_size
    var_size=$(normalize_size "${5:-30G}")
    local network="${6:-nat}"

    # Initialize machine config first (so we can check mutable status)
    init_machine "$name" "$profile" "$network"

    # Build appropriate image variant
    if is_mutable "$name"; then
        build_profile "$profile" "true"
    else
        build_profile "$profile" "false"
    fi

    backend_create_disks "$name" "$var_size"
    backend_generate_config "$name" "$memory" "$vcpus"
    backend_define "$name"

    echo ""
    if is_mutable "$name"; then
        echo "VM '$name' is ready (profile: $profile, mutable). Start with: just start $name"
        echo "Machine config: $MACHINES_DIR/$name/"
        echo "SSH as admin (sudo): ssh admin@<ip>"
        echo "SSH as user (no sudo): ssh user@<ip>"
        echo ""
        echo "NOTE: This is a mutable VM with full nix toolchain."
        echo "Upgrades must be done inside the VM with nixos-rebuild."
    else
        echo "VM '$name' is ready (profile: $profile). Start with: just start $name"
        echo "Machine config: $MACHINES_DIR/$name/"
        echo "SSH as admin (sudo): ssh admin@<ip>"
        echo "SSH as user (no sudo): ssh user@<ip>"
    fi
}

# Clone a VM: copy disk(s) from source, generate fresh identity
clone_vm() {
    local source="$1"
    local dest="$2"
    local memory="${3:-}"
    local vcpus="${4:-}"
    local network="${5:-}"

    local source_machine_dir="$MACHINES_DIR/$source"
    local dest_machine_dir="$MACHINES_DIR/$dest"
    local source_vm_dir="$OUTPUT_DIR/vms/$source"
    local dest_vm_dir="$OUTPUT_DIR/vms/$dest"

    # Validate source machine config exists
    if [ ! -d "$source_machine_dir" ]; then
        echo "Error: Source machine config not found: $source_machine_dir"
        exit 1
    fi

    # Default memory/vcpus from source machine config
    if [ -z "$memory" ]; then
        memory=$(cat "$source_machine_dir/memory" 2>/dev/null || echo "2048")
    fi
    if [ -z "$vcpus" ]; then
        vcpus=$(cat "$source_machine_dir/vcpus" 2>/dev/null || echo "2")
    fi

    # Check if source is mutable
    local source_mutable=false
    if is_mutable "$source"; then
        source_mutable=true
    fi

    # Validate source disk exists
    if [ "$source_mutable" = true ]; then
        if [ ! -f "$source_vm_dir/disk.qcow2" ]; then
            echo "Error: Source disk not found: $source_vm_dir/disk.qcow2"
            exit 1
        fi
    else
        if [ ! -f "$source_vm_dir/var.qcow2" ]; then
            echo "Error: Source /var disk not found: $source_vm_dir/var.qcow2"
            exit 1
        fi
    fi

    # Validate source VM is shut off
    local state
    state=$($VIRSH -c "$LIBVIRT_URI" domstate "$source" 2>/dev/null || echo "unknown")
    if [ "$state" != "shut off" ] && [ "$state" != "unknown" ]; then
        echo "Error: Source VM '$source' must be shut off (current state: $state)"
        echo "Run 'just stop $source' first."
        exit 1
    fi

    # Validate dest doesn't already exist
    if [ -d "$dest_machine_dir" ]; then
        echo "Error: Destination machine config already exists: $dest_machine_dir"
        exit 1
    fi
    if [ -d "$dest_vm_dir" ]; then
        echo "Error: Destination VM disks already exist: $dest_vm_dir"
        exit 1
    fi

    echo "Cloning VM '$source' -> '$dest'"

    # Initialize machine config (non-interactive, copies mutable flag too)
    init_machine_clone "$source" "$dest" "$network"
    mkdir -p "$dest_vm_dir"

    if [ "$source_mutable" = true ]; then
        # Mutable: copy the single disk
        echo "Copying disk..."
        $CP "$source_vm_dir/disk.qcow2" "$dest_vm_dir/disk.qcow2"

        # Update hostname and machine-id in the cloned disk
        local hostname machine_id
        hostname=$(cat "$dest_machine_dir/hostname")
        machine_id=$(cat "$dest_machine_dir/machine-id")

        echo "Updating identity in cloned disk..."
        $GUESTFISH -a "$dest_vm_dir/disk.qcow2" <<EOF
run
mount /dev/sda2 /
write /etc/hostname "$hostname"
write /etc/machine-id "$machine_id"
EOF
    else
        # Immutable: copy var disk, create new boot disk
        echo "Copying /var disk..."
        $CP "$source_vm_dir/var.qcow2" "$dest_vm_dir/var.qcow2"

        # Sync new identity onto copied var disk
        backend_sync_identity "$dest"

        # Delete SSH host keys so clone generates fresh keys on first boot
        echo "Removing SSH host keys (will be regenerated on first boot)..."
        eval "$GUESTFISH -a $dest_vm_dir/var.qcow2 run : mount /dev/sda1 / : rm-f /identity/ssh_host_ed25519_key : rm-f /identity/ssh_host_ed25519_key.pub"

        # Create boot disk with same profile's base image
        local profile profile_image
        profile=$(cat "$dest_machine_dir/profile")
        profile_image=$($READLINK -f "$OUTPUT_DIR/profiles/$profile")/nixos.qcow2
        if [ ! -f "$profile_image" ]; then
            echo "Error: Profile image not found: $profile_image"
            echo "Run 'just build $profile' first"
            exit 1
        fi
        $QEMU_IMG create -f qcow2 \
            -b "$profile_image" \
            -F qcow2 \
            "$dest_vm_dir/boot.qcow2"
    fi

    # Generate XML and define in libvirt
    backend_generate_config "$dest" "$memory" "$vcpus"
    backend_define "$dest"

    echo ""
    echo "VM '$dest' cloned from '$source'. Start with: just start $dest"
}

# Destroy a VM: force stop, undefine, remove disks (keeps machine config)
destroy_vm() {
    local name="$1"

    if [ ! -d "$MACHINES_DIR/$name" ]; then
        echo "Error: No machine config found for '$name'"
        exit 1
    fi

    echo "WARNING: This will destroy VM '$name' and delete all its disks."
    echo "All data in /var and home directories will be PERMANENTLY LOST."
    echo "(Machine config in $MACHINES_DIR/$name/ will be preserved)"
    read -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi

    echo "Destroying VM: $name"
    backend_force_stop "$name"
    $VIRSH -c "$LIBVIRT_URI" undefine "$name" --nvram --snapshots-metadata 2>/dev/null || \
        $VIRSH -c "$LIBVIRT_URI" undefine "$name" --snapshots-metadata 2>/dev/null || \
        $VIRSH -c "$LIBVIRT_URI" undefine "$name" 2>/dev/null || true
    rm -rf "$OUTPUT_DIR/vms/$name"
    backend_cleanup "$name"
    echo "VM '$name' has been removed."
    echo "Machine config preserved: $MACHINES_DIR/$name/"
    echo "To also remove config: just purge $name"
}

# Completely remove a VM including its machine config
purge_vm() {
    local name="$1"

    if [ ! -d "$MACHINES_DIR/$name" ]; then
        echo "Error: No machine config found for '$name'"
        exit 1
    fi

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
    $VIRSH -c "$LIBVIRT_URI" undefine "$name" --nvram --snapshots-metadata 2>/dev/null || \
        $VIRSH -c "$LIBVIRT_URI" undefine "$name" --snapshots-metadata 2>/dev/null || \
        $VIRSH -c "$LIBVIRT_URI" undefine "$name" 2>/dev/null || true
    rm -rf "$OUTPUT_DIR/vms/$name"
    backend_cleanup "$name"
    rm -rf "$MACHINES_DIR/$name"
    echo "VM '$name' completely removed."
}

# Recreate a VM from its existing machine config
recreate_vm() {
    local name="$1"
    local var_size
    var_size=$(normalize_size "${2:-30G}")
    local network="${3:-}"

    local machine_dir="$MACHINES_DIR/$name"
    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        echo "Use 'just create $name' for new VMs"
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

    backend_force_stop "$name"
    $VIRSH -c "$LIBVIRT_URI" undefine "$name" --nvram --snapshots-metadata 2>/dev/null || \
        $VIRSH -c "$LIBVIRT_URI" undefine "$name" --snapshots-metadata 2>/dev/null || \
        $VIRSH -c "$LIBVIRT_URI" undefine "$name" 2>/dev/null || true

    # Build appropriate image variant
    if is_mutable "$name"; then
        build_profile "$profile" "true"
    else
        build_profile "$profile" "false"
    fi

    rm -rf "$OUTPUT_DIR/vms/$name"
    backend_create_disks "$name" "$var_size"
    backend_generate_config "$name"
    $VIRSH -c "$LIBVIRT_URI" define "$LIBVIRT_DIR/$name.xml"
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
        echo "Use 'just create $name' for new VMs"
        exit 1
    fi

    # Block upgrades for mutable VMs
    if is_mutable "$name"; then
        echo "Error: Cannot upgrade mutable VMs from the host."
        echo ""
        echo "Mutable VMs have a standard read-write NixOS filesystem and must be"
        echo "upgraded from inside the VM using nixos-rebuild:"
        echo ""
        echo "  ssh admin@<vm-ip>"
        echo "  sudo nixos-rebuild switch --flake <your-flake>#<config>"
        echo ""
        echo "Or to upgrade packages:"
        echo "  nix-env -u '*'"
        echo ""
        exit 1
    fi

    local profile
    profile=$(cat "$machine_dir/profile")

    # Check for existing snapshots
    local snapshot_count
    snapshot_count=$(backend_snapshot_count "$name")
    if [ "$snapshot_count" -gt 0 ]; then
        echo "WARNING: VM '$name' has $snapshot_count snapshot(s) that will be DELETED:"
        $VIRSH -c "$LIBVIRT_URI" snapshot-list "$name" --name 2>/dev/null | sed 's/^/  /'
        echo ""
        read -p "Continue with upgrade and delete snapshots? [y/N] " confirm
        if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
            echo "Aborted."
            exit 1
        fi
    fi

    echo "Upgrading VM '$name' to latest $profile image (preserving /var data)"

    stop_graceful "$name"
    $VIRSH -c "$LIBVIRT_URI" undefine "$name" --nvram --snapshots-metadata 2>/dev/null || \
        $VIRSH -c "$LIBVIRT_URI" undefine "$name" --snapshots-metadata 2>/dev/null || \
        $VIRSH -c "$LIBVIRT_URI" undefine "$name" 2>/dev/null || true

    build_profile "$profile"
    backend_sync_identity "$name"

    # Replace only the boot disk (keep /var disk intact)
    local profile_image
    profile_image=$($READLINK -f "$OUTPUT_DIR/profiles/$profile")/nixos.qcow2
    rm -f "$OUTPUT_DIR/vms/$name/boot.qcow2"
    rm -f "$OUTPUT_DIR/vms/$name/OVMF_VARS.qcow2"
    $QEMU_IMG create -f qcow2 \
        -b "$profile_image" \
        -F qcow2 \
        "$OUTPUT_DIR/vms/$name/boot.qcow2"

    backend_generate_config "$name"
    $VIRSH -c "$LIBVIRT_URI" define "$LIBVIRT_DIR/$name.xml"
    backend_start "$name"

    echo ""
    echo "VM '$name' upgraded and started. /var data preserved."
    echo "SSH as admin (sudo): ssh admin@<ip>"
    echo "SSH as user (no sudo): ssh user@<ip>"
}

# Resize the /var disk for a VM (or main disk for mutable VMs)
resize_var() {
    local name="$1"
    local new_size
    new_size=$(normalize_size "$2")

    # Determine disk path based on mutable mode
    local disk_path disk_label
    if is_mutable "$name"; then
        disk_path="$OUTPUT_DIR/vms/$name/disk.qcow2"
        disk_label="disk"
    else
        disk_path="$OUTPUT_DIR/vms/$name/var.qcow2"
        disk_label="/var disk"
    fi

    if [ ! -f "$disk_path" ]; then
        echo "Error: $disk_label not found: $disk_path"
        exit 1
    fi
    local var_disk="$disk_path"

    # Check if VM is running
    if backend_is_running "$name"; then
        echo "Error: VM '$name' must be stopped before resizing."
        echo "Run 'just stop $name' first."
        exit 1
    fi

    # Get current size in bytes
    local current_size_bytes
    current_size_bytes=$($QEMU_IMG info --output=json "$var_disk" | jq -r '.["virtual-size"]')
    local current_size_human
    current_size_human=$(numfmt --to=iec "$current_size_bytes" 2>/dev/null || echo "$current_size_bytes bytes")

    # Convert new size to bytes for comparison
    local new_size_bytes
    new_size_bytes=$(numfmt --from=iec "$new_size" 2>/dev/null || echo "0")
    if [ "$new_size_bytes" -le "$current_size_bytes" ]; then
        echo "Error: New size ($new_size) must be larger than current size ($current_size_human)"
        echo "Shrinking disks is not supported."
        exit 1
    fi

    echo "Current $disk_label size: $current_size_human"
    echo "New size: $new_size"
    echo ""
    echo "NOTE: This will resize the QCOW2 disk image."
    echo "The filesystem inside will be grown automatically."
    read -p "Continue? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi

    echo "Resizing $disk_label..."
    $QEMU_IMG resize "$var_disk" "$new_size"

    # Use guestfish to grow the partition and filesystem
    echo "Growing partition and filesystem..."
    if is_mutable "$name"; then
        # Mutable: root is on partition 2
        $GUESTFISH -a "$var_disk" <<EOF
run
part-resize /dev/sda 2 -1
e2fsck-f /dev/sda2
resize2fs /dev/sda2
EOF
    else
        # Immutable: /var is on partition 1
        $GUESTFISH -a "$var_disk" <<EOF
run
part-resize /dev/sda 1 -1
e2fsck-f /dev/sda1
resize2fs /dev/sda1
EOF
    fi

    echo ""
    echo "Resize complete. Start VM with: just start $name"
}

# Interactively resize VM resources (memory, vcpus, /var disk)
resize_vm() {
    local name="$1"
    local machine_dir="$MACHINES_DIR/$name"

    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        exit 1
    fi

    # Check if VM is running
    if backend_is_running "$name"; then
        echo "Error: VM '$name' must be stopped before resizing."
        echo "Run 'just stop $name' first."
        exit 1
    fi

    # Get current values
    local current_memory current_vcpus current_disk_bytes current_disk_human
    current_memory=$(cat "$machine_dir/memory" 2>/dev/null || echo "2048")
    current_vcpus=$(cat "$machine_dir/vcpus" 2>/dev/null || echo "2")

    # Determine disk path based on mutable mode
    local disk_path disk_label
    if is_mutable "$name"; then
        disk_path="$OUTPUT_DIR/vms/$name/disk.qcow2"
        disk_label="Disk"
    else
        disk_path="$OUTPUT_DIR/vms/$name/var.qcow2"
        disk_label="/var"
    fi
    local var_disk="$disk_path"

    if [ -f "$var_disk" ]; then
        current_disk_bytes=$($QEMU_IMG info --output=json "$var_disk" | jq -r '.["virtual-size"]')
        current_disk_human=$(numfmt --to=iec "$current_disk_bytes" 2>/dev/null || echo "unknown")
    else
        current_disk_bytes=0
        current_disk_human="unknown"
    fi

    echo "Current VM configuration for '$name':"
    echo "  Memory: ${current_memory} MB"
    echo "  vCPUs:  ${current_vcpus}"
    echo "  $disk_label:   ${current_disk_human}"
    echo ""

    # Prompt for new values
    read -p "New memory in MB [$current_memory]: " new_memory
    new_memory="${new_memory:-$current_memory}"

    read -p "New vCPUs [$current_vcpus]: " new_vcpus
    new_vcpus="${new_vcpus:-$current_vcpus}"

    read -p "New $disk_label disk size [$current_disk_human]: " new_disk
    new_disk="${new_disk:-$current_disk_human}"
    new_disk=$(normalize_size "$new_disk")

    # Validate disk size increase
    local new_disk_bytes
    new_disk_bytes=$(numfmt --from=iec "$new_disk" 2>/dev/null || echo "0")
    if [ "$new_disk_bytes" -lt "$current_disk_bytes" ]; then
        echo "Error: New disk size ($new_disk) must be >= current size ($current_disk_human)"
        echo "Shrinking disks is not supported."
        exit 1
    fi

    echo ""
    echo "New configuration:"
    echo "  Memory: ${new_memory} MB"
    echo "  vCPUs:  ${new_vcpus}"
    echo "  /var:   ${new_disk}"
    read -p "Apply changes? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi

    # Update machine config
    echo "$new_memory" > "$machine_dir/memory"
    echo "$new_vcpus" > "$machine_dir/vcpus"

    # Resize disk if needed
    if [ "$new_disk_bytes" -gt "$current_disk_bytes" ] && [ -f "$var_disk" ]; then
        echo "Resizing $disk_label disk..."
        $QEMU_IMG resize "$var_disk" "$new_disk"
        echo "Growing partition and filesystem..."
        if is_mutable "$name"; then
            # Mutable: root is on partition 2
            $GUESTFISH -a "$var_disk" <<EOF
run
part-resize /dev/sda 2 -1
e2fsck-f /dev/sda2
resize2fs /dev/sda2
EOF
        else
            # Immutable: /var is on partition 1
            $GUESTFISH -a "$var_disk" <<EOF
run
part-resize /dev/sda 1 -1
e2fsck-f /dev/sda1
resize2fs /dev/sda1
EOF
        fi
    fi

    # Regenerate libvirt XML and redefine
    echo "Updating VM definition..."
    backend_generate_config "$name" "$new_memory" "$new_vcpus"
    $VIRSH -c "$LIBVIRT_URI" define "$LIBVIRT_DIR/$name.xml"

    echo ""
    echo "Resize complete. Start VM with: just start $name"
}

# Backup a VM (suspend, copy disks, compress)
backup_vm() {
    local name="$1"
    local vm_dir="$OUTPUT_DIR/vms/$name"
    local backup_dir="$OUTPUT_DIR/backups"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$backup_dir/$name-$timestamp.tar.zst"

    if [ ! -d "$vm_dir" ]; then
        echo "Error: VM disks not found: $vm_dir"
        exit 1
    fi

    mkdir -p "$backup_dir"

    # Check if VM is running
    local was_running=false
    if backend_is_running "$name"; then
        was_running=true
        backend_suspend "$name"
    fi

    # Ensure we resume on exit if VM was running
    cleanup() {
        if [ "$was_running" = true ]; then
            backend_resume "$name"
        fi
    }
    trap cleanup EXIT

    echo "Creating backup: $backup_file"
    echo "This may take a while..."

    # Compress VM disks with zstd (or gzip fallback)
    if command -v zstd &>/dev/null; then
        tar -C "$vm_dir" -cf - . | zstd -T0 -o "$backup_file"
    else
        backup_file="$backup_dir/$name-$timestamp.tar.gz"
        tar -C "$vm_dir" -czf "$backup_file" .
    fi

    local size
    size=$(ls -lh "$backup_file" | awk '{print $5}')
    echo ""
    echo "Backup complete: $backup_file ($size)"
}

# Restore a VM from backup
restore_backup_vm() {
    local name="$1"
    local backup_file="${2:-}"
    local vm_dir="$OUTPUT_DIR/vms/$name"
    local machine_dir="$MACHINES_DIR/$name"
    local backup_dir="$OUTPUT_DIR/backups"

    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        echo "The VM must be created first with 'just create $name'"
        exit 1
    fi

    # If no backup file specified, show interactive selection
    if [ -z "$backup_file" ]; then
        shopt -s nullglob
        local backups=("$backup_dir"/$name-*.tar.*)
        if [ ${#backups[@]} -eq 0 ]; then
            echo "No backups found for VM '$name' in $backup_dir/"
            exit 1
        fi

        echo "Available backups for '$name':"
        local i=1
        for f in "${backups[@]}"; do
            local size
            size=$(ls -lh "$f" | awk '{print $5}')
            echo "  $i) $(basename "$f") ($size)"
            ((i++))
        done
        echo ""
        read -p "Select backup to restore [1-${#backups[@]}]: " selection

        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#backups[@]} ]; then
            echo "Invalid selection."
            exit 1
        fi
        backup_file="${backups[$((selection-1))]}"
    fi

    if [ ! -f "$backup_file" ]; then
        echo "Error: Backup file not found: $backup_file"
        exit 1
    fi

    echo "WARNING: This will replace all disks for VM '$name'."
    echo "All current data will be LOST and replaced with backup contents."
    echo "Backup file: $backup_file"
    read -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi

    # Stop VM if running
    echo "Stopping VM '$name'..."
    backend_force_stop "$name"

    # Remove existing disks
    echo "Removing existing disks..."
    rm -rf "$vm_dir"
    mkdir -p "$vm_dir"

    # Extract backup
    echo "Extracting backup: $backup_file"
    echo "This may take a while..."
    case "$backup_file" in
        *.tar.zst)
            zstd -d -c "$backup_file" | tar -C "$vm_dir" -xf -
            ;;
        *.tar.gz|*.tgz)
            tar -C "$vm_dir" -xzf "$backup_file"
            ;;
        *.tar)
            tar -C "$vm_dir" -xf "$backup_file"
            ;;
        *)
            echo "Error: Unknown backup format. Expected .tar.zst, .tar.gz, or .tar"
            exit 1
            ;;
    esac

    # Regenerate XML and define VM in libvirt
    echo "Defining VM in libvirt..."
    backend_generate_config "$name"
    $VIRSH -c "$LIBVIRT_URI" define "$LIBVIRT_DIR/$name.xml" 2>/dev/null || true

    echo ""
    echo "Restore complete. Start VM with: just start $name"
}

# SSH into a VM as the user account
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
        echo "Is the VM running? Check with: just status $name"
        exit 1
    fi
    echo "Connecting to $name at $ip as $ssh_user..."
    $SSH -o StrictHostKeyChecking=accept-new "$ssh_user"@"$ip"
}

# List available backups
list_backups() {
    local backup_dir="$OUTPUT_DIR/backups"
    if [ ! -d "$backup_dir" ] || [ -z "$(ls -A "$backup_dir" 2>/dev/null)" ]; then
        echo "No backups found in $backup_dir/"
        return 0
    fi
    echo "Available backups in $backup_dir/:"
    ls -lh "$backup_dir"/*.tar.* 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'
}
