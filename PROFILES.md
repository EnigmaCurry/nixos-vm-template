# Profiles

Profiles are composable mixins that you combine as needed. The `core` profile
is always included automatically. Specify multiple profiles with commas:

```bash
just create myvm docker,python           # Docker + Python
just create devbox docker,podman,dev     # Full dev environment
just create claude-vm claude,dev,docker  # Claude Code with dev tools
```

## Available Profiles

| Profile | Description |
|---------|-------------|
| **core** | SSH server, admin/user accounts, firewall (always included) |
| **docker** | Docker daemon (both users have docker access) |
| **podman** | Podman + distrobox, buildah, skopeo (rootless containers) |
| **nvidia** | NVIDIA drivers + container toolkit (requires docker) |
| **python** | Python with uv package manager and build tools |
| **rust** | Rust toolchain from Nix packages |
| **dev** | Development tools (neovim, tmux, etc.) |
| **home-manager** | Home-manager with sway-home modules (emacs, shell config, etc.) |
| **claude** | Claude Code CLI (Anthropic's AI coding assistant) |
| **open-code** | Open Code CLI (open-source AI coding assistant) |

> **Tip for agentic use:** Consider enabling
> [semi-mutable mode](MODES.md#semi-mutable-vms) for `claude` or `open-code` VMs
> (`echo "semi" > machines/<name>/mutable`). This gives a writable `/nix`
> overlay so that software can be installed on the fly with
> `nix profile install`, and nix-based projects can build and evaluate
> flakes — all while keeping the root filesystem immutable and
> host-upgradeable.

## Common Combinations

| Use Case | Profiles |
|----------|----------|
| Docker server | `docker` |
| Development VM | `docker,podman,dev` |
| Full dev environment | `docker,podman,dev,home-manager` |
| Python development | `docker,python` |
| Claude Code (full) | `claude,dev,docker,podman,home-manager` |
| Claude with GPU | `claude,dev,docker,nvidia` |
| Open Code (full) | `open-code,dev,docker,podman,home-manager` |

## Zram Compressed Swap

Zram creates a compressed swap device in RAM, allowing the system to handle
memory pressure by compressing inactive pages rather than killing processes
(OOM). This is useful for development workloads that may have unpredictable
memory spikes.

**Enabled by default in:** `dev`, `claude`, `open-code`

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `vm.zram.enable` | `false` | Enable zram compressed swap |
| `vm.zram.memoryPercent` | `100` | Percentage of RAM to use for zram (e.g., 50 = half of RAM) |
| `vm.zram.algorithm` | `zstd` | Compression algorithm (`zstd`, `lz4`, `lzo`) |

When enabled, swappiness is set to 100 to prefer compressing memory over
OOM killing.

### Enabling in a Custom Profile

To enable zram in your own profile, add to your profile's nix file:

```nix
{
  vm.zram.enable = true;
  vm.zram.memoryPercent = 50;  # Use half of RAM for compressed swap
}
```

### Effective Memory

Zram compresses inactive pages and stores them in RAM as swap. This
lets the system handle more memory pressure before OOM killing.
Compression ratios vary by workload (typically 2:1 to 4:1).

With a 4GB VM and an assumed 3:1 compression ratio:

| `memoryPercent` | Zram Swap Size | Effective Capacity |
|-----------------|----------------|-------------------|
| 50 | 2GB | ~5.3GB |
| 75 | 3GB | ~6GB |
| 100 | 4GB | ~6.7GB |

The zram device itself lives in RAM, so higher values trade active
memory for more compressed swap capacity.
