# Proxmox VE router platform

Turn a working PVE + admin VM (built via [PROXMOX_INSTALL.md](PROXMOX_INSTALL.md))
into an airgapped router platform: onboard/PCIe NICs freed for PCI
passthrough to a router VM, management traffic isolated on a USB-NIC
bridge, prod VMs on a separate bridge serviced by the router VM.

## Prerequisites

- Everything in [PROXMOX_INSTALL.md's prereqs](PROXMOX_INSTALL.md#prerequisites),
  plus:
- Target machine has **VT-x/AMD-V + IOMMU (VT-d/AMD-Vi)** enabled in firmware
- **≥ 2 onboard/PCIe NICs** to reserve for passthrough (WAN + LAN for the router VM)
- **USB Ethernet adapter** — becomes PVE's management NIC once the onboard NICs are freed
- Workstation has a second physical NIC (built-in or USB) to direct-link to PVE's USB NIC

## 1. Complete PROXMOX_INSTALL.md first

Follow [PROXMOX_INSTALL.md](PROXMOX_INSTALL.md) end-to-end. When
finished you'll have:

- PVE installed on your LAN via `vmbr0` (onboard NIC uplink)
- `nixos` cloud-init template on PVE
- Admin VM (VMID `100`) on `vmbr0` with DHCP'd LAN address
- `pve-admin` SSH alias on your workstation, `pve` SSH alias on admin,
  `pve.env` on admin with `BACKEND=proxmox PVE_HOST=pve PVE_STORAGE=local-zfs PVE_BRIDGE=vmbr0`
- `pve list` from admin returns cleanly

The rest of this doc reconfigures that setup: adds a USB NIC as the
only management path, moves admin off `vmbr0` onto an isolated `mgmt`
bridge, destroys `vmbr0`, and binds the onboard NICs to `vfio-pci` for
router VM passthrough.

## 2. Create the `mgmt` bridge on PVE

Plug the USB Ethernet adapter into PVE. From your workstation, SSH to
PVE (still reachable via the LAN uplink on vmbr0) and find the USB
NIC's interface name:

```bash
ssh pve
ip -br link | grep -Ev '^(lo|vmbr|tap|fwpr|fwln|veth)'
```

The newly-appeared one is the USB NIC (often `enx<mac>` or `usb0`).
Pin it in a shell var:

```bash
export USB_NIC=<usb-nic-name>
```

Write a bridge drop-in that fronts the USB NIC and gives PVE
`192.168.100.1`:

```bash
cat > /etc/network/interfaces.d/mgmt <<EOF
auto mgmt
iface mgmt inet static
    address 192.168.100.1/24
    bridge-ports $USB_NIC
    bridge-stp off
    bridge-fd 0
EOF

ifreload -a
```

Verify:

```bash
ip -br addr show mgmt      # UP, 192.168.100.1/24
bridge link show mgmt      # $USB_NIC as member
```

`vmbr0` still carries the LAN uplink and admin VM keeps its DHCP
address, so nothing has broken yet — `mgmt` is idle until step 3
hooks up the workstation.

**Caveat:** PVE's web UI expects bridge names matching `vmbr\d+` and
won't offer `mgmt` in the GUI network dropdown. Fine here since
everything downstream (`qm`, `nixos-vm-template`) drives PVE via the
CLI, not the GUI.

## 3. Workstation direct-link + tinyproxy

Cable your workstation directly to PVE's USB NIC. Statically assign
your workstation NIC to the same `/24`:

```bash
nmcli con add type ethernet ifname enpXsY con-name pve-mgmt \
  ipv4.method manual ipv4.addresses 192.168.100.2/24
nmcli con up pve-mgmt
```

Trust the direct-link NIC so your firewall doesn't drop pings or the
proxy port (ephemeral; add `networking.firewall.trustedInterfaces` on
NixOS, or the equivalent on your distro, to persist):

```bash
sudo iptables -I INPUT 1 -i enpXsY -j ACCEPT
```

Verify from your workstation:

```bash
ssh root@192.168.100.1 hostname
```

Now run tinyproxy on the workstation — PVE will need it once step 6
removes `vmbr0` (which currently carries the LAN uplink), and admin
will need it too once we move it to `mgmt` in step 4. Tinyproxy is
config-file-driven (no CLI equivalents for `Listen`/`Allow`), so pipe
the config in as a process-substituted file:

```bash
nix run nixpkgs#tinyproxy -- -d -c <(cat <<'EOF'
Port 8888
Listen 192.168.100.2
Allow 192.168.100.0/24
EOF
)
```

Keep this terminal open (or run in tmux). This is the **permanent**
internet path for PVE and mgmt-side VMs — plan for it to run any time
you need to `apt-get` on PVE or `nix` on admin.

Point PVE's apt + shell at the proxy so nothing breaks when `vmbr0`
goes away in step 6:

```bash
ssh pve

cat > /etc/apt/apt.conf.d/99proxy <<'EOF'
Acquire::http::Proxy  "http://192.168.100.2:8888/";
Acquire::https::Proxy "http://192.168.100.2:8888/";
EOF

cat > /etc/profile.d/proxy.sh <<'EOF'
export http_proxy=http://192.168.100.2:8888/
export https_proxy=http://192.168.100.2:8888/
export no_proxy=localhost,127.0.0.0/8,192.168.100.0/24
EOF
. /etc/profile.d/proxy.sh
```

Verify — the request should show up in the tinyproxy terminal:

```bash
apt-get update
```

## 4. Move the admin VM to `mgmt`

### 4a. Add `proxy.nix` on admin (still on vmbr0)

While admin still has LAN internet via vmbr0, SSH in from your
workstation and add a NixOS proxy module that persists across
reboots. Two things need the proxy: the root/user shell running `nix`
and the `nix-daemon`.

```bash
ssh pve-admin
sudo -i

cat > /etc/nixos/proxy.nix <<'EOF'
# Workstation tinyproxy is admin's only route to the internet
# (mgmt has no upstream). Remove once the router VM is up and admin
# gets a NIC on vmbr1 with routed internet.
{
  systemd.services.nix-daemon.environment = {
    http_proxy  = "http://192.168.100.2:8888/";
    https_proxy = "http://192.168.100.2:8888/";
    no_proxy    = "localhost,127.0.0.0/8,192.168.100.0/24";
  };
  environment.sessionVariables = {
    http_proxy  = "http://192.168.100.2:8888/";
    https_proxy = "http://192.168.100.2:8888/";
    no_proxy    = "localhost,127.0.0.0/8,192.168.100.0/24";
  };
}
EOF

# Insert ./proxy.nix into the modules list, right before the mutable
# template's "# VM-specific settings" anchor. \1 preserves indentation.
sed -i 's|^\([[:space:]]*\)# VM-specific settings$|\1./proxy.nix\n\1# VM-specific settings|' /etc/nixos/flake.nix

nixos-rebuild switch
exit
```

### 4b. Point admin's SSH alias + `pve.env` at the mgmt topology

Still on admin (as `admin`), update `~/.ssh/config`'s `Host pve` entry
so it resolves to PVE's mgmt IP after the move:

```bash
sed -i '/^Host pve$/,/^$/ s|^  HostName .*|  HostName 192.168.100.1|' ~/.ssh/config
```

Update `pve.env` — new prod VMs default to `vmbr1` (created in step 5):

```bash
sed -i 's|^PVE_BRIDGE=.*|PVE_BRIDGE=vmbr1|' ~/.config/nixos-vm-template/pve.env
```

Log out — admin is about to be reconfigured out from under you:

```bash
exit
```

### 4c. Rebridge admin on PVE

From your **workstation**, SSH to PVE via the mgmt direct link (don't
use `pve-admin` — it's about to go offline):

```bash
ssh root@192.168.100.1

qm shutdown 100
# wait ~10s for graceful shutdown
qm set 100 --net0 virtio,bridge=mgmt
qm set 100 --ipconfig0 ip=192.168.100.100/24,gw=192.168.100.1
qm start 100
```

### 4d. Update workstation `pve-admin` alias

On your **workstation**, point `Host pve-admin` at the new mgmt IP:

```bash
sed -i '/^Host pve-admin$/,/^$/ s|^  HostName .*|  HostName 192.168.100.100|' ~/.ssh/config
```

Wait ~30s for cloud-init/networkd to apply the new address on admin,
then verify end-to-end:

```bash
ssh pve-admin              # workstation → admin over mgmt
pve list                   # admin → PVE via pve alias (192.168.100.1)
```

## 5. Create `vmbr1` — the prod bridge

`vmbr1` is the L2 fabric for prod VMs. PVE gets no IP on it — the
router VM (built in step 8) is its sole upstream. On PVE:

```bash
ssh root@192.168.100.1

cat > /etc/network/interfaces.d/vmbr1 <<'EOF'
auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF

ifreload -a
```

Verify:

```bash
ip -br link show vmbr1     # UP, no address
bridge link show vmbr1     # exists, no ports
```

## 6. Destroy `vmbr0`

`vmbr0` still owns the onboard NIC and the LAN uplink. Once removed,
the onboard NIC is a plain interface (no bridge membership) and free
for `vfio-pci` binding in step 7. Also unplug the LAN cable — PVE is
now airgapped on `mgmt`.

Before destroying, note the onboard NIC MAC addresses — you'll need
them in step 8 for `systemd.link` name pinning inside the router VM:

```bash
for iface in $(ls /sys/class/net | grep -Ev '^(lo|vmbr|tap|fwpr|fwln|veth|bond|mgmt)'); do
  echo "$iface: $(cat /sys/class/net/$iface/address)"
done
```

Save the output somewhere safe (a note on your workstation, a comment
in `machines/router/default.nix`).

Edit `/etc/network/interfaces` on PVE. Delete the `auto vmbr0` +
`iface vmbr0 inet ...` stanza (and any `iface <onboard-nic>` stanzas
— those NICs stay unbound). Then reboot:

```bash
reboot
```

Wait ~60s, then verify from your workstation direct link:

```bash
ssh root@192.168.100.1
ip -br link show           # no vmbr0
apt-get update             # still works via tinyproxy
```

## 7. PVE passthrough prep

Detect CPU vendor:

```bash
grep -m1 -o -e vmx -e svm /proc/cpuinfo    # vmx=Intel, svm=AMD
```

Edit `/etc/default/grub` and append the IOMMU flag to
`GRUB_CMDLINE_LINUX_DEFAULT`:

- Intel: `intel_iommu=on iommu=pt`
- AMD: `amd_iommu=on iommu=pt`

Then:

```bash
update-grub
```

Find the onboard NIC PCI IDs:

```bash
lspci -nn | grep -i ether
# example: 02:00.0 Ethernet controller [0200]: Intel ... I210 [8086:1533]
```

Bind them to `vfio-pci` (the `ids=` list is the `[vendor:device]`
part; both onboard NICs of the same model share one ID):

```bash
cat > /etc/modprobe.d/vfio.conf <<'EOF'
options vfio-pci ids=8086:1533
EOF

cat > /etc/modules-load.d/vfio.conf <<'EOF'
vfio
vfio_iommu_type1
vfio_pci
EOF

update-initramfs -u -k all
reboot
```

Verify after PVE comes back:

```bash
ssh root@192.168.100.1
lspci -nnk | grep -A3 -i ether
# expect: 'Kernel driver in use: vfio-pci' on both NICs
```

The onboard NICs should each be in their own IOMMU group (a shared
group means both NICs must be passed through together — usually fine
for a router VM):

```bash
for d in /sys/kernel/iommu_groups/*; do
  echo "IOMMU group $(basename $d):"
  for dev in $d/devices/*; do
    lspci -nns "$(basename $dev)"
  done
done | grep -B1 -i ether
```

## 8. Router VM with `nftables` + NIC passthrough

The [`nftables`](profiles/nftables.nix) profile loads its ruleset from
`/var/identity/nftables.conf` and pairs with the wizard's PCI picker
(added on this branch — same mechanism as the GPU picker documented
in [PROXMOX.md](PROXMOX.md#gpu-passthrough), filtered to
network-class devices).

From admin:

```bash
ssh pve-admin
cd ~/nixos-vm-template
pve create router
```

In the wizard, select:

- **Profile:** `nftables`
- **Network:** `bridge:vmbr1` (router's virtio NIC on the prod bridge)
- **PCI passthrough:** pick both onboard NICs (WAN + LAN) from the list

Before starting the VM, wire the two remaining router-specific bits
into `machines/router/`:

**`machines/router/nftables.conf`** — NAT + forward skeleton (adjust
to your policy):

```nft
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif "lo" accept
    tcp dport { 22 } accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname "lan0" oifname "wan0" accept
  }
  chain output {
    type filter hook output priority 0; policy accept;
  }
}

table inet nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "wan0" masquerade
  }
}
```

**`machines/router/default.nix`** — `systemd.link` files to pin
`wan0`/`lan0` names by MAC (the values you saved in step 6):

```nix
systemd.network.links."10-wan0" = {
  matchConfig.MACAddress = "aa:bb:cc:dd:ee:01";
  linkConfig.Name = "wan0";
};
systemd.network.links."10-lan0" = {
  matchConfig.MACAddress = "aa:bb:cc:dd:ee:02";
  linkConfig.Name = "lan0";
};
```

Start:

```bash
pve start router
```

## 9. DHCP + DNS for prod VMs (TBD)

Not implemented yet. Likely a companion profile (`dhcp-dns` or
similar) composed alongside `nftables`, so the nftables profile stays
firewall-only. Prod VMs on `vmbr1` will need:

- DHCP server (dnsmasq or Kea) advertising the router VM's `vmbr1` IP
  as gateway
- DNS resolver (unbound or dnsmasq forwarder) upstream to public
  resolvers
- Prod-VM DNS records for internal names

## 10. Reconnect admin to routed internet (once the router is up)

Once the router VM is forwarding between `vmbr1` and `wan0`, admin
can drop tinyproxy and use the routed path. Give admin a second NIC
on `vmbr1`, remove `proxy.nix`, and rebuild:

```bash
ssh root@192.168.100.1
qm set 100 --net1 virtio,bridge=vmbr1
qm set 100 --ipconfig1 ip=dhcp
qm reboot 100
```

Then on admin:

```bash
sudo rm /etc/nixos/proxy.nix
sudo sed -i '/^[[:space:]]*\.\/proxy\.nix$/d' /etc/nixos/flake.nix
sudo nixos-rebuild switch
```

Admin now has routed internet through the router VM; `mgmt` stays as
the PVE-only management path.
