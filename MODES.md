# VM Modes

VMs come in three modes. **Immutable** is the default — a read-only root
filesystem on a separate boot disk, with all state on a `/var` disk (see
[ARCHITECTURE.md](ARCHITECTURE.md)). The two alternatives below trade some of
that immutability for runtime flexibility.

The mode is stored in `machines/<name>/mutable`: absent for immutable,
`"semi"` for semi-mutable, `"true"` for mutable.

## Mutable VMs

While immutable VMs are the default, sometimes you need a traditional
read-write NixOS system. Mutable VMs provide:

- **Single disk** instead of boot + var disks
- **Full nix toolchain** - run `nix-env`, `nixos-rebuild`, etc.
- **Standard NixOS experience** - install packages, modify configs at runtime
- **Same profiles** - all composable profiles work with mutable VMs
- **Works with both backends** - libvirt and Proxmox

**When to use mutable VMs:**
- You need to run `nixos-rebuild switch` inside the VM
- You want to experiment with NixOS configuration interactively
- You need full `nix` command access
- You're doing NixOS development or testing
- You're using the LXC backend which requires mutable mode.

**Tradeoffs:**
- No thin provisioning (each VM gets a full disk copy)
- Cannot use `just upgrade` from the host (must upgrade inside VM)
- Loses the corruption-resistance of a read-only root

You can still treat a mutable VM as stateless -- if you attach a
remote NAS drive to the VM and store all your important state there,
the VM itself can disposed of and recreated at will (discarding
everything not already stored on the NAS), and then you would just
need to re-attach the NAS on the fresh instance, to restore that
state.

Use `just mutable` to toggle mutable mode for an existing machine config:

```bash
just mutable myvm      # Interactive prompt to enable/disable
just recreate myvm     # Apply the change
```

Or create the `mutable` file manually before creating a new VM:

```bash
# Libvirt
mkdir -p machines/myvm
echo "true" > machines/myvm/mutable
just create myvm docker,dev

# Proxmox
mkdir -p machines/myvm
echo "true" > machines/myvm/mutable
BACKEND=proxmox just create myvm docker,dev
```

### Upgrading Mutable VMs

Mutable VMs cannot be upgraded from the host with `just upgrade`. Ship the
latest workstation checkout with `sync-identity`, then rebuild inside the
VM:

```bash
just sync-identity myvm
just ssh admin@myvm
sudo nixos-rebuild switch --flake /etc/nixos
```

`sync-identity` stages `/etc/nixos/{flake.nix,flake.lock,modules,profiles,src}`
on the VM as a *snapshot* of the workstation's working tree — whatever branch
is checked out and any uncommitted edits are included, and `flake.lock` is
copied verbatim so both sides pin the same nixpkgs. There is no git remote
pull; to promote new code to the VM, run `sync-identity` again.

### When `nixos-rebuild` is enough vs. when to recreate

For feature development, most workstation changes land on the VM with
`sync-identity` + `nixos-rebuild switch`. A few knobs live outside the
NixOS system and require `just recreate`, which **destroys the rootfs**
— including `/var/lib/traefik/acme.json`, container-local caches, and
anything else not on a separate disk. (Immutable / semi-mutable VMs have
a separate /var disk that survives recreate; mutable VMs and LXC
containers put /var on the rootfs.)

| Change type | Applies with | Preserves rootfs |
|---|---|---|
| Any `.nix` file (`profiles/`, `modules/`) | `sync-identity` + `nixos-rebuild switch` | ✓ |
| Any `src/` referenced by a profile via `callPackage` | `sync-identity` + `nixos-rebuild switch` | ✓ |
| `flake.lock` bump (nixpkgs version) | `sync-identity` + `nixos-rebuild switch` | ✓ |
| Any identity file (SSH keys, `hosts`, `resolv.conf`, `wg_users`, `nas_acl`, …) | `sync-identity` (unit-restart handles reload) | ✓ |
| `tcp_ports` / `udp_ports` | `sync-identity` (firewall re-applied) | ✓ |
| `memory` / `vcpus` | `just generate-config` (host-side `qm set` / `pct set`) | ✓ |
| LXC bind mounts (`mounts`) | `just recreate` — sync-identity does not re-apply | ✗ |
| LXC features (`privileged`, apparmor, nesting) | `just recreate` | ✗ |
| LXC rootfs storage backend | `just recreate` | ✗ |
| Disk size (mutable KVM single disk) | `just recreate` | ✗ |

If you need to recreate a mutable VM or LXC container without losing
Traefik certs, back them up first:

```bash
# LXC:
ssh <pve-host> "pct exec <vmid> -- cat /var/lib/traefik/acme.json" > acme.json.bak
BACKEND=proxmox-lxc just recreate myvm
ssh <pve-host> "pct exec <vmid> -- tee /var/lib/traefik/acme.json" < acme.json.bak
ssh <pve-host> "pct exec <vmid> -- chown traefik:traefik /var/lib/traefik/acme.json && \
                pct exec <vmid> -- chmod 600 /var/lib/traefik/acme.json && \
                pct exec <vmid> -- systemctl restart traefik"
```

### Mutable VM Internals

| Feature | Immutable VM | Mutable VM |
|---------|--------------|------------|
| Disk layout | Boot disk + var disk | Single disk |
| Root filesystem | Read-only | Read-write |
| Identity files | `/var/identity/` | `/etc/` (hostname, machine-id, SSH keys) |
| Firewall rules | `/var/identity/tcp_ports` | `/etc/firewall-ports/tcp_ports` |
| Static IP | `/var/identity/static_ip` | `/etc/network-config/static_ip` |
| Root password | `/var/identity/root_password_hash` | `/etc/root_password_hash` |
| Upgrade method | `just upgrade` from host | `nixos-rebuild` inside VM |
| Thin provisioning | Yes (QCOW2 backing files) | No (full disk copy) |

## Semi-Mutable VMs

Semi-mutable VMs offer a middle ground: the root filesystem remains
read-only (like immutable VMs), but `/nix` is writable via an overlayfs
overlay. This lets you install packages at runtime with `nix profile
install` while keeping the base system immutable and upgradeable from
the host.

**Important caveat:** The /nix overlay is wiped on every `just upgrade`.
User-installed packages must be reinstalled after each upgrade. This is
by design — the overlay becomes inconsistent when the base image changes,
so a clean wipe is the only safe upgrade path.

- **Read-only root** - same corruption resistance as immutable VMs
- **Writable /nix** - install packages at runtime via overlay
- **Two-disk layout** - same as immutable (boot disk + var disk, thin provisioned)
- **Host-upgradeable** - `just upgrade` works (overlay is wiped on each upgrade)
- **Survives reboots** - installed packages persist across reboots

**When to use semi-mutable VMs:**
- You want an immutable base but need to install a few extra packages at runtime
- You want `nix profile install` without committing to a fully mutable system
- You want the upgrade simplicity of immutable VMs

Use `just mutable` to select semi-mutable mode for an existing machine config:

```bash
just mutable myvm      # Select "Semi-mutable" from the interactive prompt
just upgrade myvm      # Apply the change (preserves /var data)
```

Or set the `mutable` file manually before creating a new VM:

```bash
mkdir -p machines/myvm
echo "semi" > machines/myvm/mutable
just create myvm docker,dev
```

### Upgrading Semi-Mutable VMs

Semi-mutable VMs are upgraded the same way as immutable VMs:

```bash
just upgrade myvm
```

The upgrade rebuilds the base image, replaces the boot disk, and **wipes
the /nix overlay**. Any packages installed via `nix profile install`
will need to be reinstalled after upgrade.

### Semi-Mutable VM Internals

| Feature | Immutable VM | Semi-Mutable VM | Mutable VM |
|---------|--------------|-----------------|------------|
| Root filesystem | Read-only | Read-only | Read-write |
| /nix | Read-only | Writable (overlay) | Read-write |
| Disk layout | Boot + var | Boot + var | Single disk |
| Thin provisioning | Yes | Yes | No |
| `nix profile install` | No | Yes | Yes |
| Upgrade method | `just upgrade` | `just upgrade` (wipes overlay) | `nixos-rebuild` inside VM |
| Nix GC | Disabled | Enabled (weekly) | Enabled (weekly) |
