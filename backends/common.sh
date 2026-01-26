#!/usr/bin/env bash
# Common functions for NixOS VM Template
# Sourced by backend scripts - do not execute directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Normalize disk size: add 'G' suffix if no unit specified
# Examples: "30" -> "30G", "30G" -> "30G", "500M" -> "500M"
normalize_size() {
    local size="$1"
    if [[ "$size" =~ ^[0-9]+$ ]]; then
        echo "${size}G"
    else
        echo "$size"
    fi
}

# Environment defaults
HOST_CMD="${HOST_CMD:-}"
SUDO="${SUDO:-$(id -nG 2>/dev/null | grep -qw libvirt && printf '' || printf 'sudo')}"
NIX="${NIX:-${HOST_CMD:+$HOST_CMD }nix}"
SSH="${SSH:-${HOST_CMD:+$HOST_CMD }ssh}"
READLINK="${READLINK:-${HOST_CMD:+$HOST_CMD }readlink}"
CP="${CP:-${HOST_CMD:+$HOST_CMD }cp}"
OUTPUT_DIR="${OUTPUT_DIR:-output}"
MACHINES_DIR="${MACHINES_DIR:-machines}"

# Build a profile's base image
build_profile() {
    local profile="${1:-core}"
    echo "Building profile: $profile"
    mkdir -p "$OUTPUT_DIR/profiles"
    $NIX build ".#${profile}" --out-link "$OUTPUT_DIR/profiles/$profile"
    echo "Built: $OUTPUT_DIR/profiles/$profile"
}

# Build all profiles
build_all() {
    echo "Building all profiles..."
    build_profile base
    build_profile core
    build_profile docker
    build_profile dev
    build_profile claude
    echo "All profiles built."
}

# List available profiles
list_profiles() {
    echo "Available profiles:"
    ls -1 profiles/*.nix 2>/dev/null | xargs -I{} basename {} .nix || echo "(none)"
}

# Initialize machine config directory (creates identity files if not present)
init_machine() {
    local name="$1"
    local profile="${2:-core}"
    local network="${3:-nat}"
    local machine_dir="$MACHINES_DIR/$name"
    mkdir -p "$machine_dir"

    # Set profile (only if not present, unless explicitly overridden)
    if [ ! -f "$machine_dir/profile" ]; then
        echo "$profile" > "$machine_dir/profile"
        echo "Created: $machine_dir/profile ($profile)"
    elif [ "$profile" != "base" ]; then
        echo "$profile" > "$machine_dir/profile"
        echo "Updated: $machine_dir/profile ($profile)"
    else
        echo "Using existing profile: $(cat "$machine_dir/profile")"
    fi

    # Set network configuration (default: nat)
    if [ ! -f "$machine_dir/network" ]; then
        network_config "$name" "$network"
    elif [ "$network" != "nat" ]; then
        network_config "$name" "$network"
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
        echo "$name" > "$machine_dir/hostname"
        echo "Created: $machine_dir/hostname"
    fi

    # Prompt for admin authorized_keys if not present
    if [ ! -f "$machine_dir/admin_authorized_keys" ]; then
        echo ""
        echo "Enter SSH public key(s) for 'admin' (has sudo access):"
        echo "(Paste key, then press Enter, then Ctrl+D. Leave empty and press Ctrl+D to skip)"
        printf '%s\n' "# SSH authorized_keys for 'admin' user (has sudo access)" "# Add one public key per line. Run 'just upgrade $name' to apply changes." "" > "$machine_dir/admin_authorized_keys"
        cat >> "$machine_dir/admin_authorized_keys" || true
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
        printf '%s\n' "# SSH authorized_keys for 'user' account (no sudo access)" "# Add one public key per line. Run 'just upgrade $name' to apply changes." "" > "$machine_dir/user_authorized_keys"
        cat >> "$machine_dir/user_authorized_keys" || true
        if [ "$(grep -cv '^#\|^$' "$machine_dir/user_authorized_keys")" -gt 0 ]; then
            echo "Saved: $machine_dir/user_authorized_keys"
        else
            echo "No user authorized_keys configured (user SSH login will be disabled)"
        fi
    fi

    # Create default tcp_ports if not present
    if [ ! -f "$machine_dir/tcp_ports" ]; then
        printf '%s\n' "# TCP ports to open in firewall (one per line)" "# Run 'just upgrade $name' to apply changes." "22" "80" "443" > "$machine_dir/tcp_ports"
        echo "Created: $machine_dir/tcp_ports (22, 80, 443)"
    fi

    # Create default udp_ports if not present
    if [ ! -f "$machine_dir/udp_ports" ]; then
        printf '%s\n' "# UDP ports to open in firewall (one per line)" "# Run 'just upgrade $name' to apply changes." > "$machine_dir/udp_ports"
        echo "Created: $machine_dir/udp_ports (empty)"
    fi

    # Create default resolv.conf if not present
    if [ ! -f "$machine_dir/resolv.conf" ]; then
        printf '%s\n' "# DNS configuration. Run 'just upgrade $name' to apply changes." "nameserver 1.1.1.1" "nameserver 1.0.0.1" > "$machine_dir/resolv.conf"
        echo "Created: $machine_dir/resolv.conf (Cloudflare DNS)"
    fi

    echo "Machine config ready: $machine_dir/"
}

# Initialize machine config for clone (non-interactive, copies from source)
init_machine_clone() {
    local source="$1"
    local dest="$2"
    local network="${3:-}"
    local source_dir="$MACHINES_DIR/$source"
    local dest_dir="$MACHINES_DIR/$dest"
    mkdir -p "$dest_dir"

    # Copy config files from source
    for f in admin_authorized_keys user_authorized_keys tcp_ports udp_ports resolv.conf hosts root_password_hash profile; do
        if [ -f "$source_dir/$f" ]; then
            cp "$source_dir/$f" "$dest_dir/$f"
        fi
    done

    # Handle network: copy from source or use override
    if [ -n "$network" ]; then
        if [ "$network" = "bridge" ] && [ -f "$source_dir/network" ]; then
            source_net=$(cat "$source_dir/network")
            if [[ "$source_net" == bridge:* ]]; then
                echo "$source_net" > "$dest_dir/network"
            else
                echo "bridge:br0" > "$dest_dir/network"
            fi
        else
            echo "$network" > "$dest_dir/network"
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

    echo "$dest" > "$dest_dir/hostname"
    echo "Created: $dest_dir/hostname"

    # Preserve permissions on sensitive files
    if [ -f "$dest_dir/root_password_hash" ]; then
        chmod 600 "$dest_dir/root_password_hash"
    fi

    echo "Machine config ready: $dest_dir/ (cloned from $source)"
}

# Set network configuration for a machine (non-interactive for nat, interactive bridge selection)
network_config() {
    local name="$1"
    local network="$2"
    local machine_dir="$MACHINES_DIR/$name"
    mkdir -p "$machine_dir"

    if [[ "$network" == "nat" ]]; then
        echo "nat" > "$machine_dir/network"
        echo "Network configured: nat"
    elif [[ "$network" == bridge:* ]]; then
        # Direct bridge specification (e.g., bridge:vmbr0, bridge:br0)
        echo "$network" > "$machine_dir/network"
        echo "Network configured: $network"
    elif [[ "$network" == "bridge" ]]; then
        # Interactive bridge selection (lists local bridges)
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
        local i=1
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
        local selected_bridge="${bridges[$((selection-1))]}"
        echo "bridge:$selected_bridge" > "$machine_dir/network"
        echo "Network configured: bridge:$selected_bridge"
    else
        echo "Error: Invalid network config '$network'. Use 'nat', 'bridge', or 'bridge:<name>'"
        exit 1
    fi
}

# Interactive network configuration (shows current, prompts for mode)
network_config_interactive() {
    local name="$1"
    local network="${2:-}"
    local machine_dir="$MACHINES_DIR/$name"

    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        echo "Create the VM first with 'just create $name'"
        exit 1
    fi

    local current
    current=$(cat "$machine_dir/network" 2>/dev/null || echo "nat")

    if [ -z "$network" ]; then
        echo "Current network config: $current"
        echo ""
        echo "Select network mode:"
        echo "  1) nat - NAT networking via libvirt (default)"
        echo "  2) bridge - Bridged networking to physical network"
        echo ""
        read -p "Selection [1-2]: " mode_selection
        case "$mode_selection" in
            1) network="nat" ;;
            2) network="bridge" ;;
            *) echo "Invalid selection."; exit 1 ;;
        esac
    fi

    network_config "$name" "$network"
}

# Set or clear the root password for a VM
set_password() {
    local name="$1"
    local machine_dir="$MACHINES_DIR/$name"

    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        exit 1
    fi
    echo "Set root password for VM '$name'"
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
        local hash
        hash=$(printf '%s' "$password" | $NIX run nixpkgs#mkpasswd -- -m sha-512 --stdin)
        echo -n "$hash" > "$machine_dir/root_password_hash"
        echo "Root password hash saved."
    fi
    chmod 600 "$machine_dir/root_password_hash"
    echo "Run 'just upgrade $name' to apply."
}

# List all machine configs
list_machines() {
    echo "Machine configs in $MACHINES_DIR/:"
    shopt -s nullglob
    local found=0
    for dir in "$MACHINES_DIR"/*/; do
        if [ -d "$dir" ]; then
            local name
            name=$(basename "$dir")
            local profile
            profile=$(cat "$dir/profile" 2>/dev/null || echo "unknown")
            echo "  $name (profile: $profile)"
            found=1
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo "  (none)"
    fi
}


# Stop a VM gracefully, aborting if timeout is reached
# Requires backend_stop and backend_is_running to be defined
stop_graceful() {
    local name="$1"
    local timeout="${2:-60}"  # default 60 seconds

    if ! backend_is_running "$name"; then
        return 0
    fi

    echo "Attempting graceful shutdown (${timeout}s timeout)..."
    backend_stop "$name" 2>/dev/null || true

    local waited=0
    while backend_is_running "$name" && [ $waited -lt $timeout ]; do
        sleep 1
        waited=$((waited + 1))
    done

    if backend_is_running "$name"; then
        echo "Error: Graceful shutdown timed out after ${timeout}s."
        echo "VM is still running. Use 'just force-stop $name' to force stop, then retry."
        exit 1
    fi

    echo "VM stopped gracefully."
}

# Clean built images and VM disks (keeps machine configs)
clean() {
    rm -rf "$OUTPUT_DIR"
    echo "Cleaned $OUTPUT_DIR/"
}

# Enter development shell
dev_shell() {
    $NIX develop
}
