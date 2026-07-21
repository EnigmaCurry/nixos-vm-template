# Moonshine (github.com/hgaiser/moonshine): a headless Moonlight/GameStream
# streaming server. This profile ships the NVIDIA variant — it needs a
# discrete NVIDIA GPU passed through to the VM (see PROXMOX.md, "GPU
# passthrough") and requires the pipewire profile for audio capture.
#
# The systemd service module is adapted from
#   github.com/philpax/nixos-configuration
#   nixos/mindgame/services/moonshine.nix
{ config, lib, pkgs, ... }:

let
  user = config.core.regularUser;
  moonshine = pkgs.callPackage ./moonshine/package.nix { };

  # The unit runs as `user` via User=, but Moonshine launches game sessions
  # through the user's systemd instance (systemd-run --user over D-Bus), so it
  # needs XDG_RUNTIME_DIR / the session bus address resolved for that user.
  # Linger (below) keeps that instance alive with no interactive login.
  startMoonshine = pkgs.writeShellApplication {
    name = "start-moonshine";
    runtimeInputs = [ pkgs.coreutils moonshine ];
    text = ''
      uid="$(id -u)"
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$uid}"
      export DBUS_SESSION_BUS_ADDRESS="''${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
      if [ ! -d "$XDG_RUNTIME_DIR" ]; then
        echo "moonshine: $XDG_RUNTIME_DIR missing — is linger enabled for $(id -un)?" >&2
        exit 1
      fi
      exec moonshine "$@"
    '';
  };
in
{
  config = {
    assertions = [{
      assertion = config.services.pipewire.enable;
      message = "moonshine-nvidia profile requires the pipewire profile (audio capture)";
    }];

    # NVIDIA bare-metal driver stack (unlike profiles/nvidia.nix, which is
    # scoped to nvidia-container-toolkit for docker workloads).
    nixpkgs.config.allowUnfree = true;
    services.xserver.videoDrivers = [ "nvidia" ];
    hardware.graphics.enable = true;
    hardware.nvidia.open = true;  # open kernel modules (Turing+ / RTX)

    # Keep the user's systemd user instance running without an interactive
    # login, so Moonshine can spawn game sessions on a headless VM.
    users.users.${user}.linger = true;

    # Pre-create the moonshine config dir so the daemon can drop defaults +
    # pairing certs into it on first run.
    systemd.tmpfiles.settings."10-moonshine"."/home/${user}/.config/moonshine".d = {
      user = user;
      group = "users";
      mode = "0700";
    };

    systemd.services.moonshine = {
      description = "Moonshine — headless Moonlight/GameStream streaming server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Log both crates: the server's actual logic lives in moonshine_core,
      # not the thin `moonshine` bin crate.
      environment.MOONSHINE_LOG = "moonshine=info,moonshine_core=info";
      serviceConfig = {
        User = user;
        Group = "users";
        SupplementaryGroups = [ "input" "video" "render" ];
        # Moonshine requires the config path as a positional arg; it will
        # auto-create the file (Config::load_or_create) with defaults + pairing
        # cert/key on first run, using the dir pre-created by tmpfiles above.
        ExecStart = "${startMoonshine}/bin/start-moonshine /home/${user}/.config/moonshine/config.toml";
        Restart = "always";
        RestartSec = 3;
        # inputtino virtual devices + GPU nodes for Vulkan encode/compositor.
        DeviceAllow = [
          "/dev/uinput rw"
          "/dev/uhid rw"
          "char-drm rw"
          "char-nvidia rw"
          "char-nvidia-uvm rw"
        ];
      };
    };

    # Virtual input devices (inputtino): gamepad (incl. motion/touchpad/
    # haptics), keyboard and mouse injection from the Moonlight client.
    hardware.uinput.enable = true;
    boot.kernelModules = [ "uhid" ];
    services.udev.extraRules = ''
      KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess", GROUP="input", MODE="0660"
      KERNEL=="uhid", TAG+="uaccess", GROUP="input", MODE="0660"
      SUBSYSTEM=="hidraw", KERNELS=="uhid", TAG+="uaccess", GROUP="input", MODE="0660"
      SUBSYSTEMS=="input", ATTRS{name}=="Moonshine *", TAG+="uaccess", GROUP="input", MODE="0660"
    '';

    # Register the Moonshine Vulkan WSI layer. It is gated by
    # ENABLE_MOONSHINE_WSI=1, which Moonshine sets only in the environment of
    # apps it streams, so the layer is inert for every other Vulkan program
    # on the system. /etc/vulkan is scanned by the loader unconditionally
    # (independent of XDG_DATA_DIRS), which matters in the lingering
    # headless session where XDG_DATA_DIRS may be minimal.
    environment.etc."vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json".source =
      "${moonshine}/share/vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json";

    environment.systemPackages = [ moonshine ];

    # Moonlight/GameStream firewall ports are seeded into the per-VM
    # machines/<name>/tcp_ports + udp_ports at machine-init time (see
    # src/vm/machine.clj) rather than baked into the image — this matches how
    # every other profile in this repo handles ports, and keeps them visible/
    # editable via `just upgrade`.
  };
}
