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
only management path, moves admin off `vmbr0` onto an isolated `mgmtbr`
bridge, repurposes `vmbr0` as the isolated prod bridge (router VM is
its sole upstream), and binds the onboard NICs to `vfio-pci` for
router VM passthrough.

## 2. Create the `mgmtbr` bridge on PVE

Plug the USB Ethernet adapter into PVE.

First, add a permanent `pve` alias to your **workstation's**
`~/.ssh/config` for direct root access to PVE (mirrors the `pve-admin`
entry). Use PVE's current LAN IP for now — step 5 will re-point it at
`192.168.100.1` once vmbr0 loses its LAN uplink:

```bash
cat >> ~/.ssh/config <<'EOF'

Host pve
  HostName <pve-lan-ip>
  User root
EOF
```

Then from your workstation, SSH to PVE (still reachable via the LAN
uplink on vmbr0) and find the USB NIC's interface name:

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
cat > /etc/network/interfaces.d/mgmtbr <<EOF
auto mgmtbr
iface mgmtbr inet static
    address 192.168.100.1/24
    bridge-ports $USB_NIC
    bridge-stp off
    bridge-fd 0
EOF

ifreload -a
```

Verify:

```bash
ip -br addr show mgmtbr    # UP, 192.168.100.1/24
bridge link show | grep mgmtbr    # $USB_NIC as member of mgmtbr
```

`vmbr0` still carries the LAN uplink and admin VM keeps its DHCP
address, so nothing has broken yet — `mgmtbr` is idle until step 3
hooks up the workstation.

**Caveat:** PVE's web UI expects bridge names matching `vmbr\d+` and
won't offer `mgmtbr` in the GUI network dropdown. Fine here since
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

Now run tinyproxy on the workstation — PVE will need it once step 5
removes `vmbr0` (which currently carries the LAN uplink), and admin
will need it too once we move it to `mgmtbr` in step 4. Tinyproxy is
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
loses its LAN uplink in step 5:

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

## 4. Move the admin VM to `mgmtbr`

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
# (mgmtbr has no upstream). Remove once the router VM is up and admin
# gets a NIC on vmbr0 with routed internet.
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

### 4b. Point admin's SSH alias + `pve.env` at the mgmtbr topology

Still on admin (as `admin`), update `~/.ssh/config`'s `Host pve` entry
so it resolves to PVE's mgmtbr IP after the move:

```bash
sed -i '/^Host pve$/,/^$/ s|^  HostName .*|  HostName 192.168.100.1|' ~/.ssh/config
```

`pve.env`'s `PVE_BRIDGE=vmbr0` from INSTALL stays as-is — vmbr0 is
repurposed as the isolated prod bridge in step 5, so new VMs still
default to `vmbr0`.

Log out — admin is about to be reconfigured out from under you:

```bash
exit
```

### 4c. Rebridge admin on PVE

From your **workstation**, SSH to PVE via the mgmtbr direct link (don't
use `pve-admin` — it's about to go offline):

```bash
ssh root@192.168.100.1

qm shutdown 100
# wait ~10s for graceful shutdown
qm set 100 --net0 virtio,bridge=mgmtbr
qm set 100 --ipconfig0 ip=192.168.100.100/24,gw=192.168.100.1
qm start 100
```

### 4d. Update workstation `pve-admin` alias

On your **workstation**, point `Host pve-admin` at the new mgmtbr IP:

```bash
sed -i '/^Host pve-admin$/,/^$/ s|^  HostName .*|  HostName 192.168.100.100|' ~/.ssh/config
```

Wait ~30s for cloud-init/networkd to apply the new address on admin,
then verify end-to-end:

```bash
ssh pve-admin              # workstation → admin over mgmtbr
pve list                   # admin → PVE via pve alias (192.168.100.1)
```

## 5. Repurpose `vmbr0` as the isolated prod bridge

`vmbr0` currently owns the onboard NIC and the LAN uplink. Strip
those out and it becomes the L2 fabric for prod VMs — the router VM
(built in step 7) will be its sole upstream. Reusing `vmbr0` keeps
`PVE_BRIDGE=vmbr0` in admin's `pve.env` from step 1 valid, matches
PVE's native `vmbr*` naming, and frees the onboard NIC for
`vfio-pci` binding in step 6.

Also unplug the LAN cable — PVE will be airgapped on `mgmtbr` after
this step.

Before editing, note the onboard NIC MAC addresses — you'll need them
in step 7 for `systemd.link` name pinning inside the router VM:

```bash
for iface in $(ls /sys/class/net | grep -Ev '^(lo|vmbr|tap|fwpr|fwln|veth|bond|mgmt)'); do
  echo "$iface: $(cat /sys/class/net/$iface/address)"
done
```

Save the output somewhere safe (a note on your workstation, a comment
in `machines/router/default.nix`).

Edit `/etc/network/interfaces` on PVE. In the `iface vmbr0` stanza,
drop the `address`/`gateway` lines, switch `inet static` to `inet
manual`, and change `bridge-ports <onboard-nic>` to `bridge-ports
none`. Also delete any `iface <onboard-nic>` stanza — that NIC stays
unbound so `vfio-pci` can claim it.

Before:

```
auto vmbr0
iface vmbr0 inet static
    address 10.13.14.90/24
    gateway 10.13.14.1
    bridge-ports enp1s0
    bridge-stp off
    bridge-fd 0
```

After:

```
auto vmbr0
iface vmbr0 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
```

Then reboot:

```bash
reboot
```

Update your workstation's `pve` alias to the mgmtbr IP (PVE's LAN
address is gone):

```bash
sed -i '/^Host pve$/,/^$/ s|^  HostName .*|  HostName 192.168.100.1|' ~/.ssh/config
```

Wait ~60s for PVE to come back, then verify from your workstation
direct link:

```bash
ssh pve
ip -4 -br addr show vmbr0        # empty (no IPv4)
ip -br link show vmbr0           # UNKNOWN (normal for empty bridge — flips to UP once the router VM attaches)
bridge link show | grep vmbr0    # no ports
apt-get update                   # still works via tinyproxy
```

## 6. PVE passthrough prep

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
# 02:00.0 Ethernet controller [0200]: Intel ... I210 [8086:1533]
# 03:00.0 Ethernet controller [0200]: Intel ... I210 [8086:1533]
```

Bind them to `vfio-pci`. `ids=` is a comma-separated list of
**unique** `vendor:device` pairs from the `[…]` field above — one
entry per NIC *model*, not per NIC. The kernel binds every device
matching any listed ID.

Two NICs of the same model (like the pair of I210s above) share one
entry:

```
options vfio-pci ids=8086:1533
```

Two NICs of different models get two entries:

```
options vfio-pci ids=8086:1533,10ec:8168
```

You also need to **blacklist** the ethernet drivers your NICs
currently use, so they can't bind — otherwise they race with vfio-pci
during PCI enumeration and usually win. Common drivers by Intel NIC
family: `i40e` (X710/XL710), `igc` (I225/I226), `igb` (I210/I350),
`e1000e` (older Intel). Check yours **before** binding:

```bash
lspci -nnk | grep -A3 -i ether
# Kernel driver in use: <driver-name>
```

Blacklisting is safe here because all onboard NICs are going to
vfio-pci — nothing else on this host wants those drivers. If you had
mixed use (some NICs for the host, others for vfio), you'd use
`driverctl set-override <BDF> vfio-pci` for per-device binding
instead.

Write it all, load the vfio modules early, rebuild the initrd, and
reboot:

```bash
cat > /etc/modprobe.d/vfio.conf <<'EOF'
options vfio-pci ids=8086:1533
blacklist igb
blacklist i40e
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

## 7. Router VM with `nftables` + NIC passthrough

The [`nftables`](profiles/nftables.nix) profile loads its ruleset from
`/var/identity/nftables.conf` and pairs with the wizard's PCI picker
(added on this branch — same mechanism as the GPU picker documented
in [PROXMOX.md](PROXMOX.md#gpu-passthrough), filtered to
network-class devices).

From admin, pre-set env vars for the non-interactive prompts, then
run the wizard — only the PCI picker fires:

```bash
ssh pve-admin
cd ~/nixos-vm-template

export NIXOS_VM_MUTABILITY=immutable
export NIXOS_VM_PROFILE=nftables
export NIXOS_VM_MEMORY=4G
export NIXOS_VM_VCPUS=2
export NIXOS_VM_DISK_SIZE=20G
export NIXOS_VM_BRIDGE=vmbr0
export NIXOS_VM_STATIC_IP=192.168.1.1/24    # router's LAN-side IP on vmbr0
export NIXOS_VM_DNS=cloudflare              # or google / gateway

pve create router
```

Two prompts still fire:

- **PCI passthrough** — pick the physical NICs (WAN + LAN) you want
  handed to the router VM.
- **Gateway** — press Enter to leave blank. The router's own gateway
  is upstream via `wan0`, not on the virtio-vmbr0 interface.

The virtio NIC on `vmbr0` is the router's port into the prod network
(that's where future prod VMs find it as their gateway — hence the
`192.168.1.1/24` static IP above).

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
`wan0`/`lan0` names by MAC (the values you saved in step 5):

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

## 8. DHCP + DNS for prod VMs (TBD)

Not implemented yet. Likely a companion profile (`dhcp-dns` or
similar) composed alongside `nftables`, so the nftables profile stays
firewall-only. Prod VMs on `vmbr0` will need:

- DHCP server (dnsmasq or Kea) advertising the router VM's `vmbr0` IP
  as gateway
- DNS resolver (unbound or dnsmasq forwarder) upstream to public
  resolvers
- Prod-VM DNS records for internal names

## 9. Reconnect admin to routed internet (once the router is up)

Once the router VM is forwarding between `vmbr0` and `wan0`, admin
can drop tinyproxy and use the routed path. Give admin a second NIC
on `vmbr0`, remove `proxy.nix`, and rebuild:

```bash
ssh root@192.168.100.1
qm set 100 --net1 virtio,bridge=vmbr0
qm set 100 --ipconfig1 ip=dhcp
qm reboot 100
```

Then on admin:

```bash
sudo rm /etc/nixos/proxy.nix
sudo sed -i '/^[[:space:]]*\.\/proxy\.nix$/d' /etc/nixos/flake.nix
sudo nixos-rebuild switch
```

Admin now has routed internet through the router VM; `mgmtbr` stays as
the PVE-only management path.
