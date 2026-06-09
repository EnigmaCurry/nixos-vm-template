# CI Setup Guide

This project uses [Woodpecker CI](https://woodpecker-ci.org/) to
automatically build NixOS VM images and publish them to S3-compatible
storage.

## Prerequisites

- A [Forgejo](https://forgejo.org/) instance (self-hosted Git server)
- A Woodpecker CI server connected to your Forgejo instance
- An S3-compatible storage bucket (e.g., DigitalOcean Spaces, AWS S3,
  MinIO)
- A Proxmox VE host (for running the CI agent VM)

If you don't already have Forgejo and Woodpecker deployed, you can use
[d.rymcg.tech](https://github.com/EnigmaCurry/d.rymcg.tech), which
includes Docker Compose configurations for both services.

## 1. Push to Forgejo

Create a repository on your Forgejo instance and push
nixos-vm-template to it:

```bash
git remote add forgejo git@forgejo.example.com:youruser/nixos-vm-template.git
git push forgejo master
```

## 2. Create the Woodpecker Agent VM

The CI agent runs as a NixOS VM on your Proxmox host using the
`woodpecker` profile in semi-mutable mode. Semi-mutable mode provides
a writable Nix store overlay on `/var`, which caches build
dependencies between runs but resets on upgrade.

### Create the agent environment file

Create `machines/woodpecker/woodpecker.env` with your Woodpecker
server connection details:

```
WOODPECKER_SERVER=woodpecker-grpc.example.com:443
WOODPECKER_AGENT_SECRET=your-shared-agent-secret
```

The agent secret is configured on the Woodpecker server. Refer to the
[Woodpecker admin docs](https://woodpecker-ci.org/docs/administration/configuration/server)
for `WOODPECKER_AGENT_SECRET`.

### Create and deploy the VM

```bash
BACKEND=proxmox just create woodpecker
```

Select the following during the interactive setup:

- **Mode**: Semi-mutable
- **Profile**: woodpecker
- **Memory**: 8G or more (Nix builds are memory-intensive)
- **vCPUs**: 4 or more
- **Disk**: 100G or more (for Nix store cache)

Once the VM boots, verify the agent is connected:

```bash
just ssh admin@woodpecker
journalctl -u woodpecker-agent-exec -f
```

You should see `starting Woodpecker agent` with no errors.

## 3. Set Up S3 Storage

Create an S3-compatible bucket for storing built images. For
DigitalOcean Spaces:

1. Create a Space (e.g., `nixos-vm-template`)
2. Generate an API key with read/write access to the Space
3. Note the endpoint (e.g., `nyc3.digitaloceanspaces.com`)

## 4. Configure CI Secrets

The pipeline needs S3 credentials to upload images. Configure them
using the provided Justfile recipe.

Find your `WOODPECKER_SERVER` and `WOODPECKER_TOKEN` values at
`https://woodpecker.example.com/user/cli-and-api` (replace with your
Woodpecker server URL).

```bash
export WOODPECKER_SERVER=https://woodpecker.example.com
export WOODPECKER_TOKEN=your-api-token
just ci-secrets
```

This will prompt for:

- **Repository**: The Forgejo repo name (e.g., `youruser/nixos-vm-template`)
- **S3 bucket name**: The name of your storage bucket
- **S3 provider**: e.g., `DigitalOcean`, `AWS`, `Minio`
- **S3 endpoint**: e.g., `nyc3.digitaloceanspaces.com`
- **S3 region**: e.g., `nyc3`, `us-east-1`
- **Access key ID**: Your S3 access key
- **Secret access key**: Your S3 secret key

## 5. Pipeline

The pipeline is defined in `.woodpecker.yml`. By default it:

1. **Builds** the `core` profile image using `nix build`
2. **Exports** it with a release filename
   (e.g., `nixos-core-20260609-abc1234.qcow2`)
3. **Uploads** to S3, replacing any previous image for the same profile

The pipeline triggers on push to `master` and can be run manually from
the Woodpecker UI on any branch.

### Adding more profiles

Edit `.woodpecker.yml` to build additional profiles:

```yaml
steps:
  - name: build
    image: bash
    commands:
      - source backends/common.sh && build_profile core
      - source backends/common.sh && export_profile core
      - source backends/common.sh && build_profile core,docker
      - source backends/common.sh && export_profile core,docker
```

## 6. Upgrading the Agent

To update the agent VM with a new base image:

```bash
BACKEND=proxmox just upgrade woodpecker
```

This rebuilds the boot image and preserves `/var` (including the Nix
store cache). The agent will reconnect to the Woodpecker server
automatically after reboot.
