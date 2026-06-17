# Bootstrap one-liner

The `bootstrap.bb` script is a single entry point that works in **both**
roles, automatically adapting to the machine it runs on:

- **Production** (no Nix) — downloads pre-built images from the public binary
  image repository and creates VMs from them. Nothing is built locally.
- **Development** (Nix present) — clones the repo and drives the local
  `just create` / `just upgrade` build workflow inside the flake dev shell.

Which role you get depends on whether `nix` is detected on the machine (see
[Production vs Development](#production-vs-development) below). The same
one-liner works on any machine, so from one Nix-equipped host you can develop
and build images to deploy on all the rest.

## Running it

It runs on [babashka (`bb`)](https://github.com/babashka/babashka), a
fast-starting Clojure interpreter — `nix` is **not** required. The script
clones/updates a private working copy under `~/.cache/nixos-vm-template` and
re-execs the latest version. Run it straight from the web:

```bash
bb -e '(load-string (slurp (str "https://github.com/EnigmaCurry/nixos-vm-template/raw/refs/heads/" (or (System/getenv "NIXOS_VM_BRANCH") "master") "/bootstrap.bb")))'
```

`NIXOS_VM_BRANCH` selects the branch and defaults to `master`. It can't be
inferred from the fetched URL (the slurp'd script has no idea where it came
from), so the same variable drives both the script that's downloaded and the
branch the working copy is checked out to. To bootstrap from another branch,
set it explicitly:

```bash
NIXOS_VM_BRANCH=dev bb -e '(load-string (slurp (str "https://github.com/EnigmaCurry/nixos-vm-template/raw/refs/heads/" (or (System/getenv "NIXOS_VM_BRANCH") "master") "/bootstrap.bb")))'
```

The wizard walks you through selecting a backend, downloading a profile
image, and creating or managing VMs. Machine configs are stored under
`~/.config/nixos-vm-template/machines`.

## Production vs Development

If `nix` is detected on the machine, the wizard first offers a choice of
**Production** (download pre-built images, as above) or **Development**
(build your own images locally from source). Development mode clones the
repo to `~/git/vendor/enigmacurry/nixos-vm-template` (override with
`NIXOS_VM_DEV_DIR`) and acts as a frontend for the `just create` /
`just upgrade` workflow, running everything inside the flake dev shell so
the build tooling comes from Nix. This means the one-liner works on any
machine, and from one with Nix you can develop and build images to deploy
on all the rest.

If `nix` is **not** present, the wizard goes straight to the production
workflow — you only consume pre-built images.

|                  | Production deployment | Development |
|------------------|-----------------------|-------------|
| **Goal**         | Deploy the official, pre-built images | Customize the system and build your own images |
| **Entry point**  | `bootstrap.bb` (the `bb` one-liner above) | `just` recipes in a cloned repo |
| **Where images come from** | Downloaded from the binary image repository | Built locally with Nix |
| **Requires Nix?** | **No** | **Yes** |
| **Tools needed** | `bb` + a few standard CLI tools (see below) | `nix`, `just`, `qemu-img`, `guestfish`, … |

## Requirements (production)

- `bb` ([babashka](https://github.com/babashka/babashka)) — install this first; it's the runtime for the whole tool (the one-liner re-execs into the `bb -m vm.cli` VM-management code)
- `curl` — download images
- `qemu-img` — create the boot and `/var` disks
- `guestfish` (libguestfs-tools) — inject per-VM identity into the disks
- `readlink` (coreutils)
- **libvirt backend:** `virsh` (libvirt-clients)
- **proxmox backend:** `ssh` + `rsync` (the Proxmox node runs `qm`/`pvesh`)

The script checks for these on startup and, on Debian/Ubuntu, prints the
exact `apt-get install` line for anything missing. Notably, **`nix` is not
required** — image building happens upstream in CI, and you only consume the
results.

For the development / local-build workflow, see [INSTALL.md](INSTALL.md). To
publish your *own* binary image repository so your deployments can use this
Nix-free workflow, see [CI.md](CI.md).
