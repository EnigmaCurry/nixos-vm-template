#!/usr/bin/env bash
## Push flake.lock update if the local branch is ahead of the remote.
## Run after a successful build+upload to confirm the update.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Ensure git reads the woodpecker user's .gitconfig (insteadOf URL rewrites)
export HOME=/var/lib/woodpecker

BRANCH="${CI_COMMIT_BRANCH:-dev}"

git fetch origin "$BRANCH"

if [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$BRANCH")" ]; then
    echo "Nothing to push."
    exit 0
fi

# Verify the only unpushed commit changes nothing but flake.lock
changed_files=$(git diff --name-only "origin/$BRANCH"..HEAD)
if [ "$changed_files" != "flake.lock" ]; then
    echo "ERROR: unpushed commits contain unexpected changes:"
    echo "$changed_files"
    echo "Refusing to push."
    exit 1
fi

echo "Pushing flake.lock update..."
git push origin "HEAD:$BRANCH"
