#!/usr/bin/env bash
## Run nix garbage collection if disk space is low.
## Threshold can be set via NIX_GC_THRESHOLD (default: 20G).
set -euo pipefail

THRESHOLD="${NIX_GC_THRESHOLD:-20}"  # in GB
STORE_PATH="/nix"

avail_kb=$(df --output=avail "$STORE_PATH" | tail -1 | tr -d ' ')
avail_gb=$((avail_kb / 1024 / 1024))

echo "Nix store: ${avail_gb}G available (threshold: ${THRESHOLD}G)"

if [ "$avail_gb" -lt "$THRESHOLD" ]; then
    echo "Disk space low, running nix garbage collection..."
    nix-collect-garbage
    avail_kb=$(df --output=avail "$STORE_PATH" | tail -1 | tr -d ' ')
    avail_gb=$((avail_kb / 1024 / 1024))
    echo "After GC: ${avail_gb}G available"
else
    echo "Disk space OK, skipping GC."
fi
