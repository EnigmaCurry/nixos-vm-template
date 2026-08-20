# Installing Proxmox VE from scratch

Bare-metal Proxmox setup, so you can run [`bootstrap.bb`](BOOTSTRAP.md)
against it without a Nix laptop.

## Prerequisites

- **Target machine** — x86_64 with VT-x/AMD-V and IOMMU (VT-d/AMD-Vi) enabled
  in firmware; UEFI boot; **at least two** onboard/PCIe NICs to reserve for
  passthrough (WAN + LAN for the router VM)
- **USB Ethernet adapter** — used as PVE's management NIC so all built-in
  NICs stay free for passthrough
- **USB stick** — ≥ 2 GB, for the installer
- **Monitor + keyboard** — for the install; SSH takes over after
- **A second machine** — to write the installer USB, and to remotely
  login. The machine needs two network interfaces: one for normal
  internet access (e.g. wifi) and a second physical NIC (maybe USB).
- **`ssh-agent` running on the workstation with your ed25519 key
  loaded** — every `ssh` in this doc assumes `ssh-add -l` already
  lists a key. If it doesn't:
  ```bash
  eval "$(ssh-agent)"
  ssh-add ~/.ssh/id_ed25519
  ```

## 1. Download the ISO and write to USB

Get the **Proxmox VE ISO Installer** from
<https://www.proxmox.com/en/downloads/proxmox-virtual-environment>.

The ISO is a hybrid image - it must be written raw. Use Fedora Media Writer or `dd`:

```bash
sudo dd if=proxmox-ve_*.iso of=/dev/sdX bs=4M status=progress oflag=direct conv=fsync
```

## 2. Plug in the USB NIC and USB drive

Plug both the USB installer and a **USB Ethernet adapter** into the target
machine. The installer will use the USB NIC as the management interface.

The onboard/PCIe NICs stay unbound so we can dedicate them to **PCI
passthrough** later (see [`profiles/nftables.nix`](profiles/nftables.nix)
for the passthrough-picker). This also means the default PVE bridge
(`vmbr0`) has no upstream — it's an isolated internal switch reserved
for management traffic between PVE, the workstation, and the admin VM.
Step 11 renames it to `mgmt` so this role is self-documenting; step 12
adds a second bridge (`vmbr1`) that the router VM will service for prod
VMs, on a subnet distinct from the physical LAN.

## 3. Boot from USB and install PVE

Boot the target off the installer USB and choose **Install Proxmox VE
(Graphical)**. Then:

- Agree to the EULA.
- **Target disk(s):** click *Options*, switch **Filesystem** to `zfs (RAID0)`
  for a single disk (or the appropriate RAID level for multiple disks).
- **Country / timezone / keyboard layout:** set as appropriate.
- **Password + email:** the root password for the web UI and shell; email
  is where PVE sends notifications.
- **Management interface:** pick the **USB NIC** — match by MAC, not name,
  since `enpXsY` numbering is easy to get wrong.
- **Hostname (FQDN):** e.g. `pve.lan`.
- **IP address:** `192.168.100.1/24` — an isolated management-only address
  on a subnet nothing else uses.
- **Gateway:** the installer requires one but we have no upstream, so enter
  `192.168.100.1` again (its own IP).
- **DNS:** `1.1.1.1` as a fallback; the router VM will provide real DNS
  later.

Confirm the summary and let it install. Remove the USB installer when it
reboots; keep the USB NIC plugged in.

## 4. Connect your workstation to PVE

Plug an Ethernet cable directly between your personal workstation and the
PVE management USB NIC.

Statically assign your workstation NIC to the same `/24`, e.g. with
NetworkManager:

```bash
nmcli con add type ethernet ifname enpXsY con-name pve-mgmt \
  ipv4.method manual ipv4.addresses 192.168.100.2/24
nmcli con up pve-mgmt
```

Trust the direct-link NIC so your firewall doesn't drop pings or the
proxy's port (ephemeral; add `networking.firewall.trustedInterfaces` on
NixOS, or the equivalent on your distro, to persist it):

```bash
sudo iptables -I INPUT 1 -i enpXsY -j ACCEPT
```

## 5. Run an HTTP proxy on your workstation

By design, the PVE host has no upstream internet access yet. However,
in order to update the operating system, `apt-get update` and initial
package installs on the fresh host will need internet. Run a small
HTTP proxy on your workstation that PVE can dial through the direct
link.

Tinyproxy is config-file-driven (no CLI equivalents for `Listen`/`Allow`),
so pipe the config in as a process-substituted file:

```bash
nix run nixpkgs#tinyproxy -- -d -c <(cat <<'EOF'
Port 8888
Listen 192.168.100.2
Allow 192.168.100.0/24
EOF
)
```

Keep this terminal open until the proxy is not needed (or run it in tmux).
PVE stays airgapped forever in this design, so tinyproxy is the
**permanent** internet path for the hypervisor — plan for it to run any
time you need to `apt-get` on PVE, not just during install.

## 6. SSH into PVE

In another terminal:

```bash
ssh root@192.168.100.1
```

Accept the host key and log in with the root password you set during
install.

## 7. Point PVE at the proxy

On PVE, tell apt (and the shell) to use the workstation as an HTTP proxy:

```bash
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

## 8. Switch PVE to the no-subscription repos

Fresh installs point at the enterprise repos, which return `401
Unauthorized` without a paid subscription. Disable those and add the
community `pve-no-subscription` source (PVE 9 = Debian trixie):

```bash
# Remove enterprise PVE + Ceph repos (they 401 without a subscription)
rm /etc/apt/sources.list.d/pve-enterprise.sources \
   /etc/apt/sources.list.d/ceph.sources

# Add the no-subscription repo
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
```

Now update:

```bash
apt-get update
```

You should see the Debian/PVE repos update through the proxy (watch the
tinyproxy terminal on your workstation for the requests).

## 9. Fully upgrade PVE

```bash
apt-get dist-upgrade
```

Use `dist-upgrade`, not plain `upgrade` — PVE point releases often ship
new kernels and swap out dependent packages, which plain `upgrade` won't
pull in. Reboot when it finishes:

```bash
reboot
```

Then reconnect:

```bash
ssh root@192.168.100.1
```

## 10. Install your SSH key and disable password auth

From your **workstation** (still connected on `192.168.100.2`):

```bash
ssh-copy-id root@192.168.100.1
```

Confirm key-based login works:

```bash
ssh root@192.168.100.1
```

Then on **PVE**, disable password auth via a drop-in so it survives PVE
upgrades touching the main `sshd_config`:

```bash
cat > /etc/ssh/sshd_config.d/no-passwords.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF

systemctl reload ssh
```

Test from your workstation that password auth is now refused:

```bash
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@192.168.100.1
# expected: Permission denied (publickey).
```

## 11. Rename `vmbr0` → `mgmt`

`vmbr0` is going to stay isolated forever in this design — it's the
management-only path (PVE ↔ workstation ↔ admin VM ↔ tinyproxy). Renaming
it to `mgmt` makes every downstream reference (`--net0 bridge=mgmt`,
`PVE_BRIDGE=mgmt`) self-document.

**⚠️ Do this on a fresh install, before any VMs exist.** If any VM's
config still references `bridge=vmbr0` after the rename, that VM will
come up networkless. `qm list` should be empty; `bridge link show`
should show only the USB NIC as a member of vmbr0 (no `tapNNNi0` or
`fwprNNNp0` entries). If either check fails, stop and either destroy
the VMs first or skip this step (keep `vmbr0` — the doc still works,
substitute `vmbr0` for `mgmt` in every downstream `bridge=…` reference).

Edit `/etc/network/interfaces` — rename `vmbr0` to `mgmt` and drop
the `gateway 192.168.100.1` line:

```bash
sed -i 's/\bvmbr0\b/mgmt/g' /etc/network/interfaces
sed -i '/^[[:space:]]*gateway 192\.168\.100\.1[[:space:]]*$/d' /etc/network/interfaces
cat /etc/network/interfaces          # sanity-check before rebooting
```

Then reboot to apply:

```bash
reboot
# wait ~60s
ssh root@192.168.100.1
```

Verify after reconnecting:

```bash
ip -br link show mgmt        # UP, MAC of the USB NIC
ip -br addr show mgmt        # 192.168.100.1/24
bridge link show             # USB NIC as member of mgmt
```

**Caveat:** PVE's web UI expects bridges matching `vmbr\d+` and won't
offer `mgmt` in the GUI network dropdown. This is fine here because
everything downstream (`qm`, `bootstrap.bb`, `nixos-vm-template`) drives
PVE via the CLI, not the GUI.

## 12. Create `vmbr1` — the prod bridge

Prod VMs live on `vmbr1`, on a subnet distinct from the physical LAN,
and reach the internet through the router VM (built in a later step).
PVE itself deliberately gets **no IP** on this bridge — the hypervisor
stays airgapped on `mgmt`, and there's no route from PVE through the
router. The only thing PVE needs on `vmbr1` is the L2 fabric for guest
NICs; management traffic (including PVE's own `apt-get update`) stays on
`mgmt` via workstation tinyproxy indefinitely.

Write a new drop-in under `/etc/network/interfaces.d/` (sourced by the
main file's trailing `source /etc/network/interfaces.d/*`):

```bash
cat > /etc/network/interfaces.d/vmbr1 <<'EOF'
# Prod-VM bridge. Serviced by the router VM (built later) — PVE has
# no IP here on purpose. bridge-ports is 'none' until the router
# attaches its virtio NIC as the sole member.
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
ip -br link show vmbr1       # UP, no address
brctl show vmbr1             # exists, no ports
```

## 13. Download a Debian cloud image on PVE

We'll use a throwaway Debian VM as the launcher for `bootstrap.bb` — it
does the image prep + rsync-back to PVE, then we destroy it. This keeps
build tooling off the hypervisor.

On **PVE**, grab the Debian 13 generic cloud qcow2 (curl uses the proxy
you set in step 7):

```bash
cd /root
curl -fLO https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
```

## 14. Create the temp VM and import the disk

Clean up any previous attempt first, so retries start fresh:

```bash
qm stop 9999 --skiplock 1 2>/dev/null; qm destroy 9999 --purge 2>/dev/null; true
```

Then create:

```bash
qm create 9999 --name debian-tmp-nix-build --memory 8192 --cores 4 \
  --net0 virtio,bridge=mgmt --ostype l26 --cpu host \
  --scsihw virtio-scsi-single --serial0 socket --agent 1

qm importdisk 9999 debian-13-genericcloud-amd64.qcow2 local-zfs
qm set 9999 --scsi0 local-zfs:vm-9999-disk-0,discard=on,ssd=1
qm set 9999 --ide2 local-zfs:cloudinit
qm set 9999 --boot order=scsi0
qm resize 9999 scsi0 +100G
```

Adjust `local-zfs` if your storage is named differently (`pvesm status`).

## 15. Configure cloud-init via a custom snippet and boot

PVE's `--sshkeys` codepath URL-encodes the file contents and often fails
cloud-init's key-application step (you'll see `Applying SSH credentials
failed!` in `/var/log/cloud-init-output.log`). Bypass it with a
`--cicustom` user-data snippet — cloud-init handles a plain `users:`
list cleanly.

Enable the `snippets` content type on `local` storage (one-time), then
write the snippet and attach it:

```bash
pvesm set local --content iso,vztmpl,snippets,backup,images
mkdir -p /var/lib/vz/snippets

{
  cat <<'EOF'
#cloud-config
hostname: debian-tmp-nix-build
disable_root: false
users:
  - name: root
    ssh_authorized_keys:
EOF
  awk 'NF{printf "      - \"%s\"\n", $0}' /root/.ssh/authorized_keys
} > /var/lib/vz/snippets/bootstrap-tmp.yaml

qm set 9999 --cicustom "user=local:snippets/bootstrap-tmp.yaml"
qm set 9999 --ipconfig0 ip=192.168.100.10/24,gw=192.168.100.1
qm start 9999
```

Wait ~30s for cloud-init to finish first-boot.

## 16. SSH into the temp VM and install Nix

From your **workstation**, load your key into ssh-agent and SSH to the
temp VM with `-A` so the agent is forwarded — the bootstrap in step 15
will SSH out to PVE using the same key:

```bash
ssh -A root@192.168.100.10
```

Inside the temp VM, point apt/curl at the proxy, then install Nix. We
use Nix (rather than apt for `libguestfs-tools` + a static `bb`) so the
flake dev shell provides every build tool at the exact pinned version
this repo expects.

```bash
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

apt-get update
apt-get install -y curl xz-utils git

# Determinate Systems installer — works as root, sets up multi-user daemon
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
  | sh -s -- install --no-confirm

# Give the nix-daemon the proxy too (installer runs as user, daemon inherits nothing)
mkdir -p /etc/systemd/system/nix-daemon.service.d
cat > /etc/systemd/system/nix-daemon.service.d/proxy.conf <<'EOF'
[Service]
Environment=http_proxy=http://192.168.100.2:8888/
Environment=https_proxy=http://192.168.100.2:8888/
Environment=no_proxy=localhost,127.0.0.0/8,192.168.100.0/24
EOF
systemctl daemon-reload
systemctl restart nix-daemon

# Re-login so the nix profile scripts load
exit
```

Then reconnect:

```bash
ssh -A root@192.168.100.10
```

Verify Nix works and flakes are enabled:

```bash
nix --version
nix run nixpkgs#hello       # first run pulls a few MB through tinyproxy
```

## 17. Build the Proxmox cloud-init template

Inside the temp VM, invoke `bootstrap.bb` via Nix-provided `babashka`.
Nix on `PATH` means bootstrap detects **Development mode** and runs
`just cloud-template` inside the flake dev shell, so every disk tool
(guestfish, qemu-img, rsync, ...) comes from the flake — no apt
installs on the temp VM. The end result is a **PVE template** (not a
running VM) with `cloud-init` + `mutable` baked in; clones spawned
from it will pick up per-VM identity (hostname, SSH keys, IP, etc.)
from PVE's cloud-init seed drive on first boot.

```bash
export BACKEND=proxmox                       # skip Backend: prompt
export NIXOS_VM_MODE=development             # skip Mode: prompt
export NIXOS_VM_ACTION=cloud-template        # build a template, not a VM
export NIXOS_VM_NAME=nixos                   # the template name
export NIXOS_VM_PROFILE=""                   # extra profiles (cloud-init,mutable auto-added)
export PVE_HOST=192.168.100.1                # skip PVE host: prompt
export PVE_STORAGE=local-zfs                 # skip storage prompt
export PVE_BRIDGE=mgmt                       # skip bridge prompt (renamed in step 11)
export PVE_VMID=9010                         # any free VMID (templates conventionally 9000+)
export NIXOS_VM_MEMORY=2G                    # per-clone default — clones can bump
export NIXOS_VM_VCPUS=2                      # per-clone default — clones can bump
export NIXOS_VM_DISK_SIZE=10G                # template disk size; qcow2 is sparse
export LIBGUESTFS_BACKEND=direct

# Pre-accept PVE's host key — bootstrap SSHes with BatchMode=yes,
# which won't accept an unknown key interactively.
ssh -o StrictHostKeyChecking=accept-new root@192.168.100.1 hostname

# -D flags force bb's Java HTTP layer (slurp on URLs + pod resolution)
# through tinyproxy — env vars alone don't reach java.net.URLConnection.
nix run nixpkgs#babashka -- \
  -Dhttps.proxyHost=192.168.100.2 -Dhttps.proxyPort=8888 \
  -Dhttp.proxyHost=192.168.100.2  -Dhttp.proxyPort=8888 \
  -e '(load-string (slurp "https://github.com/EnigmaCurry/nixos-vm-template/raw/refs/heads/master/bootstrap.bb"))'
```

The build runs `just cloud-template nixos "$NIXOS_VM_PROFILE"` inside
the flake dev shell. It skips the interactive wizard entirely
(templates carry no per-VM identity), builds the qcow2, imports it to
PVE, attaches an IDE2 cloud-init seed drive, and marks the VM as a
template with `qm template`. No VM is started. Clones from this
template are configured in step 19 (the admin VM).

## 18. Destroy the temp VM

Once the template is on PVE, log out of the temp VM and delete it:

```bash
qm stop 9999
qm destroy 9999 --purge
rm /root/debian-13-genericcloud-amd64.qcow2
rm /var/lib/vz/snippets/bootstrap-tmp.yaml
```

Nothing about the temp VM persists — the `nixos` template is the only
artifact left on PVE, and clones from it are the next building block.

## 19. Create the admin VM (VMID 100)

The admin VM is the first clone from the template and takes over the
"launcher for other VMs" role that the temp VM played — but permanently.
Pet containers may still be cloned from the template directly (like
this VM), but the majority of the fleet will be built from **inside
this VM** using `nixos-vm-template` (`just create ...`) against the PVE
backend at `192.168.100.1`.

The admin VM lives on `mgmt` alongside PVE, at `192.168.100.100/24`.
It's the only VM (besides pet clones) that stays on `mgmt` long-term —
everything else lands on `vmbr1` once the router VM is up.

### Clone the template

On **PVE**:

```bash
qm clone 9010 100 --name admin --full 1
qm set 100 --memory 4096 --cores 2
qm set 100 --net0 virtio,bridge=mgmt
qm set 100 --ciuser admin \
           --sshkeys ~/.ssh/authorized_keys \
           --ipconfig0 ip=192.168.100.100/24,gw=192.168.100.1
qm start 100
```

Wait ~30s for cloud-init to finish first boot, then from your
**workstation**:

```bash
ssh admin@192.168.100.100
sudo -i
```

### Wire the admin VM to tinyproxy — persistently

The admin VM has the same predicament PVE had in step 7: it's on
`mgmt`, which has no upstream. Unlike the throwaway clones case, this
one is permanent — the admin VM stays on `mgmt` forever and its only
route to the internet is workstation tinyproxy. Bake the proxy into
`/etc/nixos/configuration.nix` so it survives reboots and
`nixos-rebuild` runs.

Two things need the proxy: the **root/user shell** running `nix`
(flake input fetching happens client-side) and the **nix-daemon**
(actual build downloads).

In the root shell on the admin VM, add to `/etc/nixos/configuration.nix`
(inside the top-level `{ config, pkgs, ... }: {}` block):

```nix
{
  # tinyproxy on the workstation is this VM's only route to the internet
  # (mgmt is airgapped). Both the nix-daemon and interactive shells need
  # the proxy — the daemon downloads store paths, the shell fetches flake
  # inputs client-side.
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
```

For the immediate `nixos-rebuild switch` (which itself needs to reach
the internet), export the proxy in the current shell first:

```bash
export http_proxy=http://192.168.100.2:8888/
export https_proxy=http://192.168.100.2:8888/
export no_proxy=localhost,127.0.0.0/8,192.168.100.0/24

nixos-rebuild switch
```

After the rebuild, log out and back in so the new
`environment.sessionVariables` are picked up.

### Clone the nixos-vm-template repo

Still on the admin VM as `admin` (not root — the repo lives under the
admin user):

```bash
git clone https://github.com/EnigmaCurry/nixos-vm-template.git
cd nixos-vm-template
```

### Point at PVE and verify

The admin VM manages PVE over SSH using the same key that
`ssh-copy-id` installed on PVE in step 10 — but the key needs to be on
the admin VM, not just the workstation. Copy your workstation SSH key
into the admin VM (`scp` from workstation, or paste into
`~/.ssh/id_ed25519`), then:

```bash
ssh -o StrictHostKeyChecking=accept-new root@192.168.100.1 hostname
```

Set the backend and confirm the CLI can talk to PVE:

```bash
export BACKEND=proxmox
export PVE_HOST=192.168.100.1
export PVE_STORAGE=local-zfs
export PVE_BRIDGE=vmbr1                      # prod VMs default to the router bridge

nix develop --command just list-vms
```

You should see VMID 100 (this VM) listed. From here on, any
`just create <name>` from inside the admin VM builds a new prod VM,
attaches it to `vmbr1`, and imports the disk to PVE at
`192.168.100.1`.

## 20. Next: router VM with PCI NIC passthrough (TBD)

The remaining pieces to reach a working prod fleet:

- **PVE host prep for passthrough** — enable IOMMU on the kernel
  cmdline, bind the onboard NIC PCI IDs to `vfio-pci` via
  `/etc/modprobe.d/vfio.conf`, `update-initramfs -u`, reboot. Verify
  `lspci -nnk` shows `vfio-pci` on both NICs in distinct IOMMU groups.
- **Router VM** — built from the admin VM with the
  [`nftables`](profiles/nftables.nix) profile (immutable). Two
  passed-through physical NICs (`wan0` = ISP uplink, `lan0` = physical
  house-LAN switch), one virtio NIC on `vmbr1` for prod VMs, plus a
  `systemd.link` file to pin `wan0`/`lan0` names by MAC. The wizard's
  network-class PCI picker (added on this branch) lists the candidate
  NICs interactively.
- **nftables ruleset** — NAT out `wan0`, forward between `lan0` and
  the `vmbr1`-side interface, drop everything else. Written into
  `machines/router/nftables.conf`.
- **DHCP + DNS for prod VMs** — TBD. Likely a companion profile
  (`dhcp-dns` or similar) composed with `nftables`, so the nftables
  profile stays firewall-only. Not implemented yet.
- **PVE stays airgapped** — no `vmbr1` IP, no route through the
  router. Its only internet path remains workstation tinyproxy over
  `mgmt`, indefinitely. The only reason PVE ever needs to reach the
  router VM is a direct SSH link from the admin VM to `192.168.100.1`
  and back — not a routed path.
