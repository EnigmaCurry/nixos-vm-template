#!/usr/bin/env bash
# DigitalOcean Droplet backend for NixOS VM Template
# Uses doctl CLI for all operations.
# Sourced by Justfile recipes - do not execute directly.

set -euo pipefail

# Source common functions
BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BACKEND_DIR/common.sh"

# Override build_profile to use DO format by default
build_profile() {
    local profiles="${1:-core}"
    local mutable="${2:-false}"
    local format="${3:-do}"  # Default to DO format for this backend

    # Normalize to canonical profile key
    local profile_key
    profile_key=$(normalize_profiles "$profiles")

    # Add mutable suffix for mutable images
    local output_key="$profile_key"
    if [ "$mutable" = "true" ]; then
        output_key="${profile_key}-mutable"
    fi

    # Add format suffix for non-qcow formats
    if [ "$format" != "qcow" ]; then
        output_key="${output_key}-${format}"
    fi

    echo "Building profile: $profile_key (mutable=$mutable, format=$format)"
    mkdir -p "$OUTPUT_DIR/profiles"

    # Convert comma-separated to nix list format
    local nix_list
    nix_list=$(echo "$profile_key" | sed 's/,/" "/g' | sed 's/^/["/;s/$/"]/')

    $NIX build --impure --expr "
      let flake = builtins.getFlake \"$SCRIPT_DIR\";
      in flake.lib.mkCombinedImage \"x86_64-linux\" $nix_list { mutable = $mutable; format = \"$format\"; }
    " --out-link "$OUTPUT_DIR/profiles/$output_key"

    echo "Built: $OUTPUT_DIR/profiles/$output_key"
}

# Backend-specific environment defaults
DO_REGION="${DO_REGION:-nyc1}"
DO_SIZE="${DO_SIZE:-s-1vcpu-1gb}"
DO_VPC_UUID="${DO_VPC_UUID:-}"  # Optional: use default VPC if not set
DO_SSH_KEY_IDS="${DO_SSH_KEY_IDS:-}"  # Comma-separated SSH key IDs or fingerprints
DO_IMAGE_UPLOAD_TIMEOUT="${DO_IMAGE_UPLOAD_TIMEOUT:-1800}"  # 30 min default

# doctl command: use system binary if available, otherwise nix run
_detect_doctl() {
    if [ -n "${DOCTL:-}" ]; then
        echo "$DOCTL"
    elif command -v doctl &>/dev/null; then
        echo "doctl"
    else
        echo "$NIX run nixpkgs#doctl --"
    fi
}
DOCTL="$(_detect_doctl)"

# --- Validation ---

_do_validate() {
    # Test that doctl is available
    if ! $DOCTL version &>/dev/null; then
        echo "Error: doctl CLI not found."
        echo ""
        echo "Install: https://docs.digitalocean.com/reference/doctl/how-to/install/"
        echo "Or use: nix run nixpkgs#doctl -- <command>"
        exit 1
    fi

    # Check if authenticated
    if ! $DOCTL account get &>/dev/null; then
        echo "Error: doctl not authenticated."
        echo "Run: $DOCTL auth init"
        exit 1
    fi
}

# --- Connection Test ---

test_connection() {
    echo "Testing DigitalOcean connection..."
    echo ""

    _do_validate

    echo "Account info:"
    $DOCTL account get
    echo ""

    echo "Default region: $DO_REGION"
    echo "Default size: $DO_SIZE"

    if [ -n "$DO_VPC_UUID" ]; then
        echo "VPC: $DO_VPC_UUID"
    else
        echo "VPC: (default)"
    fi

    echo ""
    echo "Connection test passed."
}

# --- Helper Functions ---

# Get droplet ID for a machine (stored in machines/<name>/droplet_id)
do_get_droplet_id() {
    local name="$1"
    local id_file="$MACHINES_DIR/$name/droplet_id"
    if [ ! -f "$id_file" ]; then
        echo "Error: Droplet ID not found for machine '$name'"
        echo "Expected file: $id_file"
        echo "Create the VM first with: BACKEND=doctl just create $name"
        exit 1
    fi
    cat "$id_file"
}

# Get volume ID for a machine (stored in machines/<name>/volume_id)
do_get_volume_id() {
    local name="$1"
    local id_file="$MACHINES_DIR/$name/volume_id"
    if [ ! -f "$id_file" ]; then
        echo "Error: Volume ID not found for machine '$name'"
        echo "Expected file: $id_file"
        exit 1
    fi
    cat "$id_file"
}

# Get or create a custom image for a profile
# Returns the image ID
do_get_or_upload_image() {
    local profile="$1"
    local profile_dir="$OUTPUT_DIR/profiles/${profile}-do"
    local image_id_file="$profile_dir/do_image_id"
    local image_name="nixos-vm-${profile//,/-}"

    # Check if we already have an uploaded image ID
    if [ -f "$image_id_file" ]; then
        local existing_id
        existing_id=$(cat "$image_id_file")
        # Verify it still exists on DO
        if $DOCTL compute image get "$existing_id" &>/dev/null; then
            echo "$existing_id"
            return 0
        fi
        echo "Warning: Cached image ID $existing_id no longer exists on DO" >&2
        rm -f "$image_id_file"
    fi

    # Check if image exists by name on DO
    local existing_image
    existing_image=$($DOCTL compute image list --public=false --format ID,Name --no-header | grep "^[0-9]*[[:space:]]*${image_name}$" | awk '{print $1}' | head -1 || true)
    if [ -n "$existing_image" ]; then
        echo "$existing_image" > "$image_id_file"
        echo "$existing_image"
        return 0
    fi

    # Need to upload new image
    echo "No existing image found for profile '$profile'. Upload required." >&2
    return 1
}

# Upload a profile image to DigitalOcean
# Requires DO_SPACES_BUCKET and DO_SPACES_REGION to be set for upload
do_upload_image() {
    local profile="$1"
    local profile_dir="$OUTPUT_DIR/profiles/${profile}-do"
    local image_id_file="$profile_dir/do_image_id"
    local image_name="nixos-vm-${profile//,/-}"

    # Find the DO image (nixos-generators produces a .qcow2.gz file)
    local image_file
    image_file=$(find "$profile_dir/" -name "*.qcow2.gz" -type f 2>/dev/null | head -1)

    if [ -z "$image_file" ] || [ ! -f "$image_file" ]; then
        echo "Error: No DO image found in $profile_dir/"
        echo "Expected a .qcow2.gz file from nixos-generators"
        echo ""
        echo "Build with: just build $profile  (uses format=do for this backend)"
        exit 1
    fi

    echo "Found image: $image_file"
    local image_size
    image_size=$(ls -lh "$image_file" | awk '{print $5}')
    echo "Image size: $image_size"

    # Check if we have Spaces configured for upload
    if [ -n "${DO_SPACES_BUCKET:-}" ] && [ -n "${DO_SPACES_REGION:-}" ]; then
        echo "Uploading to DigitalOcean Spaces..."
        local spaces_endpoint="https://${DO_SPACES_REGION}.digitaloceanspaces.com"
        local spaces_key="${image_name}.qcow2.gz"
        local spaces_url="https://${DO_SPACES_BUCKET}.${DO_SPACES_REGION}.digitaloceanspaces.com/${spaces_key}"

        # Use s3cmd or aws cli for upload (doctl doesn't support Spaces uploads directly)
        if command -v s3cmd &>/dev/null; then
            s3cmd put "$image_file" "s3://${DO_SPACES_BUCKET}/${spaces_key}" \
                --host="${DO_SPACES_REGION}.digitaloceanspaces.com" \
                --host-bucket="%(bucket)s.${DO_SPACES_REGION}.digitaloceanspaces.com" \
                --acl-public
        elif command -v aws &>/dev/null; then
            aws s3 cp "$image_file" "s3://${DO_SPACES_BUCKET}/${spaces_key}" \
                --endpoint-url "$spaces_endpoint" \
                --acl public-read
        else
            echo "Error: Neither s3cmd nor aws CLI found for Spaces upload."
            echo "Install one of: s3cmd, awscli"
            exit 1
        fi

        echo "Uploaded to: $spaces_url"
        echo ""
        echo "Creating custom image from URL..."
        local create_output
        create_output=$($DOCTL compute image create "$image_name" \
            --region "$DO_REGION" \
            --image-url "$spaces_url" \
            --format ID --no-header)

        echo "Image creation initiated. Waiting for image to be available..."
        # Wait for image to be ready (can take several minutes)
        local image_id="$create_output"
        local max_wait=1800  # 30 minutes
        local waited=0
        while [ $waited -lt $max_wait ]; do
            local status
            status=$($DOCTL compute image get "$image_id" --format Status --no-header 2>/dev/null || echo "pending")
            if [ "$status" = "available" ]; then
                echo "Image ready: $image_id"
                echo "$image_id" > "$image_id_file"
                echo "$image_id"
                return 0
            elif [ "$status" = "deleted" ] || [ "$status" = "error" ]; then
                echo "Error: Image creation failed (status: $status)"
                exit 1
            fi
            echo "Image status: $status (waiting...)"
            sleep 30
            waited=$((waited + 30))
        done
        echo "Error: Timed out waiting for image to be ready"
        exit 1
    else
        # Manual upload instructions
        echo ""
        echo "To upload this image to DigitalOcean:"
        echo ""
        echo "Option 1: Web UI"
        echo "  1. Go to: https://cloud.digitalocean.com/images/custom_images"
        echo "  2. Click 'Import via URL' or upload directly"
        echo "  3. Upload: $image_file"
        echo "  4. Save the image ID to: $image_id_file"
        echo ""
        echo "Option 2: Spaces + doctl (set these env vars and re-run):"
        echo "  export DO_SPACES_BUCKET=my-bucket"
        echo "  export DO_SPACES_REGION=nyc3"
        echo ""
        echo "After uploading manually, save the image ID:"
        echo "  echo '<image-id>' > $image_id_file"
        exit 1
    fi
}

# Map memory (MB) to DO droplet size slug
do_size_from_specs() {
    local memory="$1"
    local vcpus="$2"

    # Basic mapping - could be smarter
    if [ "$memory" -le 1024 ]; then
        echo "s-1vcpu-1gb"
    elif [ "$memory" -le 2048 ]; then
        echo "s-1vcpu-2gb"
    elif [ "$memory" -le 4096 ]; then
        echo "s-2vcpu-4gb"
    elif [ "$memory" -le 8192 ]; then
        echo "s-4vcpu-8gb"
    elif [ "$memory" -le 16384 ]; then
        echo "s-8vcpu-16gb"
    else
        echo "s-8vcpu-32gb"
    fi
}

# Wait for a droplet action to complete
do_wait_action() {
    local action_id="$1"
    local timeout="${2:-300}"

    echo "Waiting for action $action_id..."
    $DOCTL compute action wait "$action_id" --no-header
}

# --- Backend Primitives ---

# Create droplet and volume
backend_create_disks() {
    local name="$1"
    local var_size
    var_size=$(normalize_size "${2:-30G}")
    local machine_dir="$MACHINES_DIR/$name"

    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        echo "Run 'BACKEND=doctl just create $name' first"
        exit 1
    fi

    _do_validate

    local profile
    profile=$(cat "$machine_dir/profile")
    profile=$(normalize_profiles "$profile")

    # Mutable mode not yet supported
    if is_mutable "$name"; then
        echo "Error: Mutable mode not yet supported for DigitalOcean backend."
        exit 1
    fi

    echo "Creating droplet: $name (profile: $profile)"

    # Get the image (should already be built and uploaded by caller)
    local image_id
    image_id=$(do_get_or_upload_image "$profile")
    if [ -z "$image_id" ]; then
        echo "Error: No image available for profile '$profile'"
        echo "Build with: BACKEND=doctl just build $profile"
        exit 1
    fi
    echo "Using image ID: $image_id"

    # Read specs from machine config
    local memory vcpus
    memory=$(cat "$machine_dir/memory" 2>/dev/null || echo "2048")
    vcpus=$(cat "$machine_dir/vcpus" 2>/dev/null || echo "2")
    local size_slug
    size_slug=$(do_size_from_specs "$memory" "$vcpus")
    echo "Droplet size: $size_slug"

    # Parse var_size to GB integer for DO volumes
    local var_size_gb
    var_size_gb=$(echo "$var_size" | sed 's/[Gg]$//')

    # Read identity
    local hostname
    hostname=$(cat "$machine_dir/hostname")

    # Build SSH key args
    local ssh_key_args=""
    if [ -n "$DO_SSH_KEY_IDS" ]; then
        ssh_key_args="--ssh-keys $DO_SSH_KEY_IDS"
    fi

    # Build VPC args
    local vpc_args=""
    if [ -n "$DO_VPC_UUID" ]; then
        vpc_args="--vpc-uuid $DO_VPC_UUID"
    fi

    # Create the /var volume first
    echo "Creating /var volume (${var_size_gb}GB)..."
    local volume_output
    volume_output=$($DOCTL compute volume create "${name}-var" \
        --region "$DO_REGION" \
        --size "${var_size_gb}GiB" \
        --fs-type ext4 \
        --format ID --no-header)
    local volume_id="$volume_output"
    echo "$volume_id" > "$machine_dir/volume_id"
    echo "Created volume: $volume_id"

    # Prepare user-data for cloud-init (identity injection)
    local user_data_file
    user_data_file=$(mktemp)
    cat > "$user_data_file" <<EOF
#cloud-config
hostname: $hostname
manage_etc_hosts: false

# Mount the /var volume
mounts:
  - [ /dev/disk/by-id/scsi-0DO_Volume_${name}-var, /var, ext4, "defaults,nofail", "0", "2" ]

# Write identity files
write_files:
  - path: /var/identity/hostname
    content: |
      $hostname
  - path: /var/identity/machine-id
    content: |
      $(cat "$machine_dir/machine-id")
EOF

    # Add SSH keys to user-data if present
    if [ -s "$machine_dir/admin_authorized_keys" ]; then
        echo "  - path: /var/identity/admin_authorized_keys" >> "$user_data_file"
        echo "    content: |" >> "$user_data_file"
        sed 's/^/      /' "$machine_dir/admin_authorized_keys" >> "$user_data_file"
    fi

    if [ -s "$machine_dir/user_authorized_keys" ]; then
        echo "  - path: /var/identity/user_authorized_keys" >> "$user_data_file"
        echo "    content: |" >> "$user_data_file"
        sed 's/^/      /' "$machine_dir/user_authorized_keys" >> "$user_data_file"
    fi

    # Create the droplet
    echo "Creating droplet..."
    local droplet_output
    droplet_output=$($DOCTL compute droplet create "$name" \
        --image "$image_id" \
        --size "$size_slug" \
        --region "$DO_REGION" \
        --user-data-file "$user_data_file" \
        $ssh_key_args \
        $vpc_args \
        --format ID --no-header --wait)
    local droplet_id="$droplet_output"
    echo "$droplet_id" > "$machine_dir/droplet_id"
    echo "Created droplet: $droplet_id"

    rm -f "$user_data_file"

    # Attach the volume to the droplet
    echo "Attaching /var volume..."
    $DOCTL compute volume-action attach "$volume_id" "$droplet_id" --wait

    echo ""
    echo "Droplet '$name' created (ID: $droplet_id)"
    echo "Volume attached: $volume_id"
}

# Sync identity to volume (requires stopping droplet, detaching, modifying, reattaching)
backend_sync_identity() {
    local name="$1"
    local machine_dir="$MACHINES_DIR/$name"

    echo "Warning: Identity sync on DigitalOcean requires SSH access to running droplet."
    echo "Use 'just ssh admin@$name' and manually update /var/identity/ files."
    echo ""
    echo "Or destroy and recreate the droplet to apply new identity."
}

# Generate config (no-op for DO - config is in droplet metadata)
backend_generate_config() {
    local name="$1"
    local memory="${2:-2048}"
    local vcpus="${3:-2}"

    # Save to machine config
    echo "$memory" > "$MACHINES_DIR/$name/memory"
    echo "$vcpus" > "$MACHINES_DIR/$name/vcpus"

    echo "Note: To resize a DigitalOcean droplet, use 'doctl compute droplet-action resize'"
}

# Define (no-op for DO - droplet is defined at creation)
backend_define() {
    local name="$1"
    echo "Droplet '$name' is defined (ID: $(do_get_droplet_id "$name"))"
}

# Undefine (destroy droplet, optionally keep volume)
backend_undefine() {
    local name="$1"
    _do_validate

    local droplet_id
    droplet_id=$(do_get_droplet_id "$name")

    echo "Destroying droplet $droplet_id..."
    $DOCTL compute droplet delete "$droplet_id" --force

    rm -f "$MACHINES_DIR/$name/droplet_id"
    echo "Droplet destroyed."
}

# --- Lifecycle Functions ---

backend_start() {
    local name="$1"
    _do_validate
    local droplet_id
    droplet_id=$(do_get_droplet_id "$name")

    echo "Powering on droplet: $name (ID: $droplet_id)"
    $DOCTL compute droplet-action power-on "$droplet_id" --wait
}

backend_stop() {
    local name="$1"
    _do_validate
    local droplet_id
    droplet_id=$(do_get_droplet_id "$name")

    echo "Shutting down droplet: $name (ID: $droplet_id)"
    $DOCTL compute droplet-action shutdown "$droplet_id" --wait
}

backend_reboot() {
    local name="$1"
    _do_validate
    local droplet_id
    droplet_id=$(do_get_droplet_id "$name")

    echo "Rebooting droplet: $name (ID: $droplet_id)"
    $DOCTL compute droplet-action reboot "$droplet_id" --wait
}

backend_force_stop() {
    local name="$1"
    _do_validate
    local droplet_id
    droplet_id=$(do_get_droplet_id "$name")

    echo "Force stopping droplet: $name (ID: $droplet_id)"
    $DOCTL compute droplet-action power-off "$droplet_id" --wait 2>/dev/null || true
}

backend_suspend() {
    local name="$1"
    echo "Warning: DigitalOcean does not support suspend. Use power-off instead."
    backend_force_stop "$name"
}

backend_resume() {
    local name="$1"
    backend_start "$name"
}

backend_is_running() {
    local name="$1"
    _do_validate
    local droplet_id
    droplet_id=$(do_get_droplet_id "$name")

    local status
    status=$($DOCTL compute droplet get "$droplet_id" --format Status --no-header 2>/dev/null || echo "")
    [ "$status" = "active" ]
}

# --- Info Functions ---

backend_status() {
    local name="$1"
    _do_validate
    local droplet_id
    droplet_id=$(do_get_droplet_id "$name")

    $DOCTL compute droplet get "$droplet_id"
    echo ""
    echo "Volumes:"
    if [ -f "$MACHINES_DIR/$name/volume_id" ]; then
        local volume_id
        volume_id=$(cat "$MACHINES_DIR/$name/volume_id")
        $DOCTL compute volume get "$volume_id" --format ID,Name,Size,Region
    fi
}

backend_list() {
    _do_validate

    # List only droplets that we manage (have a machine config)
    echo "Managed droplets:"
    printf "%-12s %-20s %-10s %-15s\n" "DROPLET_ID" "NAME" "STATUS" "IP"

    for machine_dir in "$MACHINES_DIR"/*/; do
        [ -d "$machine_dir" ] || continue
        local name
        name=$(basename "$machine_dir")
        local droplet_id_file="$machine_dir/droplet_id"

        if [ -f "$droplet_id_file" ]; then
            local droplet_id status ip
            droplet_id=$(cat "$droplet_id_file")
            local info
            info=$($DOCTL compute droplet get "$droplet_id" --format Status,PublicIPv4 --no-header 2>/dev/null || echo "not_found -")
            status=$(echo "$info" | awk '{print $1}')
            ip=$(echo "$info" | awk '{print $2}')
            printf "%-12s %-20s %-10s %-15s\n" "$droplet_id" "$name" "$status" "$ip"
        fi
    done
}

backend_console() {
    local name="$1"
    echo "DigitalOcean does not provide serial console access via CLI."
    echo "Use the web console at: https://cloud.digitalocean.com/droplets"
    echo ""
    echo "Or SSH directly: just ssh $name"
}

backend_get_ip() {
    local name="$1"
    _do_validate
    local droplet_id
    droplet_id=$(do_get_droplet_id "$name")

    $DOCTL compute droplet get "$droplet_id" --format PublicIPv4 --no-header 2>/dev/null
}

# --- Snapshot Functions ---

backend_snapshot() {
    local name="$1"
    local snapshot_name="$2"
    _do_validate
    local droplet_id
    droplet_id=$(do_get_droplet_id "$name")

    echo "Creating snapshot '$snapshot_name' for droplet '$name'..."
    $DOCTL compute droplet-action snapshot "$droplet_id" --snapshot-name "$snapshot_name" --wait
    echo "Snapshot created."
}

backend_restore_snapshot() {
    local name="$1"
    local snapshot_name="$2"
    _do_validate

    echo "Warning: DigitalOcean snapshot restore requires recreating the droplet."
    echo "Use: doctl compute droplet create --image <snapshot-id>"
    echo ""
    echo "Available snapshots:"
    backend_list_snapshots "$name"
}

backend_list_snapshots() {
    local name="$1"
    _do_validate
    local droplet_id
    droplet_id=$(do_get_droplet_id "$name")

    $DOCTL compute snapshot list --resource droplet --format ID,Name,CreatedAt
}

backend_snapshot_count() {
    local name="$1"
    _do_validate
    local droplet_id
    droplet_id=$(do_get_droplet_id "$name")

    $DOCTL compute snapshot list --resource droplet --format ID --no-header 2>/dev/null | wc -l || echo "0"
}

# --- Cleanup ---

backend_cleanup() {
    local name="$1"
    # No local artifacts to clean for DO
    :
}

# --- Composite Operations ---

create_vm() {
    local name="$1"

    # Configure machine interactively
    config_vm_interactive "$name" "" "true"

    # Read back configured values
    local machine_dir="$MACHINES_DIR/$name"
    local profile var_size
    profile=$(cat "$machine_dir/profile" 2>/dev/null || echo "core")
    profile=$(normalize_profiles "$profile")
    var_size=$(cat "$machine_dir/var_size" 2>/dev/null || echo "30G")

    # Build the profile image (uses DO format via override)
    build_profile "$profile" "false"

    # Upload if needed
    if ! do_get_or_upload_image "$profile" >/dev/null; then
        do_upload_image "$profile"
    fi

    # Create droplet and volume
    backend_create_disks "$name" "$var_size"

    echo ""
    echo "Droplet '$name' created on DigitalOcean."
    echo "SSH as admin: ssh admin@$(backend_get_ip "$name")"
    echo "SSH as user: ssh user@$(backend_get_ip "$name")"
}

create_vm_batch() {
    local name="$1"
    local profile="${2:-core}"
    local memory="${3:-2048}"
    local vcpus="${4:-2}"
    local var_size
    var_size=$(normalize_size "${5:-30G}")
    local network="${6:-nat}"  # Ignored for DO

    # Configure machine non-interactively
    config_vm "$name" "$profile" "$memory" "$vcpus" "$var_size" "$network"

    # Normalize profile
    profile=$(normalize_profiles "$profile")

    # Build the profile image (uses DO format via override)
    build_profile "$profile" "false"

    # Upload if needed
    if ! do_get_or_upload_image "$profile" >/dev/null; then
        do_upload_image "$profile"
    fi

    # Create droplet and volume
    backend_create_disks "$name" "$var_size"

    echo ""
    echo "Droplet '$name' created on DigitalOcean."
    local ip
    ip=$(backend_get_ip "$name")
    echo "SSH as admin: ssh admin@$ip"
    echo "SSH as user: ssh user@$ip"
}

clone_vm() {
    local source="$1"
    local dest="$2"

    echo "Error: Clone not yet implemented for DigitalOcean backend."
    echo ""
    echo "Workaround: Create a snapshot of '$source', then create '$dest' from that snapshot."
    exit 1
}

destroy_vm() {
    local name="$1"

    if [ ! -d "$MACHINES_DIR/$name" ]; then
        echo "Error: No machine config found for '$name'"
        exit 1
    fi

    _do_validate

    echo "WARNING: This will destroy droplet '$name' on DigitalOcean."
    echo "The /var volume will be PRESERVED for later use."
    echo "(Machine config in $MACHINES_DIR/$name/ will be preserved)"
    read -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi

    echo "Destroying droplet: $name"

    # Get IDs before destroying
    local droplet_id volume_id
    droplet_id=$(do_get_droplet_id "$name" 2>/dev/null || echo "")
    volume_id=$(cat "$MACHINES_DIR/$name/volume_id" 2>/dev/null || echo "")

    # Detach volume first if attached
    if [ -n "$volume_id" ] && [ -n "$droplet_id" ]; then
        echo "Detaching volume..."
        $DOCTL compute volume-action detach "$volume_id" "$droplet_id" --wait 2>/dev/null || true
    fi

    # Destroy droplet
    if [ -n "$droplet_id" ]; then
        $DOCTL compute droplet delete "$droplet_id" --force
        rm -f "$MACHINES_DIR/$name/droplet_id"
    fi

    echo "Droplet destroyed. Volume preserved: $volume_id"
    echo "Machine config preserved: $MACHINES_DIR/$name/"
}

purge_vm() {
    local name="$1"

    if [ ! -d "$MACHINES_DIR/$name" ]; then
        echo "Error: No machine config found for '$name'"
        exit 1
    fi

    _do_validate

    echo "WARNING: This will COMPLETELY remove droplet '$name' and its /var volume."
    echo "All data will be PERMANENTLY LOST."
    read -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi

    echo "Purging: $name"

    local droplet_id volume_id
    droplet_id=$(do_get_droplet_id "$name" 2>/dev/null || echo "")
    volume_id=$(cat "$MACHINES_DIR/$name/volume_id" 2>/dev/null || echo "")

    # Detach and destroy volume
    if [ -n "$volume_id" ]; then
        if [ -n "$droplet_id" ]; then
            echo "Detaching volume..."
            $DOCTL compute volume-action detach "$volume_id" "$droplet_id" --wait 2>/dev/null || true
        fi
        echo "Deleting volume..."
        $DOCTL compute volume delete "$volume_id" --force 2>/dev/null || true
    fi

    # Destroy droplet
    if [ -n "$droplet_id" ]; then
        echo "Deleting droplet..."
        $DOCTL compute droplet delete "$droplet_id" --force 2>/dev/null || true
    fi

    # Remove machine config
    rm -rf "$MACHINES_DIR/$name"
    echo "Droplet '$name' completely removed."
}

recreate_vm() {
    local name="$1"
    local var_size
    var_size=$(normalize_size "${2:-30G}")

    local machine_dir="$MACHINES_DIR/$name"
    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        exit 1
    fi

    _do_validate

    local profile
    profile=$(cat "$machine_dir/profile")
    profile=$(normalize_profiles "$profile")

    echo "WARNING: This will recreate droplet '$name' with a fresh boot disk."
    echo "The existing /var volume will be reattached (data preserved)."
    read -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
        echo "Aborted."
        exit 1
    fi

    # Get volume ID before destroying droplet
    local volume_id
    volume_id=$(cat "$machine_dir/volume_id" 2>/dev/null || echo "")

    # Destroy existing droplet (keeps volume)
    local droplet_id
    droplet_id=$(do_get_droplet_id "$name" 2>/dev/null || echo "")
    if [ -n "$droplet_id" ]; then
        if [ -n "$volume_id" ]; then
            echo "Detaching volume..."
            $DOCTL compute volume-action detach "$volume_id" "$droplet_id" --wait 2>/dev/null || true
        fi
        echo "Destroying old droplet..."
        $DOCTL compute droplet delete "$droplet_id" --force
        rm -f "$machine_dir/droplet_id"
    fi

    # Build fresh image (uses DO format via override)
    build_profile "$profile" "false"

    # Upload if needed
    if ! do_get_or_upload_image "$profile" >/dev/null; then
        do_upload_image "$profile"
    fi

    # Create new droplet
    backend_create_disks "$name" "$var_size"

    echo ""
    echo "Droplet '$name' recreated."
    echo "SSH as admin: ssh admin@$(backend_get_ip "$name")"
}

upgrade_vm() {
    local name="$1"
    local machine_dir="$MACHINES_DIR/$name"

    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        exit 1
    fi

    if is_mutable "$name"; then
        echo "Error: Cannot upgrade mutable VMs from the host."
        echo "SSH into the droplet and run: sudo nixos-rebuild switch"
        exit 1
    fi

    _do_validate

    local profile
    profile=$(cat "$machine_dir/profile")
    profile=$(normalize_profiles "$profile")

    echo "Upgrading droplet '$name' to latest $profile image (preserving /var volume)"

    # Delete old DO image to force re-upload
    local image_id_file="$OUTPUT_DIR/profiles/${profile}-do/do_image_id"
    if [ -f "$image_id_file" ]; then
        local old_image_id
        old_image_id=$(cat "$image_id_file")
        echo "Deleting old image $old_image_id..."
        $DOCTL compute image delete "$old_image_id" --force 2>/dev/null || true
        rm -f "$image_id_file"
    fi

    # Build new image (uses DO format via override)
    build_profile "$profile" "false"

    # Upload new image
    if ! do_get_or_upload_image "$profile" >/dev/null; then
        do_upload_image "$profile"
    fi

    # Recreate droplet with new image
    recreate_vm "$name"

    echo ""
    echo "Droplet '$name' upgraded. /var data preserved."
}

resize_var() {
    local name="$1"
    local new_size
    new_size=$(normalize_size "$2")

    _do_validate

    local volume_id
    volume_id=$(do_get_volume_id "$name")

    # Parse to GB
    local new_size_gb
    new_size_gb=$(echo "$new_size" | sed 's/[Gg]$//')

    echo "Resizing volume $volume_id to ${new_size_gb}GB..."
    echo "Note: DigitalOcean volumes can only be increased, not decreased."

    $DOCTL compute volume-action resize "$volume_id" --size "$new_size_gb" --region "$DO_REGION" --wait

    echo "Volume resized. The filesystem will be extended on next mount."
}

resize_vm() {
    local name="$1"
    local machine_dir="$MACHINES_DIR/$name"

    if [ ! -d "$machine_dir" ]; then
        echo "Error: Machine config not found: $machine_dir"
        exit 1
    fi

    _do_validate

    local droplet_id
    droplet_id=$(do_get_droplet_id "$name")

    echo "Current droplet configuration:"
    $DOCTL compute droplet get "$droplet_id" --format Size,Memory,VCPUs,Disk

    echo ""
    echo "To resize a DigitalOcean droplet:"
    echo "  1. Power off: just stop $name"
    echo "  2. Resize: doctl compute droplet-action resize $droplet_id --size <new-size>"
    echo "  3. Power on: just start $name"
    echo ""
    echo "Available sizes: doctl compute size list"
}

backup_vm() {
    local name="$1"
    _do_validate

    local droplet_id
    droplet_id=$(do_get_droplet_id "$name")

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local snapshot_name="${name}-backup-${timestamp}"

    echo "Creating backup snapshot: $snapshot_name"
    $DOCTL compute droplet-action snapshot "$droplet_id" --snapshot-name "$snapshot_name" --wait

    echo "Backup complete."
}

restore_backup_vm() {
    local name="$1"
    local backup_id="${2:-}"

    echo "To restore from a DigitalOcean snapshot:"
    echo ""
    echo "1. List available snapshots:"
    echo "   doctl compute snapshot list --resource droplet"
    echo ""
    echo "2. Destroy current droplet:"
    echo "   BACKEND=doctl just destroy $name"
    echo ""
    echo "3. Create new droplet from snapshot:"
    echo "   doctl compute droplet create $name --image <snapshot-id> --size <size> --region $DO_REGION"
    echo ""
    echo "4. Reattach the /var volume"
}

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
        echo "Error: Could not determine IP address for droplet '$name'"
        echo "Is the droplet running? Check with: BACKEND=doctl just status $name"
        exit 1
    fi

    echo "Connecting to $name at $ip as $ssh_user..."
    $SSH -o StrictHostKeyChecking=accept-new "$ssh_user"@"$ip"
}

list_backups() {
    _do_validate
    echo "Snapshots on DigitalOcean:"
    $DOCTL compute snapshot list --resource droplet --format ID,Name,Size,CreatedAt
}
