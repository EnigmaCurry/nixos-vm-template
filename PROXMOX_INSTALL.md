## Installing Proxmox VE + building a NixOS cloud-init template

Bare-metal Proxmox install on a normal LAN, then build a NixOS
cloud-init template ([`profiles/cloud-init`](profiles/cloud-init.nix))
so `just create` clones it into fully-configured VMs.

For the airgapped-router-behind-PVE topology (no LAN uplink, workstation
tinyproxy, two-bridge fabric, router VM with NIC passthrough), see
[PROXMOX_ROUTER.md](PROXMOX_ROUTER.md) instead — it duplicates parts of
this doc with the network constraints baked in.

## Prerequisites

- **Target machine** — x86_64, UEFI boot, one NIC uplinked to your LAN
- **USB stick** — ≥ 2 GB, for the installer
- **Monitor + keyboard** — for the install; SSH takes over after
- **A workstation** on the same LAN — for SSH and running `bootstrap.bb`
- **`ssh-agent`** on the workstation with your ed25519 key loaded — every
  `ssh` in this doc assumes `ssh-add -l` already lists a key. If it doesn't:
  ```bash
  eval "$(ssh-agent)"
  ssh-add ~/.ssh/id_ed25519
  ```

## 1. Download the ISO and write to USB

Get the **Proxmox VE ISO Installer** from
<https://www.proxmox.com/en/downloads/proxmox-virtual-environment>.

The ISO is a hybrid image — write it raw. Use Fedora Media Writer or `dd`:

```bash
sudo dd if=proxmox-ve_*.iso of=/dev/sdX bs=4M status=progress oflag=direct conv=fsync
```

## 2. Boot from USB and install PVE

Boot the target off the installer USB and choose **Install Proxmox VE
(Graphical)**. Then:

- Agree to the EULA.
- **Target disk(s):** click *Options*, switch **Filesystem** to `zfs (RAID0)`
  for a single disk (or the appropriate RAID level for multiple disks).
- **Country / timezone / keyboard layout:** set as appropriate.
- **Password + email:** the root password for the web UI and shell; email
  is where PVE sends notifications.
- **Management interface:** pick your uplink NIC (match by MAC to be safe).
- **Hostname (FQDN):** e.g. `pve.lan`.
- **IP address / gateway / DNS:** the values for your LAN. A static
  address is easiest — you'll be SSHing to it repeatedly.
- **Network Options** — Create identifiable names for your detected
  NICs (`lan`, `wan`, `wifi`, etc.), otherwise they will have the
  generic `nicX` names. Avoid `mgmt` — [PROXMOX_ROUTER.md](PROXMOX_ROUTER.md)
  uses `mgmtbr` for a bridge and a NIC named `mgmt` would prefix-match
  filters that expect `mgmt*` to mean the bridge.

Confirm the summary and let it install. Remove the USB installer when it
reboots.

## 3. SSH into PVE

From your workstation, connect to the PVE IP address (set the PVE_HOST
temp variable so you can follow these docs verbatim):

```bash
export PVE_HOST=<pve-ip>
```

```bash
ssh root@$PVE_HOST
```

Accept the host key and log in with the root password you set during install.

## 4. Switch PVE to the no-subscription repos

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

apt-get update
```

## 5. Fully upgrade PVE

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
ssh root@$PVE_HOST
```

## 6. Install your SSH key and disable password auth

From your **workstation**:

```bash
ssh-copy-id root@$PVE_HOST
ssh root@$PVE_HOST
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
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@$PVE_HOST
# expected: Permission denied (publickey).
```

## 7. Download a Debian cloud image on PVE

We'll use a throwaway Debian VM as the launcher for `bootstrap.bb` — it
does the image prep + rsync-back to PVE, then we destroy it. This keeps
build tooling off the hypervisor.

On **PVE**, grab the Debian 13 generic cloud qcow2:

```bash
cd /root
curl -fLO https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
```

## 8. Create the temp VM and import the disk

Clean up any previous attempt first, so retries start fresh:

```bash
qm stop 9999 --skiplock 1 2>/dev/null; qm destroy 9999 --purge 2>/dev/null; true
```

Then create:

```bash
qm create 9999 --name debian-tmp-nix-build --memory 8192 --cores 4 \
  --net0 virtio,bridge=vmbr0 --ostype l26 --cpu host \
  --scsihw virtio-scsi-single --serial0 socket --agent 1

qm importdisk 9999 debian-13-genericcloud-amd64.qcow2 local-zfs
qm set 9999 --scsi0 local-zfs:vm-9999-disk-0,discard=on,ssd=1
qm set 9999 --ide2 local-zfs:cloudinit
qm set 9999 --boot order=scsi0
qm resize 9999 scsi0 +100G
```

Adjust `local-zfs` if your storage is named differently (`pvesm status`).

## 9. Configure cloud-init via a custom snippet and boot

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
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
users:
  - name: root
    ssh_authorized_keys:
EOF
  awk 'NF{printf "      - \"%s\"\n", $0}' /root/.ssh/authorized_keys
} > /var/lib/vz/snippets/bootstrap-tmp.yaml

qm set 9999 --cicustom "user=local:snippets/bootstrap-tmp.yaml"
qm set 9999 --ipconfig0 ip=dhcp
```

Examine the MAC address of the created VM. If your LAN router requires
static DHCP leases, associate the MAC address now:

```bash
qm config 9999 | awk -F'[=,]' '/^net0:/ {print $2}'
```

Start the VM:

```
qm start 9999
```

Wait ~30s for cloud-init to finish first-boot, then look up the address
DHCP handed the guest (via qemu-guest-agent, which the cloud-init
snippet above installs on first boot — Debian's generic cloud image
doesn't ship it):

```bash
qm guest cmd 9999 network-get-interfaces \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
  | grep -v '^127\.' \
  | head -n1
```

Pin it in a workstation shell variable for the next steps:

```bash
export TMP_HOST=<temp-vm-ip>
```

## 10. SSH into the temp VM and install Nix

From your **workstation**, SSH to the temp VM with `-A` so your agent
is forwarded — bootstrap in step 11 will SSH out to PVE using the same
key:

```bash
ssh -A root@$TMP_HOST
```

Inside the temp VM, install Nix. We use Nix (rather than apt for
`libguestfs-tools` + a static `bb`) so the flake dev shell provides
every build tool at the exact pinned version this repo expects.

```bash
apt-get update
apt-get install -y curl xz-utils git

# Determinate Systems installer — works as root, sets up multi-user daemon
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
  | sh -s -- install --no-confirm

# Re-login so the nix profile scripts load
exit
```

Then reconnect:

```bash
ssh -A root@$TMP_HOST
```

Verify Nix works:

```bash
nix --version
nix run nixpkgs#hello
```

## 11. Build the Proxmox cloud-init template

Set variables for the config for the template build:


Make sure PVE_HOST points to your PVE IP address:

```bash
export PVE_HOST=<pve-ip>                     # your PVE address
export BACKEND=proxmox                       # skip Backend: prompt
export NIXOS_VM_MODE=development             # skip Mode: prompt
export NIXOS_VM_ACTION=cloud-template        # build a template, not a VM
export NIXOS_VM_NAME=nixos                   # the template name
export NIXOS_VM_PROFILE=""                   # extra profiles (cloud-init,mutable auto-added)
export PVE_STORAGE=local-zfs                 # skip storage prompt
export PVE_BRIDGE=vmbr0                      # skip bridge prompt (default PVE bridge)
export PVE_VMID=9010                         # any free VMID (templates conventionally 9000+)
export NIXOS_VM_MEMORY=2G                    # per-clone default — clones can bump
export NIXOS_VM_VCPUS=2                      # per-clone default — clones can bump
export NIXOS_VM_DISK_SIZE=10G                # template disk size; qcow2 is sparse
export LIBGUESTFS_BACKEND=direct
```

Pre-accept PVE's host key — bootstrap SSHes with BatchMode=yes, which
won't accept an unknown key interactively.

```bash
ssh -o StrictHostKeyChecking=accept-new root@$PVE_HOST hostname
```

Build the template (~5 minutes):

```bash
nix run nixpkgs#babashka -- \
  -e '(load-string (slurp "https://github.com/EnigmaCurry/nixos-vm-template/raw/refs/heads/master/bootstrap.bb"))'
```

The build runs `just cloud-template nixos "$NIXOS_VM_PROFILE"` inside
the flake dev shell. It skips the interactive wizard entirely
(templates carry no per-VM identity), builds the qcow2, imports it to
PVE, attaches an IDE2 cloud-init seed drive, and marks the VM as a
template with `qm template`. No VM is started.

## 12. Destroy the temp VM

Once the template is on PVE, log out of the temp VM and delete it. On the **PVE** host

```bash
qm stop 9999
qm destroy 9999 --purge
rm /root/debian-13-genericcloud-amd64.qcow2
rm /var/lib/vz/snippets/bootstrap-tmp.yaml
```

Nothing about the temp VM persists — the `nixos` template is the only
artifact left on PVE.

## Next: create an admin VM

Clone the template into an "admin" VM — a permanent NixOS bastion
that hosts `nixos-vm-template` and manages further VMs on PVE from a
single place instead of from your workstation. It's the first clone
from the template, and takes over the "launcher for other VMs" role
the temp VM played.

### Clone the template

On **PVE** (same `--cicustom` pattern as step 9 — `--sshkeys`
URL-encodes and fails on multi-key files):

```bash
{
  cat <<'EOF'
#cloud-config
hostname: admin
users:
  - name: admin
    ssh_authorized_keys:
EOF
  awk 'NF{printf "      - \"%s\"\n", $0}' /root/.ssh/authorized_keys
} > /var/lib/vz/snippets/admin.yaml

qm clone 9010 100 --name admin --full 1
qm resize 100 virtio0 +100G
qm set 100 --memory 4096 --cores 2
qm set 100 --cicustom "user=local:snippets/admin.yaml"
qm set 100 --ipconfig0 ip=dhcp
```

If your LAN router requires static DHCP leases, associate the MAC
address now (same as step 9):

```bash
qm config 100 | awk -F'[=,]' '/^net0:/ {print $2}'
```

Start the VM:

```bash
qm start 100
```

Wait ~30s for cloud-init to finish first-boot, then look up the IP
(same command as step 9):

```bash
qm guest cmd 100 network-get-interfaces \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
  | grep -v '^127\.' \
  | head -n1
```

### Install nixos-vm-template on the admin VM

On your **workstation**, add a permanent `~/.ssh/config` entry for the
admin VM so `ssh pve-admin` works from anywhere. `ForwardAgent yes`
lets admin's shell reach PVE with the same key:

```bash
cat >> ~/.ssh/config <<'EOF'

Host pve-admin
  HostName <admin-ip>
  User admin
  ForwardAgent yes
EOF
```

Then connect:

```bash
ssh pve-admin
```

Inside the admin VM, add a permanent `~/.ssh/config` entry for PVE so
`ssh pve` works from anywhere (the CLI's Proxmox backend expects
`PVE_HOST=pve` to resolve to this alias):

```bash
cat >> ~/.ssh/config <<'EOF'

Host pve
  HostName <pve-ip>
  User root
EOF
```

Pre-accept PVE's host key and clone the repo (`git` ships in the
NixOS template):

```bash
ssh -o StrictHostKeyChecking=accept-new pve hostname
git clone https://github.com/EnigmaCurry/nixos-vm-template.git
```

For persistent access after your workstation's agent-forwarding
session ends, copy your workstation SSH key onto admin — `scp` from
the workstation or paste into `~/.ssh/id_ed25519`.

### Wire the `pve` alias

Write the backend config to `~/.config/nixos-vm-template/pve.env` and
register a `pve` shell alias so the CLI works from any directory (see
[INSTALL.md](INSTALL.md#tab-completion-and-per-backend-aliases) for
the alias mechanism):

```bash
mkdir -p ~/.config/nixos-vm-template

cat > ~/.config/nixos-vm-template/pve.env <<'EOF'
BACKEND=proxmox
PVE_HOST=pve
PVE_STORAGE=local-zfs
PVE_BRIDGE=vmbr0
EOF

# Bridge ~/.bashrc into login shells (SSH), idempotent.
grep -q '\.bashrc' ~/.bash_profile 2>/dev/null || \
  echo '[ -f ~/.bashrc ] && . ~/.bashrc' >> ~/.bash_profile

cat >> ~/.bashrc <<'EOF'

# nixos-vm-template — pve alias for the Proxmox backend
export NIXOS_VM_TEMPLATE="$HOME/nixos-vm-template"
source "$NIXOS_VM_TEMPLATE/completions/vm.bash"
nixos-vm-template-alias pve "$HOME/.config/nixos-vm-template/pve.env"
EOF

source ~/.bashrc
```

Confirm the CLI can reach PVE from any directory:

```bash
cd ~
pve list
```

An empty list with no SSH/auth error confirms the alias works — the
admin VM itself was cloned directly, not via the CLI, so it isn't in
the registry. From here on `pve <command>` (e.g. `pve create <name>`,
`pve clone nixos <name>`) builds or clones VMs on PVE from the admin
VM. See [INSTALL.md](INSTALL.md), [PROXMOX.md](PROXMOX.md), and
[PROFILES.md](PROFILES.md) for the full CLI surface and composable
profiles.
