# Troubleshooting

## libguestfs / supermin failure on Ubuntu

If `just create` fails with a `supermin` error like:

```
libguestfs: error: /usr/bin/supermin exited with error status 1.
```

This is because Ubuntu ships kernel images in `/boot/` without
world-read permissions. `guestfish` uses `supermin` to build a
lightweight appliance VM (booted with the host kernel) for safe disk
manipulation without root access. Without read access to the kernel,
it can't build the appliance.

Fix it:

```bash
sudo chmod 644 /boot/vmlinuz-*
```

To persist across kernel updates:

```bash
echo 'DPkg::Post-Invoke {"chmod 644 /boot/vmlinuz-*"};' \
  | sudo tee /etc/apt/apt.conf.d/99-vmlinuz-permissions
```

Fedora and Arch don't have this issue (kernels are world-readable by
default).
