# Installation

> [!NOTE]
> These steps are for the **development / local-build** workflow. If you
> only want to deploy the pre-built images, see
> [BOOTSTRAP.md](BOOTSTRAP.md) — it does not need Nix or `just`.

## Install Nix

Prefer your OS package:

```bash
## Normal Fedora workstation/server (not Atomic nor OSTree based)
sudo dnf install nix
sudo systemctl enable --now nix-daemon
```

Or use the nix installer, but it only works on non-SELinux
distributions:

```
## Generic Nix installer
curl -L https://nixos.org/nix/install | sh -s -- --daemon
```

> [!NOTE]
> The Nix installer works fine on most non-SELinux
> distributions out of the box. If you run Fedora Atomic, or another
> OSTree distro, see [DEVELOPMENT.md](DEVELOPMENT.md)

## Enable Nix Flakes support

Create the nix config file `~/.config/nix/nix.conf`:

```
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" \
    >> ~/.config/nix/nix.conf
```

## Install just

The only build tool you need on your `PATH` is `just`; install it with Nix:

```bash
nix profile add nixpkgs#just
```

Every `just` recipe runs the VM-management CLI inside the flake's development
shell automatically (via `nix develop --command`), so `bb`, `qemu-img`,
`guestfish`, and the other build tools are pulled in on demand — you don't need
to install them or enter `nix develop` yourself. The first command may take a
moment while Nix realises the dev shell; subsequent runs are cached.

> [!TIP]
> If you're iterating and want to skip the per-command `nix develop` wrapper,
> enter the shell once with `nix develop` (which puts every tool on `PATH`) and
> set `VM_CLI="bb -m vm.cli"` to make the recipes call `bb` directly.

## Run from anywhere (a shell alias)

`just` has flags to point it at a `Justfile` (`-f`), a working directory
(`-d`), and an env file (`-E`) regardless of your current directory. Wrapping
those in a shell alias lets you run the recipes from anywhere, and keeps your
backend config (`BACKEND`, `PVE_HOST`, …) in `~/.config` instead of inside the
clone. The alias name is yours to choose — `vm` is just an example:

```bash
# Add to ~/.bashrc (or ~/.zshrc)
export NIXOS_VM_TEMPLATE="$HOME/nixos-vm-template"   # wherever you cloned the repo
alias vm="just -f '$NIXOS_VM_TEMPLATE/Justfile' -d '$NIXOS_VM_TEMPLATE' -E '$HOME/.config/nixos-vm-template/env'"
```

The outer double quotes expand the variables when the alias is defined; the
inner single quotes keep the resulting paths intact at call time. Now any recipe
in this guide works as `vm <recipe>`:

```bash
vm create myvm
vm status myvm
vm ssh myvm
```

### Tab completion and per-backend aliases

The completion script in [`completions/vm.bash`](completions/vm.bash) provides a
`nixos-vm-template-alias <alias> <env-file> [repo-root]` helper that defines an alias **and**
wires up its completion in one step. Because each alias carries its own env file,
this is also how you give each backend its own command — e.g. `vm` for libvirt,
`pve` for proxmox (KVM), and `pve-lxc` for proxmox-lxc, each completing against
its own guests:

```bash
# Add to ~/.bashrc (replaces the manual `alias vm=…` line above)
export NIXOS_VM_TEMPLATE="$HOME/nixos-vm-template"
source "$NIXOS_VM_TEMPLATE/completions/vm.bash"

nixos-vm-template-alias vm      "$HOME/.config/nixos-vm-template/env"      # libvirt
nixos-vm-template-alias pve     "$HOME/.config/nixos-vm-template/pve.env"  # proxmox (KVM)
nixos-vm-template-alias pve-lxc "$HOME/.config/nixos-vm-template/lxc.env"  # proxmox-lxc
```

Put `BACKEND=libvirt` in `env`, `BACKEND=proxmox` (plus `PVE_HOST=…`) in
`pve.env`, and `BACKEND=proxmox-lxc` (plus `PVE_HOST=…`) in `lxc.env`. (Avoid
naming an alias `lxc` — it shadows the LXD/Incus client.) Now `vm <Tab>`,
`pve <Tab>`, and `pve-lxc <Tab>` complete recipe names, and recipe
arguments complete to the right values — VM names, profiles (comma-separated
lists included), and network modes — each querying its own backend.

Argument completion is data-driven: it reads the recipe's parameter name from
`just --show` and offers the output of the matching `_completion_<param>` recipe
in the `Justfile` (e.g. a `name` parameter completes from `_completion_name`).
Nothing hardcodes the recipe list, so it keeps working as recipes change — to
add completion for a new parameter, add a `_completion_<param>` recipe.

You can name the aliases anything (`nixos-vm-template-alias lab "$HOME/.config/.../lab.env"`),
and register as many backends/hosts as you like. If you prefer to define aliases
by hand, register completion for them explicitly instead: `complete -F _vm vm pve pve-lxc`.

On zsh, enable bash-completion compatibility first:
`autoload -U +X bashcompinit && bashcompinit` before the `source` line.

## Next steps

- Set up the [libvirt backend](LIBVIRT.md) or [Proxmox backend](PROXMOX.md)
- Browse the [command reference](COMMANDS.md)
