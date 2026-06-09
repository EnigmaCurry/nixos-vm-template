#!/usr/bin/env bash
## Update flake inputs (excluding pinned ones) and commit if changed.
## Run this before building to get a rolling nixos release.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Inputs safe to auto-update. opencode is intentionally pinned to a release tag.
INPUTS=(nixpkgs home-manager sway-home nix-flatpak nifty-filter)

echo "Updating flake inputs: ${INPUTS[*]}"
for input in "${INPUTS[@]}"; do
    nix flake update "$input"
done

if git diff --quiet flake.lock; then
    echo "flake.lock unchanged, nothing to commit."
else
    echo "flake.lock updated, committing..."
    git add flake.lock
    git commit -m "flake.lock: update inputs"
    git push
fi
