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

# Normalize profile list: sort, dedupe, ensure core is included
# Input: comma-separated profiles (e.g., "docker,python,rust")
# Output: canonical sorted list with core (e.g., "core,docker,python,rust")
normalize_profiles() {
    local profiles="${1:-core}"
    local normalized
    normalized=$(echo "$profiles" | tr ',' '\n' | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')
    if [[ ! ",$normalized," =~ ,core, ]]; then
        normalized="core,$normalized"
    fi
    echo "$normalized"
}

# Check if a machine is configured for mutable mode
# Returns 0 (true) if machines/{name}/mutable contains "true"
is_mutable() {
    local name="$1"
    local mutable_file="$MACHINES_DIR/$name/mutable"
    if [ -f "$mutable_file" ]; then
        local content
        content=$(cat "$mutable_file" 2>/dev/null | tr -d '[:space:]')
        [ "$content" = "true" ]
    else
        return 1
    fi
}

# Check if a machine has pipewire audio enabled
# Returns 0 (true) if "pipewire" is in the machine's profile list
is_pipewire() {
    local name="$1"
    local profile_file="$MACHINES_DIR/$name/profile"
    if [ -f "$profile_file" ]; then
        local profiles
        profiles=$(cat "$profile_file" 2>/dev/null)
        [[ ",$profiles," == *",pipewire,"* ]]
    else
        return 1
    fi
}

# Build a profile's base image (supports comma-separated profile combinations)
# Usage: build_profile <profiles> [mutable]
# If mutable=true, builds a mutable (read-write) image
build_profile() {
    local profiles="${1:-core}"
    local mutable="${2:-false}"

    # Normalize to canonical profile key
    local profile_key
    profile_key=$(normalize_profiles "$profiles")

    # Add mutable suffix for mutable images
    local output_key="$profile_key"
    if [ "$mutable" = "true" ]; then
        output_key="${profile_key}-mutable"
        echo "Building mutable profile: $profile_key"
    else
        echo "Building immutable profile: $profile_key"
    fi
    mkdir -p "$OUTPUT_DIR/profiles"

    # Convert comma-separated to nix list format: "docker,python" -> '["docker" "python"]'
    local nix_list
    nix_list=$(echo "$profile_key" | sed 's/,/" "/g' | sed 's/^/["/;s/$/"]/')

    $NIX build --impure --expr "
      let flake = builtins.getFlake \"$SCRIPT_DIR\";
      in flake.lib.mkCombinedImage \"x86_64-linux\" $nix_list { mutable = $mutable; }
    " --out-link "$OUTPUT_DIR/profiles/$output_key"

    echo "Built: $OUTPUT_DIR/profiles/$output_key"
}

# Build all base profiles
build_all() {
    echo "Building all base profiles..."
    build_profile core
    build_profile docker
    build_profile podman
    build_profile dev
    build_profile claude
    build_profile open-code
    echo "All base profiles built."
}

# List available profiles
list_profiles() {
    echo "Available profiles:"
    ls -1 profiles/*.nix 2>/dev/null | xargs -I{} basename {} .nix || echo "(none)"
}

# Initialize machine config directory (creates identity files if not present)
# Optional 4th arg: ssh_key_mode - "agent" to use ssh-add keys, "skip" to skip SSH prompts
# Optional 5th arg: admin_keys - pre-set admin SSH keys (newline-separated)
# Optional 6th arg: user_keys - pre-set user SSH keys (newline-separated)
init_machine() {
    local name="$1"
    local profile="${2:-core}"
    local network="${3:-nat}"
    local ssh_key_mode="${4:-}"
    local admin_keys="${5:-}"
    local user_keys="${6:-}"
    local machine_dir="$MACHINES_DIR/$name"
    mkdir -p "$machine_dir"

    # Normalize profile to canonical form (sorted, with core)
    local normalized_profile
    normalized_profile=$(normalize_profiles "$profile")

    # Set profile (only if not present, unless explicitly overridden)
    if [ ! -f "$machine_dir/profile" ]; then
        echo "$normalized_profile" > "$machine_dir/profile"
        echo "Created: $machine_dir/profile ($normalized_profile)"
    elif [ "$profile" != "core" ]; then
        echo "$normalized_profile" > "$machine_dir/profile"
        echo "Updated: $machine_dir/profile ($normalized_profile)"
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

    # Handle admin authorized_keys
    if [ ! -f "$machine_dir/admin_authorized_keys" ]; then
        printf '%s\n' "# SSH authorized_keys for 'admin' user (has sudo access)" "# Add one public key per line. Run 'just upgrade $name' to apply changes." "" > "$machine_dir/admin_authorized_keys"

        if [ -n "$admin_keys" ]; then
            # Pre-set keys provided
            echo "$admin_keys" >> "$machine_dir/admin_authorized_keys"
            echo "Saved: $machine_dir/admin_authorized_keys"
        elif [ "$ssh_key_mode" = "agent" ]; then
            # Use keys from SSH agent
            if ssh-add -L 2>/dev/null >> "$machine_dir/admin_authorized_keys"; then
                echo "Saved: $machine_dir/admin_authorized_keys (from SSH agent)"
            else
                echo "Warning: No keys in SSH agent, admin SSH login will be disabled"
            fi
        elif [ "$ssh_key_mode" = "skip" ]; then
            echo "No admin authorized_keys configured (admin SSH login will be disabled)"
        else
            # Interactive prompt (original behavior)
            echo ""
            echo "Enter SSH public key(s) for 'admin' (has sudo access):"
            echo "(Paste key, then press Enter, then Ctrl+D. Leave empty and press Ctrl+D to skip)"
            cat >> "$machine_dir/admin_authorized_keys" || true
            if [ "$(grep -cv '^#\|^$' "$machine_dir/admin_authorized_keys")" -gt 0 ]; then
                echo "Saved: $machine_dir/admin_authorized_keys"
            else
                echo "No admin authorized_keys configured (admin SSH login will be disabled)"
            fi
        fi
    fi

    # Handle user authorized_keys
    if [ ! -f "$machine_dir/user_authorized_keys" ]; then
        printf '%s\n' "# SSH authorized_keys for 'user' account (no sudo access)" "# Add one public key per line. Run 'just upgrade $name' to apply changes." "" > "$machine_dir/user_authorized_keys"

        if [ -n "$user_keys" ]; then
            # Pre-set keys provided
            echo "$user_keys" >> "$machine_dir/user_authorized_keys"
            echo "Saved: $machine_dir/user_authorized_keys"
        elif [ "$ssh_key_mode" = "agent" ]; then
            # Use keys from SSH agent
            if ssh-add -L 2>/dev/null >> "$machine_dir/user_authorized_keys"; then
                echo "Saved: $machine_dir/user_authorized_keys (from SSH agent)"
            else
                echo "Warning: No keys in SSH agent, user SSH login will be disabled"
            fi
        elif [ "$ssh_key_mode" = "skip" ]; then
            echo "No user authorized_keys configured (user SSH login will be disabled)"
        else
            # Interactive prompt (original behavior)
            echo ""
            echo "Enter SSH public key(s) for 'user' (no sudo access):"
            echo "(Paste key, then press Enter, then Ctrl+D. Leave empty and press Ctrl+D to skip)"
            cat >> "$machine_dir/user_authorized_keys" || true
            if [ "$(grep -cv '^#\|^$' "$machine_dir/user_authorized_keys")" -gt 0 ]; then
                echo "Saved: $machine_dir/user_authorized_keys"
            else
                echo "No user authorized_keys configured (user SSH login will be disabled)"
            fi
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

    # Copy config files from source (including mutable flag)
    for f in admin_authorized_keys user_authorized_keys tcp_ports udp_ports resolv.conf hosts root_password_hash profile mutable; do
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

# Set or clear the mutable flag for a VM
set_mutable() {
    local name="$1"
    local machine_dir="$MACHINES_DIR/$name"

    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        exit 1
    fi

    local current_status="disabled"
    if is_mutable "$name"; then
        current_status="enabled"
    fi

    echo "Configure mutable mode for VM '$name'"
    echo ""
    echo "Current status: $current_status"
    echo ""
    echo "Mutable VMs have a single read-write disk with full nix toolchain."
    echo "They cannot be upgraded with 'just upgrade' - use nixos-rebuild inside the VM."
    echo ""
    read -p "Enable mutable mode? [y/N] " confirm
    if [[ "$confirm" == [yY] || "$confirm" == [yY][eE][sS] ]]; then
        echo "true" > "$machine_dir/mutable"
        echo "Mutable mode enabled."
    else
        rm -f "$machine_dir/mutable"
        echo "Mutable mode disabled."
    fi
    echo ""
    echo "Run 'just recreate $name' to apply the change."
}

# Configure a VM (creates machine config without creating the VM)
# This is the configuration-only step that can be called separately from create
config_vm() {
    local name="$1"
    local profile="${2:-core}"
    local memory="${3:-2048}"
    local vcpus="${4:-2}"
    local var_size
    var_size=$(normalize_size "${5:-30G}")
    local network="${6:-nat}"

    # Initialize machine config (creates identity files, prompts for SSH keys)
    init_machine "$name" "$profile" "$network"

    local machine_dir="$MACHINES_DIR/$name"

    # Save resource configuration (only if not present, or if explicitly set to non-default)
    if [ ! -f "$machine_dir/memory" ]; then
        echo "$memory" > "$machine_dir/memory"
        echo "Created: $machine_dir/memory (${memory}M)"
    elif [ "$memory" != "2048" ]; then
        echo "$memory" > "$machine_dir/memory"
        echo "Updated: $machine_dir/memory (${memory}M)"
    else
        memory=$(cat "$machine_dir/memory")
        echo "Using existing memory: ${memory}M"
    fi

    if [ ! -f "$machine_dir/vcpus" ]; then
        echo "$vcpus" > "$machine_dir/vcpus"
        echo "Created: $machine_dir/vcpus ($vcpus)"
    elif [ "$vcpus" != "2" ]; then
        echo "$vcpus" > "$machine_dir/vcpus"
        echo "Updated: $machine_dir/vcpus ($vcpus)"
    else
        vcpus=$(cat "$machine_dir/vcpus")
        echo "Using existing vcpus: $vcpus"
    fi

    if [ ! -f "$machine_dir/var_size" ]; then
        echo "$var_size" > "$machine_dir/var_size"
        echo "Created: $machine_dir/var_size ($var_size)"
    elif [ "$var_size" != "30G" ]; then
        echo "$var_size" > "$machine_dir/var_size"
        echo "Updated: $machine_dir/var_size ($var_size)"
    else
        var_size=$(cat "$machine_dir/var_size")
        echo "Using existing var_size: $var_size"
    fi

    echo ""
    echo "VM '$name' configured (profile: $(cat "$machine_dir/profile"), memory: ${memory}M, vcpus: $vcpus, var: $var_size)"
    echo "To create the VM, run: just create $name"
}

# Interactive VM configuration using script-wizard
# All arguments are optional - will prompt for everything interactively
# Set from_create=true when calling from create_vm to skip "run just create" message
config_vm_interactive() {
    local name="${1:-}"
    local profile="${2:-}"
    local from_create="${3:-false}"

    # Determine how to run script-wizard
    local SCRIPT_WIZARD=""
    if command -v script-wizard &>/dev/null; then
        SCRIPT_WIZARD="script-wizard"
    elif command -v nix &>/dev/null && nix --version 2>&1 | grep -q "nix"; then
        # Check if flakes are supported
        if nix flake --help &>/dev/null; then
            SCRIPT_WIZARD="nix run github:enigmacurry/script-wizard --"
            echo "Using script-wizard via nix flakes..."
        fi
    fi

    if [ -z "$SCRIPT_WIZARD" ]; then
        echo "Error: script-wizard is not installed."
        echo ""
        echo "Install it from: https://github.com/enigmacurry/script-wizard"
        echo ""
        echo "Or if you have Nix with flakes enabled, it will be used automatically."
        exit 1
    fi

    # Prompt for VM name if not provided
    if [ -z "$name" ]; then
        name=$($SCRIPT_WIZARD ask "Enter VM name:")
        if [ -z "$name" ]; then
            echo "Error: VM name is required."
            exit 1
        fi
    fi

    # Check if machine config already exists and load current values
    local machine_dir="$MACHINES_DIR/$name"
    local current_profile="" current_memory="" current_vcpus="" current_var_size="" current_network="" current_mutable=""
    local is_reconfigure=false

    if [ -d "$machine_dir" ]; then
        echo "Machine config already exists: $machine_dir"
        if ! $SCRIPT_WIZARD confirm "Reconfigure this VM?" no; then
            if [ "$from_create" = "true" ]; then
                echo "Using existing config."
                return 0
            fi
            echo "Aborted."
            exit 0
        fi
        is_reconfigure=true
        # Load current values (trim whitespace for simple values)
        current_profile=$(cat "$machine_dir/profile" 2>/dev/null || true)
        current_profile="${current_profile%"${current_profile##*[![:space:]]}"}"  # trim trailing
        current_profile="${current_profile#"${current_profile%%[![:space:]]*}"}"  # trim leading
        current_memory=$(cat "$machine_dir/memory" 2>/dev/null | tr -d '[:space:]' || true)
        current_vcpus=$(cat "$machine_dir/vcpus" 2>/dev/null | tr -d '[:space:]' || true)
        current_var_size=$(cat "$machine_dir/var_size" 2>/dev/null | tr -d '[:space:]' || true)
        current_network=$(cat "$machine_dir/network" 2>/dev/null || true)
        current_network="${current_network%"${current_network##*[![:space:]]}"}"  # trim trailing
        current_network="${current_network#"${current_network%%[![:space:]]*}"}"  # trim leading
        current_mutable=$(cat "$machine_dir/mutable" 2>/dev/null | tr -d '[:space:]' || true)
    fi

    # Mutable mode selection: options are "Immutable" "Mutable" (indices 0-1)
    echo ""
    local mutable_choice mutable_default_idx="0"
    if [ "$current_mutable" = "true" ]; then
        mutable_default_idx="1"
    fi
    mutable_choice=$($SCRIPT_WIZARD choose -d "$mutable_default_idx" "Select VM mode:" "Immutable (read-only root, upgradeable, recommended)" "Mutable (read-write pet VM, use nixos-rebuild)")
    local is_mutable_vm=false
    if [[ "$mutable_choice" == "Mutable"* ]]; then
        is_mutable_vm=true
    fi
    echo "Mode: $mutable_choice"

    # Get list of available profiles (excluding core, which is always included)
    local available_profiles=()
    shopt -s nullglob
    for f in profiles/*.nix; do
        local pname
        pname=$(basename "$f" .nix)
        if [ "$pname" != "core" ]; then
            available_profiles+=("$pname")
        fi
    done
    shopt -u nullglob

    # Prompt for profile(s) if not provided
    if [ -z "$profile" ]; then
        echo ""
        local profile_default_arg=""
        if [ -n "$current_profile" ]; then
            # Convert comma-separated profile to JSON array, excluding core: "core,docker" -> '["docker"]'
            local profile_without_core profile_json
            profile_without_core=$(echo "$current_profile" | tr ',' '\n' | grep -v '^core$' | tr '\n' ',' | sed 's/,$//')
            if [ -n "$profile_without_core" ]; then
                profile_json=$(echo "$profile_without_core" | sed 's/,/","/g' | sed 's/^/["/;s/$/"]/')
                profile_default_arg="--default $profile_json"
            fi
        fi
        readarray -t selected_profiles < <($SCRIPT_WIZARD select $profile_default_arg "Select profile(s) to include:" "${available_profiles[@]}")
        if [ ${#selected_profiles[@]} -eq 0 ]; then
            profile="core"
        else
            profile=$(IFS=,; echo "${selected_profiles[*]}")
        fi
    fi
    echo "Selected profile(s): $profile"

    # Memory: options are "1G" "2G" "4G" "8G" "16G" "32G" "Custom" (indices 0-6)
    echo ""
    local memory_choice memory_default_idx=""
    if [ -n "$current_memory" ]; then
        case "$current_memory" in
            "1024") memory_default_idx="0" ;;
            "2048") memory_default_idx="1" ;;
            "4096") memory_default_idx="2" ;;
            "8192") memory_default_idx="3" ;;
            "16384") memory_default_idx="4" ;;
            "32768") memory_default_idx="5" ;;
            *) memory_default_idx="6" ;;  # Custom
        esac
    fi
    if [ -n "$memory_default_idx" ]; then
        memory_choice=$($SCRIPT_WIZARD choose -d "$memory_default_idx" "Select memory size:" "1G" "2G" "4G" "8G" "16G" "32G" "Custom")
    else
        memory_choice=$($SCRIPT_WIZARD choose "Select memory size:" "1G" "2G" "4G" "8G" "16G" "32G" "Custom")
    fi
    case "$memory_choice" in
        "1G") memory="1024" ;;
        "2G") memory="2048" ;;
        "4G") memory="4096" ;;
        "8G") memory="8192" ;;
        "16G") memory="16384" ;;
        "32G") memory="32768" ;;
        "Custom")
            local custom_mem
            custom_mem=$($SCRIPT_WIZARD ask "Enter memory in MB (e.g., 3072):" "$current_memory")
            memory="${custom_mem:-2048}"
            ;;
        *) memory="2048" ;;
    esac
    echo "Memory: ${memory}M"

    # vCPU selection
    echo ""
    # vCPUs: options are "1" "2" "4" "8" "Custom" (indices 0-4)
    local vcpu_choice vcpu_default_idx=""
    if [ -n "$current_vcpus" ]; then
        case "$current_vcpus" in
            "1") vcpu_default_idx="0" ;;
            "2") vcpu_default_idx="1" ;;
            "4") vcpu_default_idx="2" ;;
            "8") vcpu_default_idx="3" ;;
            *) vcpu_default_idx="4" ;;  # Custom
        esac
    fi
    if [ -n "$vcpu_default_idx" ]; then
        vcpu_choice=$($SCRIPT_WIZARD choose -d "$vcpu_default_idx" "Select number of vCPUs:" "1" "2" "4" "8" "Custom")
    else
        vcpu_choice=$($SCRIPT_WIZARD choose "Select number of vCPUs:" "1" "2" "4" "8" "Custom")
    fi
    case "$vcpu_choice" in
        "1") vcpus="1" ;;
        "2") vcpus="2" ;;
        "4") vcpus="4" ;;
        "8") vcpus="8" ;;
        "Custom")
            local custom_vcpus
            custom_vcpus=$($SCRIPT_WIZARD ask "Enter number of vCPUs:" "$current_vcpus")
            vcpus="${custom_vcpus:-2}"
            ;;
        *) vcpus="2" ;;
    esac
    echo "vCPUs: $vcpus"

    # Disk: options are "20G" "30G" "50G" "100G" "200G" "500G" "Custom" (indices 0-6)
    echo ""
    local disk_choice disk_default_idx=""
    if [ -n "$current_var_size" ]; then
        case "$current_var_size" in
            "20G") disk_default_idx="0" ;;
            "30G") disk_default_idx="1" ;;
            "50G") disk_default_idx="2" ;;
            "100G") disk_default_idx="3" ;;
            "200G") disk_default_idx="4" ;;
            "500G") disk_default_idx="5" ;;
            *) disk_default_idx="6" ;;  # Custom
        esac
    fi
    if [ -n "$disk_default_idx" ]; then
        disk_choice=$($SCRIPT_WIZARD choose -d "$disk_default_idx" "Select /var disk size:" "20G" "30G" "50G" "100G" "200G" "500G" "Custom")
    else
        disk_choice=$($SCRIPT_WIZARD choose "Select /var disk size:" "20G" "30G" "50G" "100G" "200G" "500G" "Custom")
    fi
    case "$disk_choice" in
        "20G") var_size="20G" ;;
        "30G") var_size="30G" ;;
        "50G") var_size="50G" ;;
        "100G") var_size="100G" ;;
        "200G") var_size="200G" ;;
        "500G") var_size="500G" ;;
        "Custom")
            local custom_size
            custom_size=$($SCRIPT_WIZARD ask "Enter disk size (e.g., 40G):" "$current_var_size")
            var_size="${custom_size:-30G}"
            ;;
        *) var_size="30G" ;;
    esac
    echo "Disk size: $var_size"

    # Network: options are "NAT" "Bridge" (indices 0-1)
    echo ""
    local network_choice network_default_idx=""
    if [ -n "$current_network" ]; then
        case "$current_network" in
            "nat") network_default_idx="0" ;;
            bridge*) network_default_idx="1" ;;
        esac
    fi
    if [ -n "$network_default_idx" ]; then
        network_choice=$($SCRIPT_WIZARD choose -d "$network_default_idx" "Select network mode:" "NAT" "Bridge")
    else
        network_choice=$($SCRIPT_WIZARD choose "Select network mode:" "NAT" "Bridge")
    fi
    case "$network_choice" in
        "NAT") network="nat" ;;
        "Bridge") network="bridge" ;;
        *) network="nat" ;;
    esac
    echo "Network: $network"

    # SSH keys selection
    echo ""
    local ssh_key_mode=""
    local admin_keys=""
    local user_keys=""

    # Check if SSH agent has keys
    local agent_key_count=0
    if ssh-add -L &>/dev/null; then
        agent_key_count=$(ssh-add -L 2>/dev/null | wc -l)
    fi

    # Check if existing keys are configured
    local has_existing_keys=false
    if [ "$is_reconfigure" = true ] && [ -f "$machine_dir/admin_authorized_keys" ]; then
        local existing_key_count
        existing_key_count=$(grep -cv '^#\|^$' "$machine_dir/admin_authorized_keys" 2>/dev/null || echo "0")
        if [ "$existing_key_count" -gt 0 ]; then
            has_existing_keys=true
        fi
    fi

    if [ "$has_existing_keys" = true ]; then
        local ssh_choice
        if [ "$agent_key_count" -gt 0 ]; then
            ssh_choice=$($SCRIPT_WIZARD choose --default "Keep existing keys" "SSH authorized keys:" "Keep existing keys" "Use current SSH agent keys ($agent_key_count key(s))" "Enter keys manually" "Skip (no SSH access)")
        else
            ssh_choice=$($SCRIPT_WIZARD choose --default "Keep existing keys" "SSH authorized keys:" "Keep existing keys" "Enter keys manually" "Skip (no SSH access)")
        fi
        case "$ssh_choice" in
            "Keep existing keys"*) ssh_key_mode="keep" ;;
            "Use current SSH agent keys"*) ssh_key_mode="agent" ;;
            "Enter keys manually") ssh_key_mode="manual" ;;
            "Skip"*) ssh_key_mode="skip" ;;
            *) ssh_key_mode="keep" ;;
        esac
    elif [ "$agent_key_count" -gt 0 ]; then
        local ssh_choice
        ssh_choice=$($SCRIPT_WIZARD choose "SSH authorized keys:" "Use current SSH agent keys ($agent_key_count key(s))" "Enter keys manually" "Skip (no SSH access)")
        case "$ssh_choice" in
            "Use current SSH agent keys"*) ssh_key_mode="agent" ;;
            "Enter keys manually") ssh_key_mode="manual" ;;
            "Skip"*) ssh_key_mode="skip" ;;
            *) ssh_key_mode="agent" ;;
        esac
    else
        local ssh_choice
        ssh_choice=$($SCRIPT_WIZARD choose "SSH authorized keys:" "Enter keys manually" "Skip (no SSH access)")
        case "$ssh_choice" in
            "Enter keys manually"*) ssh_key_mode="manual" ;;
            "Skip"*) ssh_key_mode="skip" ;;
            *) ssh_key_mode="manual" ;;
        esac
    fi

    if [ "$ssh_key_mode" = "manual" ]; then
        echo ""
        echo "Enter SSH public key(s) for 'admin' (has sudo access):"
        admin_keys=$($SCRIPT_WIZARD editor "Enter admin SSH public keys (one per line)" --default "# Paste your public key(s) here, one per line")
        # Remove comment lines
        admin_keys=$(echo "$admin_keys" | grep -v '^#' | grep -v '^$' || true)

        echo ""
        local same_keys
        same_keys=$($SCRIPT_WIZARD choose "User account SSH keys:" "Same as admin" "Enter different keys" "No user SSH access")
        case "$same_keys" in
            "Same as admin"*) user_keys="$admin_keys" ;;
            "Enter different keys")
                echo ""
                echo "Enter SSH public key(s) for 'user' (no sudo access):"
                user_keys=$($SCRIPT_WIZARD editor "Enter user SSH public keys (one per line)" --default "# Paste your public key(s) here, one per line")
                user_keys=$(echo "$user_keys" | grep -v '^#' | grep -v '^$' || true)
                ;;
            *) user_keys="" ;;
        esac
    fi

    echo ""
    echo "Configuration summary:"
    echo "  Name:    $name"
    echo "  Mode:    $([ "$is_mutable_vm" = true ] && echo "mutable" || echo "immutable")"
    echo "  Profile: $profile"
    echo "  Memory:  ${memory}M"
    echo "  vCPUs:   $vcpus"
    echo "  Disk:    $var_size"
    echo "  Network: $network"
    echo "  SSH:     $ssh_key_mode"
    echo ""

    if ! $SCRIPT_WIZARD confirm "Create this configuration?" yes; then
        echo "Aborted."
        exit 0
    fi

    # Initialize machine with collected values
    if [ "$ssh_key_mode" = "keep" ]; then
        # Keep existing keys - just update other settings
        init_machine "$name" "$profile" "$network" "skip"
    elif [ "$ssh_key_mode" = "manual" ]; then
        init_machine "$name" "$profile" "$network" "" "$admin_keys" "$user_keys"
    else
        init_machine "$name" "$profile" "$network" "$ssh_key_mode"
    fi

    # Save resource configuration
    echo "$memory" > "$machine_dir/memory"
    echo "Created: $machine_dir/memory (${memory}M)"

    echo "$vcpus" > "$machine_dir/vcpus"
    echo "Created: $machine_dir/vcpus ($vcpus)"

    local normalized_var_size
    normalized_var_size=$(normalize_size "$var_size")
    echo "$normalized_var_size" > "$machine_dir/var_size"
    echo "Created: $machine_dir/var_size ($normalized_var_size)"

    # Save mutable mode
    if [ "$is_mutable_vm" = true ]; then
        echo "true" > "$machine_dir/mutable"
        echo "Created: $machine_dir/mutable (true)"
    else
        rm -f "$machine_dir/mutable"
        echo "Removed: $machine_dir/mutable (immutable mode)"
    fi

    echo ""
    local mode_str="immutable"
    if [ "$is_mutable_vm" = true ]; then
        mode_str="mutable"
    fi
    echo "VM '$name' configured (profile: $(cat "$machine_dir/profile"), mode: $mode_str, memory: ${memory}M, vcpus: $vcpus, var: $normalized_var_size)"
    if [ "$from_create" != "true" ]; then
        echo "To create the VM, run: just create $name"
    fi
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
            local mode="immutable"
            if is_mutable "$name"; then
                mode="mutable"
            fi
            echo "  $name (profile: $profile, $mode)"
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

# Generate flake.nix content for mutable VMs
# Usage: generate_mutable_flake <hostname> <system> <profile>
# Outputs flake.nix content to stdout
generate_mutable_flake() {
    local hostname="$1"
    local system="$2"
    local profile="$3"

    # Build profile imports
    local profile_imports=""
    IFS=',' read -ra profile_parts <<< "$profile"
    for p in "${profile_parts[@]}"; do
        profile_imports="$profile_imports          ./profiles/${p}.nix"$'\n'
    done

    cat << FLAKE_EOF
{
  description = "NixOS VM configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sway-home = {
      url = "github:EnigmaCurry/sway-home?dir=home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-flatpak.url = "github:gmodena/nix-flatpak";
  };

  outputs = { self, nixpkgs, home-manager, sway-home, nix-flatpak, ... }:
    {
      nixosConfigurations."$hostname" = nixpkgs.lib.nixosSystem {
        system = "$system";
        specialArgs = {
          inherit sway-home nix-flatpak;
          swayHomeInputs = sway-home.inputs;
        };
        modules = [
          # Core modules (see modules/default.nix)
          ./modules
          home-manager.nixosModules.home-manager
          # Profile modules
$profile_imports          # VM-specific settings
          {
            vm.mutable = true;
            networking.hostName = "$hostname";
          }
        ];
      };
    };
}
FLAKE_EOF
}

# Enter development shell
dev_shell() {
    $NIX develop
}
