# NixOS Immutable VM Image Builder

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load
set export

BACKEND := env_var_or_default("BACKEND", "libvirt")
# Proxmox backends (KVM and LXC) scope machines by the remote PVE node, not the
# local workstation hostname — the guests live on the node, and the same node may
# be managed from several workstations.
_IS_PVE := if BACKEND == "proxmox" { "yes" } else if BACKEND == "proxmox-lxc" { "yes" } else { "no" }
HOST := if _IS_PVE == "yes" { env_var_or_default("PVE_NODE", env_var_or_default("HOST", `hostname -s`)) } else { env_var_or_default("HOST", `hostname -s`) }
_XDG_CONFIG_HOME := env_var_or_default("XDG_CONFIG_HOME", env_var("HOME") + "/.config")
_DEFAULT_MACHINES_DIR := env_var_or_default("NIXOS_VM_MACHINES_DIR", _XDG_CONFIG_HOME + "/nixos-vm-template/machines")
MACHINES_DIR := env_var_or_default("MACHINES_DIR", _DEFAULT_MACHINES_DIR + "/" + BACKEND + "/" + HOST)

# All VM management logic lives in Babashka (src/vm/, entrypoint bb -m vm.cli).
# BACKEND/MACHINES_DIR are exported above and read by vm.config.
#
# Recipes run the CLI inside the flake's dev shell (`nix develop --command`) so
# bb and the disk tools (qemu-img, guestfish, virsh, …) are on PATH without
# manually entering the shell. Override with VM_CLI="bb -m vm.cli" when those
# tools are already on PATH (e.g. you're inside `nix develop`, or in CI).
VM_CLI := env_var_or_default("VM_CLI", "nix develop --command bb -m vm.cli")

# Default recipe - show available commands
[private]
default:
    @just --list

# Build a profile image (supports comma-separated profiles, e.g., docker,python)
build profiles="core":
    @{{VM_CLI}} build "{{profiles}}"

# Build all profiles
build-all:
    @{{VM_CLI}} build-all

# Export a profile image with release metadata filename
export profiles="core":
    @{{VM_CLI}} export "{{profiles}}"

# List available profiles
list-profiles:
    @{{VM_CLI}} list-profiles

# Configure a VM interactively using script-wizard (or non-interactively with all args)
config name="" profile="":
    @{{VM_CLI}} config "{{name}}" "{{profile}}"

# Configure a VM non-interactively with explicit values
config-batch new_name profiles="core" memory="2048" vcpus="2" var_size="30G" network="nat" static_ip="":
    @{{VM_CLI}} config-batch "{{new_name}}" "{{profiles}}" "{{memory}}" "{{vcpus}}" "{{var_size}}" "{{network}}" "{{static_ip}}"

# Create a VM from a pre-built image (no local image build required)
bootstrap:
    @nix run nixpkgs#babashka -- bootstrap.bb

# Create a new VM interactively (prompts for all settings)
create name:
    @{{VM_CLI}} create "{{name}}"

# Create a new VM non-interactively with explicit values
create-batch name profiles="core" memory="2048" vcpus="2" var_size="30G" network="nat" static_ip="":
    @{{VM_CLI}} create-batch "{{name}}" "{{profiles}}" "{{memory}}" "{{vcpus}}" "{{var_size}}" "{{network}}" "{{static_ip}}"

# Clone a VM: copy /var disk from source, generate fresh identity, create boot disk
# Memory/vcpus default to source VM's values if not specified
clone source dest memory="" vcpus="" network="":
    @{{VM_CLI}} clone "{{source}}" "{{dest}}" "{{memory}}" "{{vcpus}}" "{{network}}"

# Configure network mode for a VM (nat or bridge)
network-config name network="":
    @{{VM_CLI}} network-config "{{name}}" "{{network}}"

# Start a VM
start name:
    @{{VM_CLI}} start "{{name}}"

# Stop a VM
stop name:
    @{{VM_CLI}} stop "{{name}}"

# Reboot a VM (ACPI reboot)
reboot name:
    @{{VM_CLI}} reboot "{{name}}"

# Force stop a VM
force-stop name:
    @{{VM_CLI}} force-stop "{{name}}"

# Fully destroy a VM: force stop, undefine, remove disk files (keeps machine config)
destroy name:
    @{{VM_CLI}} destroy "{{name}}"

# Completely remove a VM including its machine config
purge name:
    @{{VM_CLI}} purge "{{name}}"

# Recreate a VM from its existing machine config (force stop, replace disks, start)
recreate name var_size="30G" network="":
    @{{VM_CLI}} recreate "{{name}}" "{{var_size}}" "{{network}}"

# Update nix flake.lock
update:
    nix flake update

# Upgrade a VM to a new image (preserves /var data)
upgrade name:
    @{{VM_CLI}} upgrade "{{name}}"

# Resize VM resources interactively (memory, vcpus, /var disk)
resize name:
    @{{VM_CLI}} resize "{{name}}"

# Resize just the /var disk for a VM (VM must be stopped)
resize-var name size:
    @{{VM_CLI}} resize-var "{{name}}" "{{size}}"

# Set or clear the root password for a VM
passwd name:
    @{{VM_CLI}} passwd "{{name}}"

# Set the profile(s) for a VM (e.g., just profile myvm docker python)
profile name +profiles:
    @{{VM_CLI}} set-profile "{{name}}" {{profiles}}

# List all machine configs
list-machines:
    @{{VM_CLI}} list-machines

# Show VM console
console name:
    @{{VM_CLI}} console "{{name}}"

# SSH into a VM (accepts [user@]name, defaults to 'user')
ssh name:
    @{{VM_CLI}} ssh "{{name}}"

# Show VM status
status name:
    @{{VM_CLI}} status "{{name}}"

# List all VMs
list:
    @{{VM_CLI}} list

# Create a snapshot of a VM
snapshot name snapshot_name:
    @{{VM_CLI}} snapshot "{{name}}" "{{snapshot_name}}"

# Restore a VM to a snapshot
restore-snapshot name snapshot_name:
    @{{VM_CLI}} restore-snapshot "{{name}}" "{{snapshot_name}}"

# List snapshots for a VM
snapshots name:
    @{{VM_CLI}} snapshots "{{name}}"

# Backup a VM (suspend, copy disks, compress)
backup name:
    @{{VM_CLI}} backup "{{name}}"

# Restore a VM from backup (interactive selection if no file specified)
restore-backup name backup_file="":
    @{{VM_CLI}} restore-backup "{{name}}" "{{backup_file}}"

# List available backups
backups:
    @{{VM_CLI}} backups

# Clean built images and VM disks (keeps machine configs)
clean:
    @{{VM_CLI}} clean

# Enter development shell
shell:
    @{{VM_CLI}} shell

# Test connection to the backend (libvirt or proxmox)
test-connection:
    @{{VM_CLI}} test-connection

# Configure Woodpecker CI secrets for S3 image uploads
# Required env vars: WOODPECKER_SERVER, WOODPECKER_TOKEN, CI_REPO,
#   S3_BUCKET, S3_PUBLIC_URL, S3_PROVIDER, S3_ENDPOINT, S3_REGION, S3_ACCESS_KEY_ID
# Prompts for: S3_SECRET_ACCESS_KEY
ci-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    missing=()
    [ -z "${WOODPECKER_SERVER:-}" ] && missing+=("WOODPECKER_SERVER")
    [ -z "${WOODPECKER_TOKEN:-}" ] && missing+=("WOODPECKER_TOKEN")
    [ -z "${CI_REPO:-}" ] && missing+=("CI_REPO")
    [ -z "${S3_BUCKET:-}" ] && missing+=("S3_BUCKET")
    [ -z "${S3_PUBLIC_URL:-}" ] && missing+=("S3_PUBLIC_URL")
    [ -z "${S3_PROVIDER:-}" ] && missing+=("S3_PROVIDER")
    [ -z "${S3_ENDPOINT:-}" ] && missing+=("S3_ENDPOINT")
    [ -z "${S3_REGION:-}" ] && missing+=("S3_REGION")
    [ -z "${S3_ACCESS_KEY_ID:-}" ] && missing+=("S3_ACCESS_KEY_ID")
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Error: Missing required environment variables:" >&2
        for v in "${missing[@]}"; do echo "  $v" >&2; done
        echo "" >&2
        echo "Example:" >&2
        echo "  export WOODPECKER_SERVER=https://woodpecker.example.com" >&2
        echo "  export WOODPECKER_TOKEN=your-api-token" >&2
        echo "  export CI_REPO=owner/repo" >&2
        echo "  export S3_BUCKET=nixos-vm-template" >&2
        echo "  export S3_PUBLIC_URL=https://nixos-vm-template.nyc3.cdn.digitaloceanspaces.com" >&2
        echo "  export S3_PROVIDER=DigitalOcean  # or AWS, Minio" >&2
        echo "  export S3_ENDPOINT=nyc3.digitaloceanspaces.com" >&2
        echo "  export S3_REGION=nyc3" >&2
        echo "  export S3_ACCESS_KEY_ID=your-access-key" >&2
        exit 1
    fi
    repo="$CI_REPO"
    s3_bucket="$S3_BUCKET"
    s3_public_url="$S3_PUBLIC_URL"
    rclone_type="s3"
    rclone_provider="$S3_PROVIDER"
    rclone_endpoint="$S3_ENDPOINT"
    rclone_region="$S3_REGION"
    rclone_access_key_id="$S3_ACCESS_KEY_ID"
    read -rsp "S3 secret access key: " rclone_secret_access_key; echo ""
    echo ""
    echo "Server: $WOODPECKER_SERVER"
    echo "Repo: $repo"
    echo ""
    wcli() { nix run nixpkgs#woodpecker-cli -- "$@"; }
    # Activate repo if not already active
    wcli repo show "$repo" >/dev/null 2>&1 || {
        echo "Activating repo in Woodpecker..."
        lb='{''{'
        rb='}''}'
        fmt="${lb} .FullName ${rb} ${lb} .ForgeRemoteID ${rb}"
        sync_output=$(wcli repo sync --format "$fmt" 2>&1)
        echo "$sync_output"
        forge_id=$(echo "$sync_output" | grep "^${repo} " | awk '{print $2}')
        if [ -n "$forge_id" ]; then
            echo "Found forge ID: $forge_id"
            wcli repo add "$forge_id" || { echo "Error: failed to activate repo (forge ID: $forge_id)" >&2; exit 1; }
        else
            echo "Error: Could not find '$repo' in forge. Available repos:" >&2
            echo "$sync_output" >&2
            exit 1
        fi
    }
    wcli repo secret add --repo "$repo" --name s3_bucket --value "$s3_bucket" 2>/dev/null || \
        wcli repo secret update --repo "$repo" --name s3_bucket --value "$s3_bucket"
    wcli repo secret add --repo "$repo" --name s3_public_url --value "$s3_public_url" 2>/dev/null || \
        wcli repo secret update --repo "$repo" --name s3_public_url --value "$s3_public_url"
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
    @shopt -s nullglob; for f in profiles/*.nix; do n=$(basename "$f" .nix); if [ "$n" = nas ] && [ "{{BACKEND}}" != proxmox-lxc ]; then continue; fi; echo "$n"; done

# Alias for recipes whose parameter is named `profiles` (build, create-batch, …)
_completion_profiles: _completion_profile

_completion_network:
    @printf "nat\nbridge\n"

_completion_name:
    @shopt -s nullglob; for f in {{MACHINES_DIR}}/*; do basename $f; done
