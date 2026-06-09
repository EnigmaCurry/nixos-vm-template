# NixOS Immutable VM Image Builder

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load
set export

BACKEND := env_var_or_default("BACKEND", "libvirt")
backend_script := if BACKEND == "common" { error("BACKEND cannot be 'common'") } else { "backends/" + BACKEND + ".sh" }

# Default recipe - show available commands
[private]
default:
    @just --list

# Build a profile image (supports comma-separated profiles, e.g., docker,python)
build profiles="core":
    @source {{backend_script}} && build_profile "{{profiles}}"

# Build all profiles
build-all:
    @source {{backend_script}} && build_all

# Export a profile image with release metadata filename
export profiles="core":
    @source {{backend_script}} && export_profile "{{profiles}}"

# List available profiles
list-profiles:
    @source {{backend_script}} && list_profiles

# Configure a VM interactively using script-wizard (or non-interactively with all args)
config name="" profile="":
    @source {{backend_script}} && config_vm_interactive "{{name}}" "{{profile}}"

# Configure a VM non-interactively with explicit values
config-batch new_name profiles="core" memory="2048" vcpus="2" var_size="30G" network="nat" static_ip="":
    @source {{backend_script}} && config_vm "{{new_name}}" "{{profiles}}" "{{memory}}" "{{vcpus}}" "{{var_size}}" "{{network}}" "{{static_ip}}"

# Create a new VM interactively (prompts for all settings)
create name:
    @source {{backend_script}} && create_vm "{{name}}"

# Create a new VM non-interactively with explicit values
create-batch name profiles="core" memory="2048" vcpus="2" var_size="30G" network="nat" static_ip="":
    @source {{backend_script}} && create_vm_batch "{{name}}" "{{profiles}}" "{{memory}}" "{{vcpus}}" "{{var_size}}" "{{network}}" "{{static_ip}}"

# Clone a VM: copy /var disk from source, generate fresh identity, create boot disk
# Memory/vcpus default to source VM's values if not specified
clone source dest memory="" vcpus="" network="":
    @source {{backend_script}} && clone_vm "{{source}}" "{{dest}}" "{{memory}}" "{{vcpus}}" "{{network}}"

# Configure network mode for a VM (nat or bridge)
network-config name network="":
    @source {{backend_script}} && network_config_interactive "{{name}}" "{{network}}"

# Start a VM
start name:
    @source {{backend_script}} && backend_start "{{name}}"

# Stop a VM
stop name:
    @source {{backend_script}} && backend_stop "{{name}}"

# Reboot a VM (ACPI reboot)
reboot name:
    @source {{backend_script}} && backend_reboot "{{name}}"

# Force stop a VM
force-stop name:
    @source {{backend_script}} && backend_force_stop "{{name}}"

# Fully destroy a VM: force stop, undefine, remove disk files (keeps machine config)
destroy name:
    @source {{backend_script}} && destroy_vm "{{name}}"

# Completely remove a VM including its machine config
purge name:
    @source {{backend_script}} && purge_vm "{{name}}"

# Recreate a VM from its existing machine config (force stop, replace disks, start)
recreate name var_size="30G" network="":
    @source {{backend_script}} && recreate_vm "{{name}}" "{{var_size}}" "{{network}}"

# Update nix flake.lock
update:
    nix flake update

# Upgrade a VM to a new image (preserves /var data)
upgrade name:
    @source {{backend_script}} && upgrade_vm "{{name}}"

# Resize VM resources interactively (memory, vcpus, /var disk)
resize name:
    @source {{backend_script}} && resize_vm "{{name}}"

# Resize just the /var disk for a VM (VM must be stopped)
resize-var name size:
    @source {{backend_script}} && resize_var "{{name}}" "{{size}}"

# Set or clear the root password for a VM
passwd name:
    @source {{backend_script}} && set_password "{{name}}"

# Configure mutable mode for a VM (single read-write disk with full nix toolchain)
mutable name:
    @source {{backend_script}} && set_mutable "{{name}}"

# Set the profile(s) for a VM (e.g., just profile myvm docker python)
profile name +profiles:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "machines/{{name}}" ]; then
        echo "Error: Machine '{{name}}' does not exist" >&2
        exit 1
    fi
    profiles_csv=$(echo "{{profiles}}" | tr ' ' ',')
    echo "$profiles_csv" > "machines/{{name}}/profile"
    echo "Set profile for {{name}}: $profiles_csv"
    echo "Run 'just upgrade {{name}}' to apply the new profile."

# List all machine configs
list-machines:
    @source {{backend_script}} && list_machines

# Show VM console
console name:
    @source {{backend_script}} && backend_console "{{name}}"

# SSH into a VM (accepts [user@]name, defaults to 'user')
ssh name:
    @source {{backend_script}} && ssh_vm "{{name}}"

# Show VM status
status name:
    @source {{backend_script}} && backend_status "{{name}}"

# List all VMs
list:
    @source {{backend_script}} && backend_list

# Create a snapshot of a VM
snapshot name snapshot_name:
    @source {{backend_script}} && backend_snapshot "{{name}}" "{{snapshot_name}}"

# Restore a VM to a snapshot
restore-snapshot name snapshot_name:
    @source {{backend_script}} && backend_restore_snapshot "{{name}}" "{{snapshot_name}}"

# List snapshots for a VM
snapshots name:
    @source {{backend_script}} && backend_list_snapshots "{{name}}"

# Backup a VM (suspend, copy disks, compress)
backup name:
    @source {{backend_script}} && backup_vm "{{name}}"

# Restore a VM from backup (interactive selection if no file specified)
restore-backup name backup_file="":
    @source {{backend_script}} && restore_backup_vm "{{name}}" "{{backup_file}}"

# List available backups
backups:
    @source {{backend_script}} && list_backups

# Clean built images and VM disks (keeps machine configs)
clean:
    @source {{backend_script}} && clean

# Enter development shell
shell:
    @source {{backend_script}} && dev_shell

# Test connection to the backend (libvirt or proxmox)
test-connection:
    @source {{backend_script}} && test_connection

# Configure Woodpecker CI secrets for S3 image uploads (requires WOODPECKER_SERVER and WOODPECKER_TOKEN)
ci-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "${WOODPECKER_SERVER:-}" ]; then
        echo "Error: WOODPECKER_SERVER is not set" >&2
        echo "  export WOODPECKER_SERVER=https://woodpecker.example.com" >&2
        exit 1
    fi
    if [ -z "${WOODPECKER_TOKEN:-}" ]; then
        echo "Error: WOODPECKER_TOKEN is not set" >&2
        echo "  export WOODPECKER_TOKEN=your-api-token" >&2
        exit 1
    fi
    echo "Server: $WOODPECKER_SERVER"
    echo ""
    read -rp "Repository (e.g. owner/repo): " repo
    read -rp "S3 bucket name: " s3_bucket
    read -rp "rclone type [s3]: " rclone_type; rclone_type="${rclone_type:-s3}"
    read -rp "rclone provider (e.g. DigitalOcean, AWS, Minio): " rclone_provider
    read -rp "rclone endpoint (e.g. nyc3.digitaloceanspaces.com): " rclone_endpoint
    read -rp "rclone region (e.g. nyc3, us-east-1): " rclone_region
    read -rp "Access key ID: " rclone_access_key_id
    read -rsp "Secret access key: " rclone_secret_access_key; echo ""
    echo ""
    wcli() { nix run nixpkgs#woodpecker-cli -- "$@"; }
    # Activate repo if not already active
    wcli repo show "$repo" >/dev/null 2>&1 || {
        echo "Activating repo in Woodpecker..."
        sync_output=$(wcli repo sync 2>&1)
        echo "$sync_output"
        forge_id=$(echo "$sync_output" | grep "^${repo} " | sed 's/.*forgeRemoteID: //' | sed 's/,.*//')
        if [ -n "$forge_id" ]; then
            wcli repo add "$forge_id"
        else
            echo "Error: Could not find '$repo' in forge. Available repos:" >&2
            echo "$sync_output" >&2
            exit 1
        fi
    }
    wcli repo secret add --repo "$repo" --name s3_bucket --value "$s3_bucket" 2>/dev/null || \
        wcli repo secret update --repo "$repo" --name s3_bucket --value "$s3_bucket"
    wcli repo secret add --repo "$repo" --name rclone_type --value "$rclone_type" 2>/dev/null || \
        wcli repo secret update --repo "$repo" --name rclone_type --value "$rclone_type"
    wcli repo secret add --repo "$repo" --name rclone_provider --value "$rclone_provider" 2>/dev/null || \
        wcli repo secret update --repo "$repo" --name rclone_provider --value "$rclone_provider"
    wcli repo secret add --repo "$repo" --name rclone_endpoint --value "$rclone_endpoint" 2>/dev/null || \
        wcli repo secret update --repo "$repo" --name rclone_endpoint --value "$rclone_endpoint"
    wcli repo secret add --repo "$repo" --name rclone_region --value "$rclone_region" 2>/dev/null || \
        wcli repo secret update --repo "$repo" --name rclone_region --value "$rclone_region"
    wcli repo secret add --repo "$repo" --name rclone_access_key_id --value "$rclone_access_key_id" 2>/dev/null || \
        wcli repo secret update --repo "$repo" --name rclone_access_key_id --value "$rclone_access_key_id"
    wcli repo secret add --repo "$repo" --name rclone_secret_access_key --value "$rclone_secret_access_key" 2>/dev/null || \
        wcli repo secret update --repo "$repo" --name rclone_secret_access_key --value "$rclone_secret_access_key"
    echo "All secrets configured for $repo"

_completion_profile:
    @shopt -s nullglob; for f in profiles/*.nix; do basename "$f" .nix; done

_completion_network:
    @printf "nat\nbridge\n"

_completion_name:
    @shopt -s nullglob; for f in machines/*; do basename $f; done
