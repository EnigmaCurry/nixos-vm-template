#!/usr/bin/env bash
## Push flake.lock update if the local branch is ahead of the remote.
## Run after a successful build+upload to confirm the update.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ "$(git rev-parse HEAD)" = "$(git rev-parse @{u})" ]; then
    echo "Nothing to push."
    exit 0
fi

# Verify the only unpushed commit changes nothing but flake.lock
changed_files=$(git diff --name-only @{u}..HEAD)
if [ "$changed_files" != "flake.lock" ]; then
    echo "ERROR: unpushed commits contain unexpected changes:"
    echo "$changed_files"
    echo "Refusing to push."
    exit 1
fi

echo "Pushing flake.lock update..."
git push
