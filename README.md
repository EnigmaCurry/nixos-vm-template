# nixos-vm-template

[![Documentation](https://img.shields.io/badge/docs-scroll%20down-blue)](#documentation)

Build and manage immutable NixOS virtual machines on libvirt (KVM) or Proxmox VE (KVM or LXC).

> [!NOTE]
> This code is written using Claude Code and other AI tools. It is reviewed
> and tested by a human being.

## Why Immutable VMs?

Virtual machines accumulate state over time. Install packages, update
configs, add data - and eventually you have a unique snowflake that's
difficult to reproduce or reason about. Snapshots and backups help,
but they capture *everything* - OS, configs, and data all mixed
together.

A better approach: separate the OS from your data.

**Two disks instead of one:**
- **Boot disk** - The operating system (read-only)
- **Data disk** - Your files and application state (`/var`, `/home`)

**Benefits:**
- Snapshots and backups target only what matters - your data
- The OS is immutable - no configuration drift, no surprise changes
- Upgrades are atomic - rebuild the image, swap the boot disk, reboot
- Multiple VMs can share the same base image (thin provisioning)
- Corruption-resistant - the root filesystem can't be modified at runtime

**The tradeoff:** You can't install packages at runtime. If you want
to add packages, you need to rebuild the image. This is because the
root filesystem — including `/nix` — is mounted read-only by design.
This forces infrastructure-as-code practices and ensures every VM is
reproducible from source.

This project builds NixOS images with this architecture. NixOS is
ideal for this because the entire system configuration is declared in
code and built offline. The result is a VM that boots fast, runs
predictably, and can be recreated identically at any time.

## Features

- Works on any Linux host distribution (e.g., NixOS, Fedora, Debian,
  Arch Linux, etc.)
- **Three backends**: local libvirt/KVM, remote Proxmox VE (KVM), or Proxmox LXC containers
- It is a build script to create your own customized NixOS VM images
- Immutable, container-like root filesystem (read-only)
- Even `/etc` is read-only, you need to rebuild the image to reconfigure it
- Separate `/var` disk for all mutable state
- Bind mounted `/home` to `/var/home` and `/root` to `/var/root` (persistent)
- **Optional mutable mode**: standard read-write NixOS for full flexibility
- Snapshots and backups
- Composable VM profiles to customize the VM role (docker, podman, dev, claude, etc.)
- UEFI boot with systemd-boot
- SSH key-only authentication
- QEMU guest agent for IP detection and guest commands
- Static IP or DHCP for bridged VMs (interactive or batch)
- Interactive bridge management (create, add ports, activate)
- Optional zram compressed swap for memory overcommit

## Backends

This project supports three backends, selected via the `BACKEND` environment variable:

| Backend | Guest type | Root | Storage / image | Guide |
|---------|------------|------|-----------------|-------|
| `libvirt` | KVM VM | immutable (or mutable) | QCOW2 boot disk with backing file | [LIBVIRT.md](LIBVIRT.md) |
| `proxmox` | KVM VM | immutable (or mutable) | QCOW2 imported over SSH | [PROXMOX.md](PROXMOX.md) |
| `proxmox-lxc` | LXC container | **mutable only** | rootfs tarball + host **ZFS bind mounts** | [PROXMOX_LXC.md](PROXMOX_LXC.md) |

```bash
# Use libvirt (default)
just create myvm

# Use Proxmox (KVM)
BACKEND=proxmox just create myvm

# Use Proxmox LXC (containers)
BACKEND=proxmox-lxc just create myct
```

You can set `BACKEND` in a `.env` file in the project root to avoid
repeating it:

```bash
echo "BACKEND=proxmox" >> .env
```

> [!NOTE]
> **`proxmox-lxc` is different from the two KVM backends.** A container shares
> the host kernel, so it has no bootloader and its root is read-write — it is
> **mutable-only** (`nixos-rebuild` runs inside; there is no immutable or
> semi-mutable mode). In exchange it can **bind-mount host ZFS datasets directly
> into the guest** (`pct set -mpN`), which a KVM VM cannot do. That makes it the
> right backend for a NAS: the LXC-only **`nas`** profile serves a host ZFS
> dataset over NFS + Samba. See [PROXMOX_LXC.md](PROXMOX_LXC.md).

## Two Ways to Use This

There are two distinct workflows, depending on whether you want to *run*
the published VM images or *build your own*:

| | Production deployment | Development |
|---|---|---|
| **Goal** | Deploy the official, pre-built images | Customize the system and build your own images |
| **Entry point** | `bootstrap.bb` (the `bb` one-liner) | `just` recipes in a cloned repo |
| **Where images come from** | Downloaded from the binary image repository | Built locally with Nix |
| **Requires Nix?** | **No** | **Yes** |
| **Tools needed** | `bb` + a few standard CLI tools | `nix`, `just`, `qemu-img`, `guestfish`, … |

For production you don't need Nix, the `just` build toolchain, or even a
local clone — a single `bb` one-liner downloads pre-built images and creates
VMs from them, and the same one-liner switches to the development build
workflow when Nix is present. See **[BOOTSTRAP.md](BOOTSTRAP.md)** for the
one-liner and how it adapts to each role.

To customize the images — add packages, change configuration, create new
profiles — you build them yourself from a cloned repo with Nix and `just`.
This is the workflow the rest of these docs document, starting with the
requirements below. To publish your *own* binary image repository from your
fork, see [CI.md](CI.md).

## Requirements (Common, for local builds)

> [!NOTE]
> These requirements are for the **development / local-build** workflow. If
> you only want to deploy the pre-built images, see
> [BOOTSTRAP.md](BOOTSTRAP.md) — it does not need Nix or `just`.

- Linux build machine with KVM support
- `nix` package manager (with flakes enabled)

- `just` (command runner)

Those are the only things you install by hand. Every other build tool —
`bb` ([babashka](https://github.com/babashka/babashka), which runs the
VM-management commands), `qemu-img`, and `guestfish` — is provided by this
flake's development shell, and the `just` recipes run themselves inside it
(`nix develop --command …`) automatically. So a bare clone plus Nix and `just`
is enough; there's no need to install the rest through your distro's package
manager or to enter `nix develop` yourself.

## Documentation

Detailed setup and usage live in focused guides:

| Guide | What's inside |
|-------|---------------|
| [BOOTSTRAP.md](BOOTSTRAP.md) | The `bb` one-liner — production (no Nix) and development (with Nix) roles |
| [INSTALL.md](INSTALL.md) | Install Nix + `just`, the `vm`/`pve` shell aliases, tab completion |
| [LIBVIRT.md](LIBVIRT.md) | Libvirt/KVM backend: requirements, host firewall, networking, bridges, storage |
| [PROXMOX.md](PROXMOX.md) | Proxmox VE (KVM) backend: SSH setup, env vars, VMIDs, identity sync, disk formats |
| [PROXMOX_LXC.md](PROXMOX_LXC.md) | Proxmox LXC backend: containers, host ZFS bind mounts, the `nas` profile, privileged mode |
| [COMMANDS.md](COMMANDS.md) | Full `just` command reference (lifecycle, clone, resize, snapshot, backup) |
| [MODES.md](MODES.md) | Immutable vs mutable vs semi-mutable VMs |
| [PROFILES.md](PROFILES.md) | Available profiles, common combinations, zram compressed swap |
| [CONFIGURATION.md](CONFIGURATION.md) | The `machines/<name>/` config files, firewall ports, root password |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Disk layout and per-backend internals |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Common problems and fixes |
| [CLAUDE_CODE.md](CLAUDE_CODE.md) | Claude Code slash-command skills for guided VM management |
| [CI.md](CI.md) | Publish your own binary image repository (Woodpecker CI → S3) |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Nix on Fedora Atomic, distrobox, development notes |
