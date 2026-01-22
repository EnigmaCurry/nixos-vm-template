# Development notes

## Nix on Fedora Atomic

The default nix installer does not work on Fedora Atomic hosts
(Silverblue, Bazzite, etc.) This is because of the read-only root
filesystem.

Follow this guide to [install Nix on Fedora
Atomic](https://github.com/DeterminateSystems/nix-installer/issues/1596#issuecomment-3746102740). This will install nix on the host OS. 

There is another tool,
[nix-toolbox](https://github.com/thrix/nix-toolbox), which lets you
run nix in a toolbox/distrobox container. Installing nix on the host
seemed like the way to go for me, so I haven't tried nix-toolbox yet.

## Distrobox

I use distrobox on my development machine, but this tool needs to run
on the host, so you can do that with `host-spawn`:

```bash
export NIX="/nix/var/nix/profiles/default/bin/nix"
export JUST="${HOME}/.cargo/bin/just"
alias just="host-spawn env JUST='${JUST}' NIX='${NIX}' ${JUST}"
```

This passes the `JUST` environment variable through to the host, allowing recipes that call other recipes to work correctly.
