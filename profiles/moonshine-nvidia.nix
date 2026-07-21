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

  # NixOS-correct seed config. Moonshine's built-in Config::default() writes
  # a config.toml on first run that hard-codes /usr/bin/steam, which doesn't
  # exist on NixOS — the Moonlight client then gets HTTP 503 when launching
  # Steam. Ship a complete config with the NixOS system-profile path instead.
  # /run/current-system/sw/bin/steam is stable across nixpkgs updates (unlike
  # /nix/store/HASH/bin/steam, which would be GC'd on rebuild).
  # Fields mirror moonshine v0.11.0's Config::default() serialization — the
  # deserializer requires all StreamConfig sub-fields to be present.
  steamCommand = "/run/current-system/sw/bin/steam";
  defaultConfig = pkgs.writeText "moonshine-config.toml" ''
    name = "Moonshine"
    address = "0.0.0.0"
    stream_timeout = 60
    hdr_support = true

    [webserver]
    port = 47989
    port_https = 47984
    enable_pairing = true
    certificate = "$HOME/.config/moonshine/cert.pem"
    private_key = "$HOME/.config/moonshine/key.pem"

    [stream]
    port = 48010

    [stream.video]
    port = 47998
    fec_percentage = 20
    encrypt = false
    log_frame_spikes = false

    [stream.audio]
    port = 48000

    [stream.control]
    port = 47999

    [keyboard]
    layout = "us"
    variant = ""
    model = ""

    [[application]]
    title = "Steam"
    command = ["${steamCommand}", "steam://open/bigpicture"]

    [[application_scanner]]
    type = "steam"
    library = "$HOME/.local/share/Steam"
    command = ["${steamCommand}", "-bigpicture", "steam://rungameid/{game_id}"]
  '';

  # Seed the config on first run, and rewrite the legacy /usr/bin/steam path
  # in any config that predates this fix. The sed is idempotent and only
  # touches the exact upstream literal, so unrelated user edits are preserved.
  seedConfig = pkgs.writeShellScript "moonshine-seed-config" ''
    set -eu
    CONFIG=/home/${user}/.config/moonshine/config.toml
    if [ ! -f "$CONFIG" ]; then
      ${pkgs.coreutils}/bin/install -o ${user} -g users -m 0600 ${defaultConfig} "$CONFIG"
    fi
    ${pkgs.gnused}/bin/sed -i 's|/usr/bin/steam|${steamCommand}|g' "$CONFIG"
  '';
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

    # Steam client. programs.steam pulls in the FHS wrapper, 32-bit libs,
    # gamepad udev rules, and firewall exceptions for Remote Play. Requires
    # allowUnfree (already set above).
    programs.steam.enable = true;

    # Steam's 32-bit runtime libs bloat the base-image closure past the
    # default virtualisation.diskSize of "auto" (closure size + 512 MiB),
    # causing `cptofs failed. diskSize might be too small for closure`
    # during `just build`. Bump to 16 GiB — the output qcow2 is sparse so
    # unused space costs nothing on disk.
    virtualisation.diskSize = lib.mkForce 16384;

    # Keep the user's systemd user instance running without an interactive
    # login, so Moonshine can spawn game sessions on a headless VM.
    users.users.${user}.linger = true;

    # mDNS advertisement: Moonshine registers "_nvstream._tcp" via Avahi so
    # Moonlight clients on the LAN can discover the host. Without avahi-daemon
    # running, moonshine::publisher fails with "could not initialize
    # AvahiClient". userServices=true lets moonshine (running as `user`)
    # publish via the system Avahi bus.
    services.avahi = {
      enable = true;
      publish.enable = true;
      publish.userServices = true;
      openFirewall = true;  # UDP 5353 (mDNS)
    };

    # /etc is read-only on the immutable base image. Upstream
    # avahi-daemon.service sets ConfigurationDirectory=avahi, which makes
    # systemd try to mkdir/chown/chmod /etc/avahi at service start — that
    # fails with EROFS (status=241/CONFIGURATION_DIRECTORY). NixOS's
    # environment.etc has already baked /etc/avahi/avahi-daemon.conf into
    # the image, and avahi reads from the default compiled-in path without
    # needing $CONFIGURATION_DIRECTORY, so clearing this is safe.
    systemd.services.avahi-daemon.serviceConfig.ConfigurationDirectory =
      lib.mkForce "";

    systemd.services.moonshine = {
      description = "Moonshine — headless Moonlight/GameStream streaming server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "avahi-daemon.service" ];
      wants = [ "network-online.target" "avahi-daemon.service" ];
      # Log both crates: the server's actual logic lives in moonshine_core,
      # not the thin `moonshine` bin crate.
      environment.MOONSHINE_LOG = "moonshine=info,moonshine_core=info";
      serviceConfig = {
        User = user;
        Group = "users";
        SupplementaryGroups = [ "input" "video" "render" ];
        # Pre-create ~/.config/moonshine owned by the service user, so the
        # daemon can drop defaults + pairing cert/key into it on first run.
        # The '+' prefix runs these as root before the service drops to User=.
        # tmpfiles.d is explicitly unsupported for /home/* (man tmpfiles.d),
        # and would auto-create ~/.config as root:root, breaking write access.
        ExecStartPre = [
          "+${pkgs.coreutils}/bin/install -d -o ${user} -g users -m 0755 /home/${user}/.config"
          "+${pkgs.coreutils}/bin/install -d -o ${user} -g users -m 0700 /home/${user}/.config/moonshine"
          "+${seedConfig}"
        ];
        # Moonshine requires the config path as a positional arg; it will
        # auto-create the file (Config::load_or_create) with defaults + pairing
        # cert/key on first run.
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
