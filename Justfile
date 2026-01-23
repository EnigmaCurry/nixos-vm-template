# NixOS Immutable VM Image Builder

set shell := ["bash", "-euo", "pipefail", "-c"]

# Default recipe - show available commands
[private]
default:
    @{{JUST}} --list

# Directory for built images and VM disks
output_dir := "output"
libvirt_dir := "libvirt"
machines_dir := "machines"

# Tool commands - override these for distrobox
# Set HOST_CMD="host-spawn" to prefix all commands at once, or override individually
HOST_CMD := env_var_or_default("HOST_CMD", "")
SUDO := env_var_or_default("SUDO", `id -nG 2>/dev/null | grep -qw libvirt && printf '' || printf 'sudo'`)
JUST := env_var_or_default("JUST", "just")
NIX := env_var_or_default("NIX", HOST_CMD + " nix")
VIRSH := env_var_or_default("VIRSH", HOST_CMD + " " + SUDO + " virsh")
QEMU_IMG := env_var_or_default("QEMU_IMG", HOST_CMD + " qemu-img")
GUESTFISH := env_var_or_default("GUESTFISH", HOST_CMD + " guestfish")
CP := env_var_or_default("CP", HOST_CMD + " cp")
READLINK := env_var_or_default("READLINK", HOST_CMD + " readlink")
SSH := env_var_or_default("SSH", HOST_CMD + " ssh")

# libguestfs backend (direct avoids SELinux/libvirt conflicts on Fedora)
export LIBGUESTFS_BACKEND := env_var_or_default("LIBGUESTFS_BACKEND", "direct")

# Libvirt connection URI
LIBVIRT_URI := env_var_or_default("LIBVIRT_URI", "qemu:///system")

# OVMF firmware paths (auto-detect across distros: Fedora, Debian/Ubuntu, Arch)
OVMF_CODE := env_var_or_default("OVMF_CODE", `for f in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd; do [ -f "$f" ] && echo "$f" && break; done`)
OVMF_VARS := env_var_or_default("OVMF_VARS", `for f in /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd; do [ -f "$f" ] && echo "$f" && break; done`)

# Build a profile's base image (default: base)
build profile="core":
    @echo "Building profile: {{profile}}"
    mkdir -p {{output_dir}}/profiles
    {{NIX}} build .#{{profile}} --out-link {{output_dir}}/profiles/{{profile}}
    @echo "Built: {{output_dir}}/profiles/{{profile}}"

# Build all profiles
build-all:
    @echo "Building all profiles..."
    {{JUST}} build base
    {{JUST}} build core
    {{JUST}} build docker
    {{JUST}} build dev
    {{JUST}} build claude
    @echo "All profiles built."

# List available profiles
list-profiles:
    @echo "Available profiles:"
    @ls -1 profiles/*.nix 2>/dev/null | xargs -I{} basename {} .nix || echo "(none)"

# Create a new VM: build profile, create machine config, create disks, generate XML, define in libvirt
create name profile="core" memory="2048" vcpus="2" var_size="20G" network="nat":
    {{JUST}} build {{profile}}
    {{JUST}} _init-machine {{name}} {{profile}} {{network}}
    {{JUST}} _create-disks {{name}} {{var_size}}
    {{JUST}} _generate-xml {{name}} {{memory}} {{vcpus}}
    {{JUST}} _define {{name}}
    @echo ""
    @echo "VM '{{name}}' is ready (profile: {{profile}}). Start with: just start {{name}}"
    @echo "Machine config: {{machines_dir}}/{{name}}/"
    @echo "SSH as admin (sudo): ssh admin@<ip>"
    @echo "SSH as user (no sudo): ssh user@<ip>"

# Clone a VM: copy /var disk from source, generate fresh identity, create boot disk
clone source dest memory="2048" vcpus="2" network="":
    #!/usr/bin/env bash
    set -euo pipefail
    source_machine_dir="{{machines_dir}}/{{source}}"
    dest_machine_dir="{{machines_dir}}/{{dest}}"
    source_vm_dir="{{output_dir}}/vms/{{source}}"
    dest_vm_dir="{{output_dir}}/vms/{{dest}}"

    # Validate source machine config exists
    if [ ! -d "$source_machine_dir" ]; then
        echo "Error: Source machine config not found: $source_machine_dir"
        exit 1
    fi

    # Validate source var disk exists
    if [ ! -f "$source_vm_dir/var.qcow2" ]; then
        echo "Error: Source /var disk not found: $source_vm_dir/var.qcow2"
        exit 1
    fi

    # Validate source VM is shut off
    state=$({{VIRSH}} -c {{LIBVIRT_URI}} domstate {{source}} 2>/dev/null || echo "unknown")
    if [ "$state" != "shut off" ] && [ "$state" != "unknown" ]; then
        echo "Error: Source VM '{{source}}' must be shut off (current state: $state)"
        echo "Run 'just stop {{source}}' first."
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

    echo "Cloning VM '{{source}}' -> '{{dest}}'"

    # Initialize machine config (non-interactive)
    {{JUST}} _init-machine-clone {{source}} {{dest}} "{{network}}"

    # Copy var disk
    echo "Copying /var disk..."
    mkdir -p "$dest_vm_dir"
    {{CP}} "$source_vm_dir/var.qcow2" "$dest_vm_dir/var.qcow2"

    # Sync new identity onto copied var disk
    {{JUST}} _sync-identity {{dest}}

    # Create boot disk with same profile's base image
    profile=$(cat "$dest_machine_dir/profile")
    profile_image=$({{READLINK}} -f {{output_dir}}/profiles/$profile)/nixos.qcow2
    if [ ! -f "$profile_image" ]; then
        echo "Error: Profile image not found: $profile_image"
        echo "Run 'just build $profile' first"
        exit 1
    fi
    {{QEMU_IMG}} create -f qcow2 \
        -b "$profile_image" \
        -F qcow2 \
        "$dest_vm_dir/boot.qcow2"

    # Generate XML and define in libvirt
    {{JUST}} _generate-xml {{dest}} {{memory}} {{vcpus}}
    {{JUST}} _define {{dest}}

    echo ""
    echo "VM '{{dest}}' cloned from '{{source}}'. Start with: just start {{dest}}"

# Initialize machine config directory (creates identity files if not present)
_init-machine name profile="core" network="nat":
    #!/usr/bin/env bash
    set -euo pipefail
    machine_dir="{{machines_dir}}/{{name}}"
    mkdir -p "$machine_dir"

    # Set profile (only if not present, unless explicitly overridden)
    if [ ! -f "$machine_dir/profile" ]; then
        echo "{{profile}}" > "$machine_dir/profile"
        echo "Created: $machine_dir/profile ({{profile}})"
    elif [ "{{profile}}" != "base" ]; then
        # Only overwrite if user explicitly passed a non-default profile
        echo "{{profile}}" > "$machine_dir/profile"
        echo "Updated: $machine_dir/profile ({{profile}})"
    else
        echo "Using existing profile: $(cat "$machine_dir/profile")"
    fi

    # Set network configuration (default: nat)
    network_config="{{network}}"
    if [ ! -f "$machine_dir/network" ]; then
        # No existing config - set it
        {{JUST}} _network-config {{name}} "$network_config"
    elif [ "$network_config" != "nat" ]; then
        # User explicitly passed non-default network - update it
        {{JUST}} _network-config {{name}} "$network_config"
    else
        echo "Using existing network config: $(cat "$machine_dir/network")"
    fi

    # Create root password hash file if not present (empty = no password)
    if [ ! -f "$machine_dir/root_password_hash" ]; then
        touch "$machine_dir/root_password_hash"
        chmod 600 "$machine_dir/root_password_hash"
        echo "Created: $machine_dir/root_password_hash (empty - no root password)"
    fi

    # Generate machine-id if not present
    if [ ! -f "$machine_dir/machine-id" ]; then
        cat /proc/sys/kernel/random/uuid | tr -d '-' > "$machine_dir/machine-id"
        echo "Generated: $machine_dir/machine-id"
    fi

    # Generate MAC address if not present (uses QEMU/KVM OUI prefix 52:54:00)
    if [ ! -f "$machine_dir/mac-address" ]; then
        printf '52:54:00:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) > "$machine_dir/mac-address"
        echo "Generated: $machine_dir/mac-address ($(cat "$machine_dir/mac-address"))"
    fi

    # Generate libvirt UUID if not present
    if [ ! -f "$machine_dir/uuid" ]; then
        cat /proc/sys/kernel/random/uuid > "$machine_dir/uuid"
        echo "Generated: $machine_dir/uuid"
    fi

    # Create hostname if not present (defaults to VM name)
    if [ ! -f "$machine_dir/hostname" ]; then
        echo "{{name}}" > "$machine_dir/hostname"
        echo "Created: $machine_dir/hostname"
    fi

    # Generate SSH host key if not present
    if [ ! -f "$machine_dir/ssh_host_ed25519_key" ]; then
        ssh-keygen -t ed25519 -f "$machine_dir/ssh_host_ed25519_key" -N "" -C "root@{{name}}"
        echo "Generated: $machine_dir/ssh_host_ed25519_key"
    fi

    # Prompt for admin authorized_keys if not present
    if [ ! -f "$machine_dir/admin_authorized_keys" ]; then
        echo ""
        echo "Enter SSH public key(s) for 'admin' (has sudo access):"
        echo "(Paste key, then press Enter, then Ctrl+D. Leave empty and press Ctrl+D to skip)"
        # Create file with header comment
        printf '%s\n' "# SSH authorized_keys for 'admin' user (has sudo access)" "# Add one public key per line. Run 'just upgrade {{name}}' to apply changes." "" > "$machine_dir/admin_authorized_keys"
        cat >> "$machine_dir/admin_authorized_keys" || true
        # Check if any actual keys were added (more than just the header)
        if [ "$(grep -cv '^#\|^$' "$machine_dir/admin_authorized_keys")" -gt 0 ]; then
            echo "Saved: $machine_dir/admin_authorized_keys"
        else
            echo "No admin authorized_keys configured (admin SSH login will be disabled)"
        fi
    fi

    # Prompt for user authorized_keys if not present
    if [ ! -f "$machine_dir/user_authorized_keys" ]; then
        echo ""
        echo "Enter SSH public key(s) for 'user' (no sudo access):"
        echo "(Paste key, then press Enter, then Ctrl+D. Leave empty and press Ctrl+D to skip)"
        # Create file with header comment
        printf '%s\n' "# SSH authorized_keys for 'user' account (no sudo access)" "# Add one public key per line. Run 'just upgrade {{name}}' to apply changes." "" > "$machine_dir/user_authorized_keys"
        cat >> "$machine_dir/user_authorized_keys" || true
        # Check if any actual keys were added (more than just the header)
        if [ "$(grep -cv '^#\|^$' "$machine_dir/user_authorized_keys")" -gt 0 ]; then
            echo "Saved: $machine_dir/user_authorized_keys"
        else
            echo "No user authorized_keys configured (user SSH login will be disabled)"
        fi
    fi

    # Create default tcp_ports if not present
    if [ ! -f "$machine_dir/tcp_ports" ]; then
        printf '%s\n' "# TCP ports to open in firewall (one per line)" "# Run 'just upgrade {{name}}' to apply changes." "22" "80" "443" > "$machine_dir/tcp_ports"
        echo "Created: $machine_dir/tcp_ports (22, 80, 443)"
    fi

    # Create default udp_ports if not present
    if [ ! -f "$machine_dir/udp_ports" ]; then
        printf '%s\n' "# UDP ports to open in firewall (one per line)" "# Run 'just upgrade {{name}}' to apply changes." > "$machine_dir/udp_ports"
        echo "Created: $machine_dir/udp_ports (empty)"
    fi

    # Create default resolv.conf if not present
    if [ ! -f "$machine_dir/resolv.conf" ]; then
        printf '%s\n' "# DNS configuration. Run 'just upgrade {{name}}' to apply changes." "nameserver 1.1.1.1" "nameserver 1.0.0.1" > "$machine_dir/resolv.conf"
        echo "Created: $machine_dir/resolv.conf (Cloudflare DNS)"
    fi

    echo "Machine config ready: $machine_dir/"

# Internal: initialize machine config for clone (non-interactive, copies from source)
_init-machine-clone source dest network="":
    #!/usr/bin/env bash
    set -euo pipefail
    source_dir="{{machines_dir}}/{{source}}"
    dest_dir="{{machines_dir}}/{{dest}}"
    mkdir -p "$dest_dir"

    # Copy config files from source
    for f in admin_authorized_keys user_authorized_keys tcp_ports udp_ports resolv.conf root_password_hash profile; do
        if [ -f "$source_dir/$f" ]; then
            cp "$source_dir/$f" "$dest_dir/$f"
        fi
    done

    # Handle network: copy from source or use override
    network_override="{{network}}"
    if [ -n "$network_override" ]; then
        # Store raw value; for "bridge" we copy source's bridge config
        if [ "$network_override" = "bridge" ] && [ -f "$source_dir/network" ]; then
            source_net=$(cat "$source_dir/network")
            if [[ "$source_net" == bridge:* ]]; then
                echo "$source_net" > "$dest_dir/network"
            else
                echo "bridge:br0" > "$dest_dir/network"
            fi
        else
            echo "$network_override" > "$dest_dir/network"
        fi
    elif [ -f "$source_dir/network" ]; then
        cp "$source_dir/network" "$dest_dir/network"
    else
        echo "nat" > "$dest_dir/network"
    fi

    # Generate fresh identity
    cat /proc/sys/kernel/random/uuid | tr -d '-' > "$dest_dir/machine-id"
    echo "Generated: $dest_dir/machine-id"

    printf '52:54:00:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) > "$dest_dir/mac-address"
    echo "Generated: $dest_dir/mac-address ($(cat "$dest_dir/mac-address"))"

    cat /proc/sys/kernel/random/uuid > "$dest_dir/uuid"
    echo "Generated: $dest_dir/uuid"

    echo "{{dest}}" > "$dest_dir/hostname"
    echo "Created: $dest_dir/hostname"

    ssh-keygen -t ed25519 -f "$dest_dir/ssh_host_ed25519_key" -N "" -C "root@{{dest}}"
    echo "Generated: $dest_dir/ssh_host_ed25519_key"

    # Preserve permissions on sensitive files
    if [ -f "$dest_dir/root_password_hash" ]; then
        chmod 600 "$dest_dir/root_password_hash"
    fi

    echo "Machine config ready: $dest_dir/ (cloned from {{source}})"

# Configure network mode for a VM (nat or bridge)
network-config name network="":
    #!/usr/bin/env bash
    set -euo pipefail
    machine_dir="{{machines_dir}}/{{name}}"
    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        echo "Create the VM first with 'just create {{name}}'"
        exit 1
    fi

    network_param="{{network}}"
    current=$(cat "$machine_dir/network" 2>/dev/null || echo "nat")

    # If no network specified, show current and prompt
    if [ -z "$network_param" ]; then
        echo "Current network config: $current"
        echo ""
        echo "Select network mode:"
        echo "  1) nat - NAT networking via libvirt (default)"
        echo "  2) bridge - Bridged networking to physical network"
        echo ""
        read -p "Selection [1-2]: " mode_selection
        case "$mode_selection" in
            1) network_param="nat" ;;
            2) network_param="bridge" ;;
            *) echo "Invalid selection."; exit 1 ;;
        esac
    fi

    {{JUST}} _network-config {{name}} "$network_param"

# Internal: set network configuration for a machine
_network-config name network:
    #!/usr/bin/env bash
    set -euo pipefail
    machine_dir="{{machines_dir}}/{{name}}"
    mkdir -p "$machine_dir"
    network_config="{{network}}"

    if [[ "$network_config" == "nat" ]]; then
        echo "nat" > "$machine_dir/network"
        echo "Network configured: nat"
    elif [[ "$network_config" == "bridge" ]]; then
        # List available bridges (excluding virbr0, docker bridges)
        mapfile -t bridges < <(for d in /sys/class/net/*/bridge; do basename "$(dirname "$d")"; done 2>/dev/null | grep -vE '^(virbr[0-9]+|docker[0-9]*|br-)' || true)
        if [ ${#bridges[@]} -eq 0 ]; then
            echo "Error: No bridge interfaces found (excluding virbr0 and docker bridges)."
            echo ""
            echo "To use bridged networking, you need to create a bridge interface first."
            echo "This bridge should include your physical network interface."
            echo ""
            echo "NOTE: WiFi interfaces cannot be bridged (802.11 does not support L2"
            echo "bridging). If you only have WiFi, use NAT networking instead."
            echo ""
            echo "Example using NetworkManager (wired ethernet only):"
            echo "  nmcli connection add type bridge ifname br0 con-name br0"
            echo "  nmcli connection add type bridge-slave ifname eth0 master br0"
            echo ""
            echo "After creating a bridge, run this command again."
            exit 1
        fi
        echo ""
        echo "Available bridge interfaces:"
        i=1
        for br in "${bridges[@]}"; do
            echo "  $i) $br"
            ((i++))
        done
        echo ""
        read -p "Select bridge [1-${#bridges[@]}]: " selection
        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#bridges[@]} ]; then
            echo "Invalid selection."
            exit 1
        fi
        selected_bridge="${bridges[$((selection-1))]}"
        echo "bridge:$selected_bridge" > "$machine_dir/network"
        echo "Network configured: bridge:$selected_bridge"
    else
        echo "Error: Invalid network config '$network_config'. Use 'nat' or 'bridge'"
        exit 1
    fi

# Internal: create VM disks and copy identity from machine config
_create-disks name var_size="20G":
    #!/usr/bin/env bash
    set -euo pipefail
    machine_dir="{{machines_dir}}/{{name}}"

    # Verify machine config exists
    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        echo "Run 'just _init-machine {{name}}' first"
        exit 1
    fi

    # Read profile from machine config
    profile=$(cat "$machine_dir/profile")

    echo "Creating VM disks: {{name}} (profile: $profile)"
    mkdir -p {{output_dir}}/vms/{{name}}

    # Resolve the profile image path
    profile_image=$({{READLINK}} -f {{output_dir}}/profiles/$profile)/nixos.qcow2

    if [ ! -f "$profile_image" ]; then
        echo "Error: Profile image not found: $profile_image"
        echo "Run 'just build $profile' first"
        exit 1
    fi

    # Create boot disk with backing file
    {{QEMU_IMG}} create -f qcow2 \
        -b "$profile_image" \
        -F qcow2 \
        {{output_dir}}/vms/{{name}}/boot.qcow2

    # Create /var disk
    {{QEMU_IMG}} create -f qcow2 {{output_dir}}/vms/{{name}}/var.qcow2 {{var_size}}

    # Read identity from machine config
    hostname=$(cat "$machine_dir/hostname")
    machine_id=$(cat "$machine_dir/machine-id")

    # Build guestfish commands
    gf_cmds="run : part-disk /dev/sda gpt : mkfs ext4 /dev/sda1 : mount /dev/sda1 /"
    gf_cmds="$gf_cmds : mkdir-p /identity"
    gf_cmds="$gf_cmds : write /identity/hostname '$hostname'"
    gf_cmds="$gf_cmds : write /identity/machine-id '$machine_id'"

    # Add admin authorized_keys to /identity (owned by root, read-only to user)
    if [ -s "$machine_dir/admin_authorized_keys" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/admin_authorized_keys /identity/"
    else
        # Create empty file so bind mount works
        gf_cmds="$gf_cmds : touch /identity/admin_authorized_keys"
    fi
    gf_cmds="$gf_cmds : chmod 0644 /identity/admin_authorized_keys"
    gf_cmds="$gf_cmds : chown 0 0 /identity/admin_authorized_keys"

    # Add user authorized_keys to /identity (owned by root, read-only to user)
    if [ -s "$machine_dir/user_authorized_keys" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/user_authorized_keys /identity/"
    else
        # Create empty file so bind mount works
        gf_cmds="$gf_cmds : touch /identity/user_authorized_keys"
    fi
    gf_cmds="$gf_cmds : chmod 0644 /identity/user_authorized_keys"
    gf_cmds="$gf_cmds : chown 0 0 /identity/user_authorized_keys"

    # Copy SSH host key to /identity (owned by root:root)
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

    # Copy root password hash to /var/identity (empty = no password)
    gf_cmds="$gf_cmds : copy-in $machine_dir/root_password_hash /identity/"
    gf_cmds="$gf_cmds : chmod 0600 /identity/root_password_hash"
    gf_cmds="$gf_cmds : chown 0 0 /identity/root_password_hash"

    # Initialize /var disk
    echo "Initializing /var disk with identity from $machine_dir/"
    eval "{{GUESTFISH}} -a {{output_dir}}/vms/{{name}}/var.qcow2 $gf_cmds"

    echo "Created VM disks in {{output_dir}}/vms/{{name}}/"
    echo "  boot.qcow2 (backing: $profile_image)"
    echo "  var.qcow2 ({{var_size}}, ext4)"
    echo "  Identity: hostname=$hostname"

# Sync identity files from machine config to existing /var disk
_sync-identity name:
    #!/usr/bin/env bash
    set -euo pipefail
    machine_dir="{{machines_dir}}/{{name}}"
    var_disk="{{output_dir}}/vms/{{name}}/var.qcow2"

    if [ ! -f "$var_disk" ]; then
        echo "Error: /var disk not found: $var_disk"
        exit 1
    fi

    echo "Syncing identity files from $machine_dir/ to /var disk"

    # Build guestfish commands to update identity files
    gf_cmds="run : mount /dev/sda1 /"

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

    # Update root password hash
    if [ -f "$machine_dir/root_password_hash" ]; then
        gf_cmds="$gf_cmds : copy-in $machine_dir/root_password_hash /identity/"
        gf_cmds="$gf_cmds : chmod 0600 /identity/root_password_hash"
        gf_cmds="$gf_cmds : chown 0 0 /identity/root_password_hash"
    fi

    eval "{{GUESTFISH}} -a $var_disk $gf_cmds"
    echo "Identity files synced."

# Generate libvirt XML for a VM
_generate-xml name memory="2048" vcpus="2":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Generating libvirt XML for: {{name}}"
    mkdir -p {{libvirt_dir}}
    boot_disk=$({{READLINK}} -f {{output_dir}}/vms/{{name}}/boot.qcow2)
    var_disk=$({{READLINK}} -f {{output_dir}}/vms/{{name}}/var.qcow2)
    ovmf_vars_dest=$({{READLINK}} -f {{output_dir}}/vms/{{name}})/OVMF_VARS.qcow2
    mac_address=$(cat {{machines_dir}}/{{name}}/mac-address)
    # Generate UUID if not present (for VMs created before UUID support)
    if [ ! -f "{{machines_dir}}/{{name}}/uuid" ]; then
        cat /proc/sys/kernel/random/uuid > "{{machines_dir}}/{{name}}/uuid"
        echo "Generated: {{machines_dir}}/{{name}}/uuid"
    fi
    vm_uuid=$(cat {{machines_dir}}/{{name}}/uuid)

    # Parse network configuration (default to nat for backwards compatibility)
    network_config=$(cat {{machines_dir}}/{{name}}/network 2>/dev/null || echo "nat")
    if [[ "$network_config" == "nat" ]]; then
        network_type="network"
        network_source="network='default'"
    elif [[ "$network_config" == bridge:* ]]; then
        bridge_name="${network_config#bridge:}"
        network_type="bridge"
        network_source="bridge='$bridge_name'"
    else
        echo "Error: Invalid network config '$network_config'"
        exit 1
    fi

    # Convert NVRAM template to QCOW2 (required for snapshots with UEFI)
    {{QEMU_IMG}} convert -f raw -O qcow2 {{OVMF_VARS}} "$ovmf_vars_dest" 2>/dev/null || \
        echo "Warning: Could not convert OVMF_VARS to QCOW2 from {{OVMF_VARS}}"
    owner_uid=$(id -u)
    owner_gid=$(id -g)
    sed -e "s|@@VM_NAME@@|{{name}}|g" \
        -e "s|@@UUID@@|$vm_uuid|g" \
        -e "s|@@MEMORY@@|{{memory}}|g" \
        -e "s|@@VCPUS@@|{{vcpus}}|g" \
        -e "s|@@BOOT_DISK@@|$boot_disk|g" \
        -e "s|@@VAR_DISK@@|$var_disk|g" \
        -e "s|@@OVMF_CODE@@|{{OVMF_CODE}}|g" \
        -e "s|@@OVMF_VARS@@|$ovmf_vars_dest|g" \
        -e "s|@@MAC_ADDRESS@@|$mac_address|g" \
        -e "s|@@NETWORK_TYPE@@|$network_type|g" \
        -e "s|@@NETWORK_SOURCE@@|$network_source|g" \
        -e "s|@@OWNER_UID@@|$owner_uid|g" \
        -e "s|@@OWNER_GID@@|$owner_gid|g" \
        {{libvirt_dir}}/template.xml > {{libvirt_dir}}/{{name}}.xml
    echo "Generated: {{libvirt_dir}}/{{name}}.xml"

# Define a VM in libvirt
_define name:
    @echo "Defining VM in libvirt: {{name}}"
    {{VIRSH}} -c {{LIBVIRT_URI}} define {{libvirt_dir}}/{{name}}.xml
    @echo "VM defined. Start with: just start {{name}}"

# Undefine a VM from libvirt (also removes snapshot metadata)
_undefine name:
    @echo "Undefining VM from libvirt: {{name}}"
    {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}} --nvram --snapshots-metadata || {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}} --snapshots-metadata || {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}}

# Start a VM
start name:
    #!/usr/bin/env bash
    set -euo pipefail
    # Read the VM's network config
    network_config=$(cat {{machines_dir}}/{{name}}/network 2>/dev/null || echo "nat")
    if [[ "$network_config" == "nat" ]]; then
        # Ensure the default NAT network is defined and active
        if ! {{VIRSH}} -c {{LIBVIRT_URI}} net-info default &>/dev/null; then
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
            {{VIRSH}} -c {{LIBVIRT_URI}} net-define /tmp/libvirt-default-net.xml
            rm -f /tmp/libvirt-default-net.xml
        fi
        {{VIRSH}} -c {{LIBVIRT_URI}} net-start default 2>/dev/null || true
        {{VIRSH}} -c {{LIBVIRT_URI}} net-autostart default 2>/dev/null || true
    fi
    echo "Starting VM: {{name}}"
    {{VIRSH}} -c {{LIBVIRT_URI}} start {{name}}

# Stop a VM
stop name:
    @echo "Stopping VM: {{name}}"
    {{VIRSH}} -c {{LIBVIRT_URI}} shutdown {{name}}

# Force stop a VM
force-stop name:
    @echo "Force stopping VM: {{name}}"
    -{{VIRSH}} -c {{LIBVIRT_URI}} destroy {{name}}

# Fully destroy a VM: force stop, undefine, remove disk files (keeps machine config)
destroy name:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "WARNING: This will destroy VM '{{name}}' and delete all its disks."
    echo "All data in /var and home directories will be PERMANENTLY LOST."
    echo "(Machine config in {{machines_dir}}/{{name}}/ will be preserved)"
    read -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi
    echo "Destroying VM: {{name}}"
    {{VIRSH}} -c {{LIBVIRT_URI}} destroy {{name}} 2>/dev/null || true
    {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}} --nvram --snapshots-metadata 2>/dev/null || {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}} --snapshots-metadata 2>/dev/null || {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}} 2>/dev/null || true
    rm -rf {{output_dir}}/vms/{{name}}
    rm -f {{libvirt_dir}}/{{name}}.xml
    echo "VM '{{name}}' has been removed."
    echo "Machine config preserved: {{machines_dir}}/{{name}}/"
    echo "To also remove config: just purge {{name}}"

# Completely remove a VM including its machine config
purge name:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "WARNING: This will COMPLETELY remove VM '{{name}}'."
    echo "All data in /var and home directories will be PERMANENTLY LOST."
    echo "Machine config (SSH keys, identity) will also be deleted."
    read -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi
    echo "Purging VM: {{name}}"
    {{VIRSH}} -c {{LIBVIRT_URI}} destroy {{name}} 2>/dev/null || true
    {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}} --nvram --snapshots-metadata 2>/dev/null || {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}} --snapshots-metadata 2>/dev/null || {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}} 2>/dev/null || true
    rm -rf {{output_dir}}/vms/{{name}}
    rm -f {{libvirt_dir}}/{{name}}.xml
    rm -rf {{machines_dir}}/{{name}}
    echo "VM '{{name}}' completely removed."

# Recreate a VM from its existing machine config (force stop, replace disks, start)
recreate name var_size="20G" network="":
    #!/usr/bin/env bash
    set -euo pipefail
    machine_dir="{{machines_dir}}/{{name}}"
    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        echo "Use '{{JUST}} create {{name}}' for new VMs"
        exit 1
    fi
    profile=$(cat "$machine_dir/profile")

    # Update network config if specified
    network_param="{{network}}"
    if [ -n "$network_param" ]; then
        {{JUST}} _network-config {{name}} "$network_param"
    fi
    current_network=$(cat "$machine_dir/network" 2>/dev/null || echo "nat")

    echo "WARNING: This will recreate VM '{{name}}' with a fresh start."
    echo "All data in /var and home directories will be PERMANENTLY LOST."
    echo "(Machine config in {{machines_dir}}/{{name}}/ will be preserved)"
    echo "Profile: $profile"
    echo "Network: $current_network"
    read -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi
    echo "Recreating VM '{{name}}' with profile: $profile"

    # Force power off if running
    {{VIRSH}} -c {{LIBVIRT_URI}} destroy {{name}} 2>/dev/null || true

    # Undefine VM (clears snapshot metadata)
    {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}} --nvram --snapshots-metadata 2>/dev/null || \
        {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}} --snapshots-metadata 2>/dev/null || \
        {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}} 2>/dev/null || true

    # Rebuild profile and replace disks
    {{JUST}} build "$profile"
    rm -rf {{output_dir}}/vms/{{name}}
    {{JUST}} _create-disks {{name}} {{var_size}}

    # Regenerate XML and redefine VM
    {{JUST}} _generate-xml {{name}}
    {{VIRSH}} -c {{LIBVIRT_URI}} define {{libvirt_dir}}/{{name}}.xml

    # Start the VM
    {{VIRSH}} -c {{LIBVIRT_URI}} start {{name}}
    echo ""
    echo "VM '{{name}}' recreated and started."
    echo "SSH as admin (sudo): ssh admin@<ip>"
    echo "SSH as user (no sudo): ssh user@<ip>"

# Upgrade a VM to a new image (preserves /var data)
upgrade name:
    #!/usr/bin/env bash
    set -euo pipefail
    machine_dir="{{machines_dir}}/{{name}}"
    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        echo "Use '{{JUST}} create {{name}}' for new VMs"
        exit 1
    fi
    profile=$(cat "$machine_dir/profile")

    # Check for existing snapshots
    snapshot_count=$({{VIRSH}} -c {{LIBVIRT_URI}} snapshot-list {{name}} --name 2>/dev/null | grep -c . || true)
    if [ "$snapshot_count" -gt 0 ]; then
        echo "WARNING: VM '{{name}}' has $snapshot_count snapshot(s) that will be DELETED:"
        {{VIRSH}} -c {{LIBVIRT_URI}} snapshot-list {{name}} --name 2>/dev/null | sed 's/^/  /'
        echo ""
        read -p "Continue with upgrade and delete snapshots? [y/N] " confirm
        if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
            echo "Aborted."
            exit 1
        fi
    fi

    echo "Upgrading VM '{{name}}' to latest $profile image (preserving /var data)"

    # Force power off if running
    {{VIRSH}} -c {{LIBVIRT_URI}} destroy {{name}} 2>/dev/null || true

    # Undefine VM (clears snapshot metadata)
    {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}} --nvram --snapshots-metadata 2>/dev/null || \
        {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}} --snapshots-metadata 2>/dev/null || \
        {{VIRSH}} -c {{LIBVIRT_URI}} undefine {{name}} 2>/dev/null || true

    # Rebuild profile
    {{JUST}} build "$profile"

    # Sync identity files from machine config to /var disk
    {{JUST}} _sync-identity {{name}}

    # Replace only the boot disk (keep /var disk intact)
    profile_image=$({{READLINK}} -f {{output_dir}}/profiles/$profile)/nixos.qcow2
    rm -f {{output_dir}}/vms/{{name}}/boot.qcow2
    rm -f {{output_dir}}/vms/{{name}}/OVMF_VARS.qcow2
    {{QEMU_IMG}} create -f qcow2 \
        -b "$profile_image" \
        -F qcow2 \
        {{output_dir}}/vms/{{name}}/boot.qcow2

    # Regenerate XML and redefine VM
    {{JUST}} _generate-xml {{name}}
    {{VIRSH}} -c {{LIBVIRT_URI}} define {{libvirt_dir}}/{{name}}.xml

    # Start the VM
    {{VIRSH}} -c {{LIBVIRT_URI}} start {{name}}
    echo ""
    echo "VM '{{name}}' upgraded and started. /var data preserved."
    echo "SSH as admin (sudo): ssh admin@<ip>"
    echo "SSH as user (no sudo): ssh user@<ip>"

# Set or clear the root password for a VM
passwd name:
    #!/usr/bin/env bash
    set -euo pipefail
    machine_dir="{{machines_dir}}/{{name}}"
    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        exit 1
    fi
    echo "Set root password for VM '{{name}}'"
    echo "(leave blank to disable root password)"
    read -s -p "Password: " password
    echo
    if [ -z "$password" ]; then
        > "$machine_dir/root_password_hash"
        echo "Root password disabled."
    else
        read -s -p "Confirm: " confirm
        echo
        if [ "$password" != "$confirm" ]; then
            echo "Error: passwords do not match."
            exit 1
        fi
        hash=$(printf '%s' "$password" | {{NIX}} run nixpkgs#mkpasswd -- -m sha-512 --stdin)
        echo -n "$hash" > "$machine_dir/root_password_hash"
        echo "Root password hash saved."
    fi
    chmod 600 "$machine_dir/root_password_hash"
    echo "Run 'just upgrade {{name}}' to apply."

# List all machine configs
list-machines:
    #!/usr/bin/env bash
    echo "Machine configs in {{machines_dir}}/:"
    shopt -s nullglob
    found=0
    for dir in {{machines_dir}}/*/; do
        if [ -d "$dir" ]; then
            name=$(basename "$dir")
            profile=$(cat "$dir/profile" 2>/dev/null || echo "unknown")
            echo "  $name (profile: $profile)"
            found=1
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo "  (none)"
    fi

# Show VM console
console name:
    {{VIRSH}} -c {{LIBVIRT_URI}} console {{name}}

# SSH into a VM as the user account
ssh name:
    #!/usr/bin/env bash
    set -euo pipefail
    # Get IP address from libvirt
    ip=$({{VIRSH}} -c {{LIBVIRT_URI}} domifaddr {{name}} 2>/dev/null | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}')
    if [ -z "$ip" ]; then
        echo "Error: Could not determine IP address for VM '{{name}}'"
        echo "Is the VM running? Check with: just status {{name}}"
        exit 1
    fi
    echo "Connecting to {{name}} at $ip as user..."
    {{SSH}} -o StrictHostKeyChecking=accept-new user@"$ip"

# Show VM status
status name:
    #!/usr/bin/env bash
    {{VIRSH}} -c {{LIBVIRT_URI}} dominfo {{name}}
    echo ""
    echo "IP Address(es):"
    {{VIRSH}} -c {{LIBVIRT_URI}} domifaddr {{name}} 2>/dev/null || echo "  (not available - VM may not be running or guest agent not installed)"

# List all VMs
list:
    {{VIRSH}} -c {{LIBVIRT_URI}} list --all

# Create a snapshot of a VM
snapshot name snapshot_name:
    @echo "Creating snapshot '{{snapshot_name}}' for VM '{{name}}'..."
    {{VIRSH}} -c {{LIBVIRT_URI}} snapshot-create-as {{name}} {{snapshot_name}}
    @echo "Snapshot '{{snapshot_name}}' created."

# Restore a VM to a snapshot
restore-snapshot name snapshot_name:
    @echo "Restoring VM '{{name}}' to snapshot '{{snapshot_name}}'..."
    {{VIRSH}} -c {{LIBVIRT_URI}} snapshot-revert {{name}} {{snapshot_name}}
    @echo "VM '{{name}}' restored to '{{snapshot_name}}'."

# List snapshots for a VM
snapshots name:
    {{VIRSH}} -c {{LIBVIRT_URI}} snapshot-list {{name}}

# Backup a VM (suspend, copy disks, compress)
backup name:
    #!/usr/bin/env bash
    set -euo pipefail
    vm_dir="{{output_dir}}/vms/{{name}}"
    backup_dir="{{output_dir}}/backups"
    timestamp=$(date +%Y%m%d-%H%M%S)
    backup_file="$backup_dir/{{name}}-$timestamp.tar.zst"

    if [ ! -d "$vm_dir" ]; then
        echo "Error: VM disks not found: $vm_dir"
        exit 1
    fi

    mkdir -p "$backup_dir"

    # Check if VM is running
    was_running=false
    if {{VIRSH}} -c {{LIBVIRT_URI}} domstate {{name}} 2>/dev/null | grep -q "running"; then
        was_running=true
        echo "Suspending VM '{{name}}'..."
        {{VIRSH}} -c {{LIBVIRT_URI}} suspend {{name}}
    fi

    # Ensure we resume on exit if VM was running
    cleanup() {
        if [ "$was_running" = true ]; then
            echo "Resuming VM '{{name}}'..."
            {{VIRSH}} -c {{LIBVIRT_URI}} resume {{name}} || true
        fi
    }
    trap cleanup EXIT

    echo "Creating backup: $backup_file"
    echo "This may take a while..."

    # Compress VM disks with zstd (or gzip fallback)
    if command -v zstd &>/dev/null; then
        tar -C "$vm_dir" -cf - . | zstd -T0 -o "$backup_file"
    else
        backup_file="$backup_dir/{{name}}-$timestamp.tar.gz"
        tar -C "$vm_dir" -czf "$backup_file" .
    fi

    # Get file size
    size=$(ls -lh "$backup_file" | awk '{print $5}')
    echo ""
    echo "Backup complete: $backup_file ($size)"

# Restore a VM from backup (interactive selection if no file specified)
restore-backup name backup_file="":
    #!/usr/bin/env bash
    set -euo pipefail
    vm_dir="{{output_dir}}/vms/{{name}}"
    machine_dir="{{machines_dir}}/{{name}}"
    backup_dir="{{output_dir}}/backups"
    backup_file="{{backup_file}}"

    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        echo "The VM must be created first with 'just create {{name}}'"
        exit 1
    fi

    # If no backup file specified, show interactive selection
    if [ -z "$backup_file" ]; then
        # Find backups for this VM
        shopt -s nullglob
        backups=("$backup_dir"/{{name}}-*.tar.*)
        if [ ${#backups[@]} -eq 0 ]; then
            echo "No backups found for VM '{{name}}' in $backup_dir/"
            exit 1
        fi

        echo "Available backups for '{{name}}':"
        i=1
        for f in "${backups[@]}"; do
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

    echo "WARNING: This will replace all disks for VM '{{name}}'."
    echo "All current data will be LOST and replaced with backup contents."
    echo "Backup file: $backup_file"
    read -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi

    # Stop VM if running
    echo "Stopping VM '{{name}}'..."
    {{VIRSH}} -c {{LIBVIRT_URI}} destroy {{name}} 2>/dev/null || true

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

    # Regenerate XML and define VM in libvirt (in case it was undefined)
    echo "Defining VM in libvirt..."
    {{JUST}} _generate-xml {{name}}
    {{VIRSH}} -c {{LIBVIRT_URI}} define {{libvirt_dir}}/{{name}}.xml 2>/dev/null || true

    echo ""
    echo "Restore complete. Start VM with: just start {{name}}"

# List available backups
backups:
    #!/usr/bin/env bash
    backup_dir="{{output_dir}}/backups"
    if [ ! -d "$backup_dir" ] || [ -z "$(ls -A "$backup_dir" 2>/dev/null)" ]; then
        echo "No backups found in $backup_dir/"
        exit 0
    fi
    echo "Available backups in $backup_dir/:"
    ls -lh "$backup_dir"/*.tar.* 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'

# Clean built images and VM disks (keeps machine configs)
clean:
    rm -rf {{output_dir}}
    @echo "Cleaned {{output_dir}}/"

# Clean generated libvirt XML files
_clean-xml:
    rm -f {{libvirt_dir}}/*.xml
    @echo "Cleaned {{libvirt_dir}}/*.xml"

# Enter development shell
shell:
    {{NIX}} develop
