# Machine Configuration

Each VM has a machine config directory at `machines/<name>/` containing:

- `profile` - Which profile to use
- `mutable` - VM mode: "true" for mutable (single read-write disk), "semi" for semi-mutable (read-only root + writable /nix overlay), absent for immutable
- `hostname` - VM hostname
- `machine-id` - Unique machine identifier
- `uuid` - VM UUID (preserves DHCP lease across upgrades)
- `mac-address` - Network MAC address
- `network` - Network mode (`nat` or `bridge:<name>`)
- `ssh_host_ed25519_key` - SSH host key
- `admin_authorized_keys` - SSH public keys for admin user
- `user_authorized_keys` - SSH public keys for regular user
- `tcp_ports` - TCP ports to open in firewall (one per line)
- `udp_ports` - UDP ports to open in firewall (one per line)
- `root_password_hash` - Root password hash for console login (empty = disabled)
- `resolv.conf` - DNS configuration (default: Cloudflare 1.1.1.1, 1.0.0.1)
- `static_ip` - Static IP config (`address=` and `gateway=` lines); absent = DHCP
- `hosts` - Extra /etc/hosts entries (optional)
- `vmid` - Proxmox VMID (proxmox backend only)

These files are generated during `just create` and preserved across
`just upgrade` and `just recreate`.

## Custom Firewall Ports

To open additional ports for a specific VM, edit `tcp_ports` and/or
`udp_ports` in the machine config directory:

```bash
# Open TCP ports 8080 and 3000
echo "8080" >> machines/myvm/tcp_ports
echo "3000" >> machines/myvm/tcp_ports

# Open UDP port 53
echo "53" >> machines/myvm/udp_ports

# Apply changes
just upgrade myvm
```

Lines starting with `#` are treated as comments.

**How firewall rules are applied:**

| VM Type | Rule Location | Applied By | Update Method |
|---------|---------------|------------|---------------|
| Immutable / Semi-mutable | `/var/identity/tcp_ports`, `/var/identity/udp_ports` | `firewall-identity.service` at boot | `just upgrade` syncs from machine config |
| Mutable | `/etc/firewall-ports/tcp_ports`, `/etc/firewall-ports/udp_ports` | `firewall-ports.service` at boot | `just recreate` (or edit files in VM) |

Both services use iptables to insert rules into the `nixos-fw` chain at boot.
For mutable VMs, you can also edit the files directly inside the VM and reboot,
or manually run `systemctl restart firewall-ports` to apply changes.

## Root Password

By default, all accounts are locked for password authentication (SSH
keys are the only way to log in). To enable root console access for
debugging, you can set a root password:

```bash
just passwd myvm              # Set root password (interactive)
just upgrade myvm             # Apply the change
```

The password hash is stored in `machines/<name>/root_password_hash`.
When this file is empty, root password login is disabled.
