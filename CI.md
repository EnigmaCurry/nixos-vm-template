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
git remote add forgejo git@forgejo.example.com:your_user/nixos-vm-template.git
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
export CI_REPO=your_user/nixos-vm-template
export S3_BUCKET=nixos-vm-template
export S3_PUBLIC_URL=https://nixos-vm-template.nyc3.cdn.digitaloceanspaces.com
export S3_PROVIDER=DigitalOcean    # or AWS, Minio
export S3_ENDPOINT=nyc3.digitaloceanspaces.com
export S3_REGION=nyc3
export S3_ACCESS_KEY_ID=your-access-key
just ci-secrets
```

The recipe will prompt for the S3 secret access key interactively.

## 5. Deploy Keys

The CI pipeline can push `flake.lock` updates back to the repository
after a successful build. This requires SSH deploy keys so the
Woodpecker agent can authenticate with the git remote.

### Setup

Generate a keypair for each repository the agent needs write access to:

```bash
ssh-keygen -t ed25519 -N "" -f nixos-vm-template
```

On the VM, place the files in `/var/identity/deploy_keys/`:

```
/var/identity/deploy_keys/nixos-vm-template        # private key
/var/identity/deploy_keys/nixos-vm-template.pub     # public key (optional, unused)
/var/identity/deploy_keys/nixos-vm-template.conf    # connection config
```

The `.conf` file maps the key to a specific remote:

```ini
host=git.example.com
port=2222
owner=your_user
repo=nixos-vm-template
```

For GitHub (standard SSH port 22), `port` can be omitted.

Add the public key as a deploy key on the repository with **write
access** enabled.

### How it works

At boot, the `woodpecker-deploy-keys` systemd service reads all
`*.conf` files from `/var/identity/deploy_keys/` and generates:

- **`~woodpecker/.ssh/config`** — an SSH host alias per key with the
  correct hostname, port, and identity file
- **`~woodpecker/.gitconfig`** — `url.<alias>.insteadOf` rules that
  transparently rewrite git remote URLs to use the correct alias

This means pipeline scripts use normal git remote URLs and the right
deploy key is selected automatically.

### Verify

After setup (or after an upgrade that adds the service), verify:

```bash
sudo systemctl restart woodpecker-deploy-keys
journalctl -u woodpecker-deploy-keys
sudo -u woodpecker -H sh -c 'cd ~ && git ls-remote ssh://git@git.example.com:2222/your_user/nixos-vm-template.git'
```

### Managing keys

Keys can be managed either from the workstation (in
`machines/<vm>/deploy_keys/`, synced via `just upgrade`) or directly
on the VM (in `/var/identity/deploy_keys/`). Pick one approach per VM
and stick with it to avoid drift.

## 6. Pipeline

The pipeline is defined in `.woodpecker.yml`. By default it:

1. **Updates** flake inputs (`nix flake update`) to track the latest
   nixpkgs and other upstream dependencies
2. **Builds** profile images using `nix build`
3. **Exports** them with release filenames
   (e.g., `nixos-core-20260609-abc1234.qcow2`)
4. **Uploads** to S3, replacing any previous image for the same profile
5. **Updates** `manifest.json` in the bucket root with URLs and sha256
   checksums for all available images
6. **Pushes** the updated `flake.lock` back to the repository (only if
   the build and upload succeeded, and only if `flake.lock` changed)

The pipeline triggers on push to `master`, on manual runs, and on cron
events. To set up automatic rolling releases, configure a cron
schedule in the Woodpecker UI (e.g., daily or weekly) for the `master`
branch.

### Adding more profile builds

Edit `.woodpecker.yml` to build additional profiles:

```yaml
steps:
  - name: build
    image: bash
    commands:
      - nix run nixpkgs#babashka -- -m vm.cli build core
      - nix run nixpkgs#babashka -- -m vm.cli export core
      - nix run nixpkgs#babashka -- -m vm.cli build core,docker
      - nix run nixpkgs#babashka -- -m vm.cli export core,docker
```

## 7. Upgrading the Agent

To update the agent VM with a new base image:

```bash
BACKEND=proxmox just upgrade woodpecker
```

This rebuilds the boot image and preserves `/var` (including the Nix
store cache). The agent will reconnect to the Woodpecker server
automatically after reboot.
