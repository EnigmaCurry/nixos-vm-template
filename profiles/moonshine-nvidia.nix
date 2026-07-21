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

  # Wrapper for the Steam scanner's per-game launch command. Without it,
  # `steam steam://rungameid/<id>` returns immediately (IPC to the running
  # Steam client), so moonshine's `child.wait()` never blocks on the game —
  # session teardown fires either instantly (503) or waits on the systemd
  # scope, which stays alive because Steam BPM is a descendant. Result:
  # quitting the game leaves the stream stuck in BPM. The wrapper waits on
  # Steam's `reaper` process for this AppId — reaper wraps every game and
  # exits exactly when the game does — so `child.wait()` returns when the
  # user quits, moonshine fires ApplicationStopped, and the session ends.
  # Same pattern as Sunshine's steam.sh.
  steamRunWait = pkgs.writeShellApplication {
    name = "moonshine-steam-run-wait";
    runtimeInputs = [ pkgs.coreutils pkgs.procps ];
    text = ''
      game_id="$1"
      # -silent: start Steam minimized/hidden if it isn't running, so BPM
      # doesn't appear. Ignored when Steam is already running. Dropping
      # -bigpicture means the scanner tiles launch the game directly — the
      # separate [[application]] "Steam" tile still explicitly opens BPM.
      #
      # Background this call: on NixOS `steam` is an FHS/bwrap wrapper that
      # returns quickly when Steam is already running (IPC + exit), but on
      # a cold start it stays in the foreground until Steam client itself
      # exits — which blocks this whole wrapper forever, so we never get to
      # poll for the reaper and callers (moonshine / Pegasus's QProcess)
      # never see us finish. Backgrounding lets us proceed to the poll while
      # Steam starts up. The Steam client stays running under the parent
      # scope regardless.
      ${steamCommand} -silent "steam://rungameid/$game_id" &
      # Poll up to 120s for the reaper for this AppId to appear (cold start
      # of Steam + a Proton game can easily take a minute).
      for _ in $(seq 1 120); do
        if pgrep -f "reaper.*SteamLaunch AppId=$game_id" >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done
      # Block until the reaper exits (game quit).
      while pgrep -f "reaper.*SteamLaunch AppId=$game_id" >/dev/null 2>&1; do
        sleep 2
      done
    '';
  };
  steamRunWaitPath = "/run/current-system/sw/bin/moonshine-steam-run-wait";

  # PATH shim for Pegasus's Steam provider. Pegasus builds `steam
  # steam://rungameid/<id>` and blocks on that child (QProcess), so it
  # thinks the game is finished the moment the `steam` CLI returns —
  # which is <1s later, right after IPC to the Steam client. Result:
  # Pegasus tries to restore its UI immediately, Steam then takes focus
  # while the game loads, and when the user actually quits, Pegasus
  # doesn't come back because as far as it knows the game already ended
  # long ago. This shim intercepts the URL form, delegates to our
  # wait-for-reaper wrapper, and only returns when the game truly exits
  # — so Pegasus's blocking wait now aligns with the real game lifetime.
  # Non-URL invocations pass through to the real `steam`.
  pegasusSteamShim = pkgs.writeShellApplication {
    name = "steam";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      for arg in "$@"; do
        case "$arg" in
          steam://rungameid/*)
            game_id="''${arg#steam://rungameid/}"
            exec ${steamRunWaitPath} "$game_id"
            ;;
        esac
      done
      exec ${steamCommand} "$@"
    '';
  };

  # Wrapper for the Pegasus launcher tile. Prepends the shim above (so
  # Pegasus's bare `steam` lookup lands on our version) followed by the
  # NixOS system-profile bin dirs (for anything else Pegasus shells out
  # to). Without this, PATH may not include /run/current-system/sw/bin
  # under moonshine's systemd-run --user --scope, and even if it did,
  # Pegasus would still exit its own wait too early on Steam launches.
  pegasusLaunch = pkgs.writeShellApplication {
    name = "moonshine-pegasus-launch";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      export PATH="${pegasusSteamShim}/bin:/run/current-system/sw/bin:/run/wrappers/bin:''${PATH:-}"
      exec ${pkgs.pegasus-frontend}/bin/pegasus-fe "$@"
    '';
  };
  pegasusLaunchPath = "/run/current-system/sw/bin/moonshine-pegasus-launch";

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

    [[application]]
    title = "Pegasus"
    command = ["${pegasusLaunchPath}"]

    [[application]]
    title = "Heroic"
    command = ["/run/current-system/sw/bin/heroic"]

    [[application]]
    title = "Lutris"
    command = ["/run/current-system/sw/bin/lutris"]

    [[application]]
    title = "RetroArch"
    command = ["/run/current-system/sw/bin/retroarch"]

    [[application_scanner]]
    type = "steam"
    library = "$HOME/.local/share/Steam"
    command = ["${steamRunWaitPath}", "{game_id}"]
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
    # First-boot rename: swap the upstream default `name = "Moonshine"` for
    # the VM's actual hostname so Moonlight clients discover it by that
    # name instead of a generic "Moonshine". Only touches the exact default
    # literal, so any later user rename is preserved.
    hn=$(${pkgs.coreutils}/bin/cat /var/identity/hostname 2>/dev/null | ${pkgs.coreutils}/bin/tr -d '\n' || true)
    if [ -n "$hn" ]; then
      ${pkgs.gnused}/bin/sed -i "s|^name = \"Moonshine\"$|name = \"$hn\"|" "$CONFIG"
    fi
    # Migrate the legacy scanner command that launched Steam directly (session
    # never ended when the game quit) to the wait-for-reaper wrapper.
    ${pkgs.gnused}/bin/sed -i 's|"${steamCommand}", "-bigpicture", "steam://rungameid/{game_id}"|"${steamRunWaitPath}", "{game_id}"|g' "$CONFIG"
    # Append the Pegasus launcher tile if it isn't already present, so upgraded
    # VMs pick up the new [[application]] block without having to nuke config.
    if ! ${pkgs.gnugrep}/bin/grep -qF 'title = "Pegasus"' "$CONFIG"; then
      ${pkgs.coreutils}/bin/cat >> "$CONFIG" <<'PEG'

[[application]]
title = "Pegasus"
command = ["${pegasusLaunchPath}"]
PEG
    fi
    # Migrate legacy Pegasus tiles that ran pegasus-fe directly (no PATH set,
    # so Pegasus's Steam provider couldn't find the `steam` binary).
    ${pkgs.gnused}/bin/sed -i 's|"/run/current-system/sw/bin/pegasus-fe"|"${pegasusLaunchPath}"|g' "$CONFIG"
    # Append the Heroic launcher tile if not already present.
    if ! ${pkgs.gnugrep}/bin/grep -qF 'title = "Heroic"' "$CONFIG"; then
      ${pkgs.coreutils}/bin/cat >> "$CONFIG" <<'HER'

[[application]]
title = "Heroic"
command = ["/run/current-system/sw/bin/heroic"]
HER
    fi
    # Append the Lutris launcher tile if not already present.
    if ! ${pkgs.gnugrep}/bin/grep -qF 'title = "Lutris"' "$CONFIG"; then
      ${pkgs.coreutils}/bin/cat >> "$CONFIG" <<'LUT'

[[application]]
title = "Lutris"
command = ["/run/current-system/sw/bin/lutris"]
LUT
    fi
    # Append the RetroArch launcher tile if not already present.
    if ! ${pkgs.gnugrep}/bin/grep -qF 'title = "RetroArch"' "$CONFIG"; then
      ${pkgs.coreutils}/bin/cat >> "$CONFIG" <<'RET'

[[application]]
title = "RetroArch"
command = ["/run/current-system/sw/bin/retroarch"]
RET
    fi
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
        # `uinput` is required for inputtino to open /dev/uinput and create
        # virtual gamepads. hardware.uinput.enable puts the node in the
        # `uinput` group; the udev rule below tries to move it to `input`
        # but NixOS's own rule wins the race in practice, so we just grant
        # both here.
        SupplementaryGroups = [ "input" "uinput" "video" "render" ];
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

    environment.systemPackages = [
      moonshine
      steamRunWait
      # Optional gamepad-first launcher (browsed inside a Moonlight stream)
      # alternative to Steam BPM. Configured per-user via Pegasus's own UI.
      pkgs.pegasus-frontend
      pegasusLaunch
      # Heroic Games Launcher — Epic Games Store, GOG, Amazon Prime Gaming.
      # Own storefront browser + game grid; sign in and configure per-user.
      pkgs.heroic
      # Lutris — meta-launcher for Wine/Proton/native, plus community install
      # scripts for many storefronts (EA, Ubisoft, Battle.net, etc.).
      pkgs.lutris
      # RetroArch — LibRetro emulator frontend, gamepad-first UI. Cores and
      # ROMs are configured per-user via the RetroArch UI after first launch.
      pkgs.retroarch
      # Input diagnostics — useful when debugging gamepads reaching the VM
      # over Moonlight (virtual devices under /dev/input, /dev/uinput, /dev/uhid).
      pkgs.usbutils
      pkgs.evtest
      pkgs.sdl-jstest
      pkgs.linuxConsoleTools
    ];

    # Moonlight/GameStream firewall ports are seeded into the per-VM
    # machines/<name>/tcp_ports + udp_ports at machine-init time (see
    # src/vm/machine.clj) rather than baked into the image — this matches how
    # every other profile in this repo handles ports, and keeps them visible/
    # editable via `just upgrade`.
  };
}
