# Spike: NixOS in a Proxmox LXC (NAS proof of concept)

A **disposable** experiment to decide whether to build a third backend
(`proxmox-lxc`) alongside the existing `libvirt` and `proxmox` (KVM) backends.

**Why LXC?** A QEMU/KVM VM cannot truly bind-mount a host directory — it can
only *share* one over virtiofs/9p. A Proxmox **LXC** can: `pct set <vmid> -mp0
/tank/nas,mp=/srv/nas` is a first-class host bind mount. That makes LXC the
natural home for a NAS serving a **host-native ZFS dataset**, which is what this
spike proves out, end to end.

This spike is **isolated and additive**: it touches no backend code and adds
nothing to `profiles/`. It is **not** wired into `just` / the `vm`/`pve` CLIs.

## Scope (locked)

- **NFS + Samba only** (TFTP/WebDAV dropped).
- **Privileged container** — kernel `nfsd` does not work in unprivileged Proxmox CTs.
- **Single read-write rootfs** + the host ZFS bind mount at `/srv/nas`. No separate
  `/var` volume, no read-only-root. (The eventual backend is **mutable-only** — LXC
  does not get the immutable/semi-mutable modes, which require a read-only root.)

## Files

| File | Purpose |
|---|---|
| `spike/lxc-nas.nix` | Standalone NixOS LXC module (privileged, NFS + Samba over `/srv/nas`). |
| `flake.nix` | Adds the `lxc-nas-spike` package → `config.system.build.tarball` (additive). |
| `spike/run.bb` | Build → ship to PVE → `pct create` privileged CT + ZFS bind mount + start. |

## Run it

From the repo root, with SSH access to a Proxmox node configured in `~/.ssh/config`:

```bash
# Build only (no Proxmox needed) — confirms the tarball evaluates/builds:
nix build .#lxc-nas-spike --impure --print-out-paths

# Full spike: build, transfer, create the privileged CT, bind-mount the dataset:
PVE_HOST=pve ZFS_DATASET=tank/nas bb spike/run.bb up

# Tear it back down (leaves the ZFS dataset intact):
PVE_HOST=pve VMID=<vmid> bb spike/run.bb down
```

`run.bb` env: `PVE_HOST` (req), `ZFS_DATASET` (req for `up`), `VMID`,
`PVE_STORAGE` (default `local-zfs`), `BRIDGE` (default `vmbr0`), `CORES`,
`MEMORY`, `ROOTFS_SIZE`, `CT_HOSTNAME`, `APPARMOR_UNCONFINED` (set `0` to skip).

The build uses `--impure` so an SSH key (from `ssh-agent` or `~/.ssh/*.pub`) is
baked into the `admin` user. A throwaway password (`nixos`) is always set too,
so console / `pct enter` and password SSH work as a fallback.

> Interactive Proxmox commands (e.g. `pct enter <vmid>`) are easiest to run via
> the session `! <command>` prefix so their output lands in the conversation.

## Verification matrix

| Check | How |
|---|---|
| Tarball builds | `nix build .#lxc-nas-spike --impure` produces a `tar.xz` |
| CT boots NixOS | `pct exec <vmid> -- systemctl is-system-running` (running/degraded ok) |
| Networking | `pct exec <vmid> -- ip -4 addr show eth0` shows an IP; can resolve DNS |
| SSH | `ssh admin@<ct-ip>` succeeds (key or password `nixos`) |
| ZFS bind mount | write `/srv/nas/x` in CT → file appears in the host dataset; and vice-versa |
| NFS | from another host: `showmount -e <ct-ip>`; `mount -t nfs <ct-ip>:/srv/nas /mnt` rw |
| Samba | `smbclient -L //<ct-ip> -N`; put/get a file in the `nas` share |

## Known risks (what this spike exists to resolve)

- **Privileged-CT apparmor vs `nfsd`.** The default Proxmox apparmor profile can
  block kernel `nfsd` even in a privileged CT. `run.bb` appends
  `lxc.apparmor.profile: unconfined` to `/etc/pve/lxc/<vmid>.conf` by default
  (`APPARMOR_UNCONFINED=0` to skip). Confirm the host has `nfsd` available.
- **Networking combo.** We use `--ostype unmanaged` + NixOS-managed DHCP on
  `eth0` (`proxmoxLXC.manageNetwork = true`). Confirm the CT actually gets an IP
  and working DNS; if not, that's the first thing to investigate.
- **NixOS-in-LXC boot quirks.** `/sbin/init`, systemd-in-container, getty on
  `tty1`, journald — mostly handled by nixpkgs' `proxmox-lxc.nix`, but verify.
- **`nesting=1`** is set on the CT (needed for nested mounts / systemd).

## Findings / Decision

Run on Proxmox node `mrfusion` (pool `rust`), CT 103, 2026-06-24. **Result: GO.**

| Check | Result |
|---|---|
| Tarball builds | ✅ `nix build .#lxc-nas-spike --impure` → 246 MB `tar.xz` |
| CT boots NixOS | ✅ systemd up; reached `running` after the `wait-online` fix below |
| Networking / DNS | ✅ DHCP lease `10.13.14.81` on `eth0`, DNS resolves |
| ZFS bind mount | ✅ `findmnt` shows `/srv/nas ← rust/nas (zfs)`; rw **both** directions |
| NFS (kernel nfsd) | ✅ `showmount -e` ok; `mount -t nfs` from another host; write → ZFS |
| Samba | ✅ `nas` share listed; guest `put` from another host → ZFS |

What it took / lessons (feed these into the full backend):

1. **Privileged + `lxc.apparmor.profile: unconfined` is required for kernel `nfsd`.**
   With it, `exportfs`/`nfs-server` work in the LXC. `run.bb` appends this line by
   default. (Proxmox warns it "overrides features:nesting" — benign; unconfined is
   more permissive.)
2. **Networking = `--ostype unmanaged` + `proxmoxLXC.manageNetwork = true` + NixOS
   systemd-networkd DHCP on `eth0`** (combo A) works. Caveat: the CT got an
   **auto-generated MAC** that had to be allowed by the DHCP server. → The real
   backend must **persist/pin a MAC per machine** like the KVM proxmox backend
   already does (`mac-address` in the machine dir), so the address is stable.
3. **`pct exec` uses a minimal PATH; NixOS binaries are under
   `/run/current-system/sw/bin`.** Any backend operation invoking in-CT tools must
   use full paths (or `pct enter`). Fixed in `run.bb`'s printed hints.
4. **`systemd-networkd-wait-online` will fail/degrade** while waiting on DHCP; set
   `systemd.network.wait-online.enable = false` so boot reaches `running` cleanly
   (applied to `lxc-nas.nix`).
5. The bind-mounted dataset appears **as a real `zfs` mount inside the CT**
   (not a plain bind), so per-dataset semantics (xattrs, etc.) carry through.

**Decision:** proceed to author the full **`proxmox-lxc` backend** plan
(mutable-only; `pct`-based; per-machine MAC; host ZFS dataset bind mounts as a
first-class config surface). KVM + virtiofs fallback is **not** needed.
