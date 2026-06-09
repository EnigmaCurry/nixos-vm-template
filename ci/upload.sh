#!/usr/bin/env bash
set -euo pipefail

rclone() { nix run nixpkgs#rclone -- "$@"; }
jq() { nix run nixpkgs#jq -- "$@"; }

echo "Upload images:"
ls -lh output/export/

# Clean up stale multipart uploads from previous failed runs
rclone cleanup "remote:$S3_BUCKET/" -v || true

# Upload new images
rclone copy output/export/ "remote:$S3_BUCKET/" --include '*.qcow2' -v

# Build manifest from newly built images only
manifest='{"profiles":{}}'

for f in output/export/nixos-*.qcow2; do
    filename=$(basename "$f")
    slug="${filename%.qcow2}"
    slug="${slug%-*}"    # strip -SHA
    slug="${slug%-*}"    # strip -YYYYMMDD
    slug="${slug#nixos-}" # strip nixos- prefix
    profile_key=$(echo "$slug" | tr '-' ',')
    date_stamp=$(echo "$filename" | grep -o '[0-9]\{8\}')
    git_sha=$(echo "$filename" | sed 's/.*-\([a-f0-9]*\)\.qcow2$/\1/')
    sha256=$(sha256sum "$f" | cut -d' ' -f1)
    url="${S3_PUBLIC_URL%/}/${filename}"
    manifest=$(echo "$manifest" | jq \
        --arg key "$profile_key" \
        --arg url "$url" \
        --arg filename "$filename" \
        --arg date "$date_stamp" \
        --arg commit "$git_sha" \
        --arg sha256 "$sha256" \
        '.profiles[$key] = {url: $url, filename: $filename, date: $date, commit: $commit, sha256: $sha256}')
done

echo "$manifest" | jq . > /tmp/manifest.json
echo "Manifest:"
cat /tmp/manifest.json
rclone copyto /tmp/manifest.json "remote:$S3_BUCKET/manifest.json" --s3-no-check-bucket -v

# Delete any qcow2 files not referenced in the manifest
manifest_files=$(jq -r '.profiles[].filename' /tmp/manifest.json)
rclone lsf "remote:$S3_BUCKET/" --include 'nixos-*.qcow2' | while read -r bucket_file; do
    if ! echo "$manifest_files" | grep -qxF "$bucket_file"; then
        echo "Deleting stale image: $bucket_file"
        rclone deletefile "remote:$S3_BUCKET/$bucket_file" -v
    fi
done
