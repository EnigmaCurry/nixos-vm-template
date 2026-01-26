# NixOS Immutable VM Image Builder

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load

BACKEND := env_var_or_default("BACKEND", "libvirt")
backend_script := if BACKEND == "common" { error("BACKEND cannot be 'common'") } else { "backends/" + BACKEND + ".sh" }

# Default recipe - show available commands
[private]
default:
    @just --list

# Build a profile's base image (default: core)
build profile="core":
    @source {{backend_script}} && build_profile "{{profile}}"

# Build all profiles
build-all:
    @source {{backend_script}} && build_all

# List available profiles
list-profiles:
    @source {{backend_script}} && list_profiles

# Create a new VM: build profile, create machine config, create disks, generate config, define
create name profile="core" memory="2048" vcpus="2" var_size="30G" network="nat":
    @source {{backend_script}} && create_vm "{{name}}" "{{profile}}" "{{memory}}" "{{vcpus}}" "{{var_size}}" "{{network}}"

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
