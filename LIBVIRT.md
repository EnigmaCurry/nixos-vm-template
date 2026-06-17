# Libvirt Backend

The default backend. VMs run locally on libvirt/KVM, using QCOW2 backing
files for thin provisioning. See [INSTALL.md](INSTALL.md) for Nix and `just`
setup first.

## Additional Requirements

- libvirt and QEMU
- OVMF (UEFI firmware)

### Fedora

```bash
sudo dnf install git libvirt qemu-kvm virt-manager guestfs-tools edk2-ovmf
sudo systemctl enable --now libvirtd
```

### Debian / Ubuntu

```bash
sudo apt install git libvirt-daemon-system qemu-kvm virt-manager libguestfs-tools ovmf
sudo systemctl enable --now libvirtd
```

### Arch Linux

```bash
sudo pacman -S git libvirt qemu-full virt-manager guestfs-tools edk2-ovmf dnsmasq
sudo systemctl enable --now libvirtd
```

## Host Firewall (UFW)

If your host has UFW enabled, it will block DHCP and NAT traffic on the
libvirt bridge. Allow traffic on `virbr0`:

```bash
sudo ufw allow in on virbr0
sudo ufw allow out on virbr0
sudo ufw route allow in on virbr0
sudo ufw route allow out on virbr0
```

## Quick Start (Libvirt)

```bash
git clone https://github.com/EnigmaCurry/nixos-vm-template ~/nixos-vm-template
cd ~/nixos-vm-template

# Create a VM interactively (prompts for name, profile, resources, etc.)
just create

# Check VM status and get IP address
just status myvm

# SSH into the VM
just ssh myvm              # As 'user' (no sudo)
just ssh admin@myvm        # As 'admin' (has sudo)
```

## Libvirt Storage

The libvirt backend uses QCOW2 backing files for thin provisioning.
Multiple VMs sharing the same profile share a single base image, with
each VM's boot disk storing only the delta (copy-on-write). This means
ten VMs built from the same profile consume roughly the space of one
full image plus their individual deltas.

The Proxmox backend does not use backing files — each VM receives a
full (flattened) copy of the boot disk. Storage-level deduplication
(e.g., ZFS) can offset this, but there is no per-profile thin
provisioning at the QCOW2 layer.

## Bridged Networking (Libvirt)

By default, VMs use NAT networking via libvirt's `virbr0` bridge. This
gives VMs internet access but they're not directly accessible from
other machines on your LAN.

For bridged networking, VMs connect directly to your physical network
and get IP addresses from your network's DHCP server (or use a static
IP). This requires a bridge interface on the host.

### Interactive Bridge Setup

When you select "Bridge" during `just create`, an interactive picker
shows available bridges with their state, IP address, and physical
interfaces:

```
Select network bridge:
  br0 (up, 10.13.14.1/24, enp6s0)
  br1 (down)
  Create new bridge
```

The wizard will guide you through:
- **Creating a bridge** if none exist (or choose "Create new bridge")
- **Adding a physical interface** if the bridge has no ports
- **Bringing the bridge up** if it's currently down

All bridge management uses NetworkManager (`nmcli`) so connections
persist across reboots.

### Manual Bridge Setup

You can also set up bridges manually:

```bash
# Create the bridge
sudo nmcli connection add type bridge ifname br0 con-name br0 stp no

# Add your physical interface (replace enp6s0)
sudo nmcli connection add type bridge-slave ifname enp6s0 master br0

# Bring up the bridge (WARNING: briefly disconnects network!)
sudo nmcli connection down "Wired connection 1" && sudo nmcli connection up br0
```

### Static IP Configuration

When using bridged networking, you can assign a static IP instead of
relying on DHCP. The interactive wizard prompts for DHCP vs Static
after bridge selection:

```
IP address configuration:
  DHCP (automatic)
  Static IP
```

If you choose Static IP, you'll be prompted for:
- **IP address** with CIDR notation (e.g., `10.13.14.5/24`) — the bridge
  subnet is auto-detected and shown as the example
- **Gateway** — discovered from the host routing table, or defaults to
  `.1` on the subnet
- **DNS servers** — choose from gateway, Cloudflare, Google, or custom

The CIDR mask (`/24`) is automatically appended if you enter a bare IP
address.

Static IP config is saved in `machines/<name>/static_ip` and applied
at boot. Remove this file and run `just upgrade` to switch back to
DHCP.

### Changing Network Mode

```bash
just network-config myvm bridge
just upgrade myvm             # Apply the change
```
