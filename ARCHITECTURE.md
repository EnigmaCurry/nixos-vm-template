# Architecture

For the rationale behind the immutable two-disk design, see
[Why Immutable VMs?](README.md#why-immutable-vms) in the README. For the
read-write alternatives, see [MODES.md](MODES.md).

```
VM Disk Layout:
  vda (boot) - Read-only root filesystem
  vdb (var)  - Read-write /var filesystem

Filesystem Mounts:
  /      - Read-only (from vda)
  /boot  - Read-only (EFI partition on vda)
  /var   - Read-write (from vdb)
  /home  - Bind mount of /var/home
  /root  - Bind mount of /var/root
  /tmp   - tmpfs
```

## Libvirt Specifics

- Boot disk uses QCOW2 with backing file (thin provisioning)
- Multiple VMs share a single base image
- OVMF UEFI firmware with QCOW2 NVRAM (supports snapshots)

## Proxmox Specifics

- Boot disk flattened and imported via `qm importdisk`
- Serial console (no VGA framebuffer)
- QEMU guest agent enabled for IP detection
- Identity sync via `qemu-nbd` mount on PVE node
