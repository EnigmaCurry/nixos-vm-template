# agent-face screen: a VM with an NVIDIA
# GPU passed through to a real monitor, showing one window of the ship.
#
# The regular user is logged in at boot (greetd) to Hyprland under UWSM, so
# graphical-session.target comes up and the user's agent-face@NAME.service
# (installed in ~/.config/systemd/user, see agent-face's docs/new-screen.md)
# starts on the monitor its screens/NAME.env names.
#
# Requirements:
#   - a discrete NVIDIA GPU passed through, with a monitor on one of its
#     outputs (unlike sunshine-plasma-nvidia, no virtual display is forced:
#     check `cat /sys/class/drm/card*-*/status` reads "connected")
#   - the pipewire profile (agent-face speaks and listens through it)
#   - the rust profile, to build agent-face on the VM
#
# Composes with docker + nvidia (both set the same driver options).
{ config, lib, pkgs, ... }:

let
  user = config.core.regularUser;
  home = config.users.users.${user}.home;

  # Seeded into ~/.config/hypr/hyprland.conf once, if there is none there:
  # the user's own copy is theirs to change.
  hyprlandConf = pkgs.writeText "hyprland.conf" ''
    # Seeded by the agent-face-screen profile; yours to change.
    monitor = , preferred, auto, 1

    # NVIDIA
    env = LIBVA_DRIVER_NAME,nvidia
    env = __GLX_VENDOR_LIBRARY_NAME,nvidia
    env = GBM_BACKEND,nvidia-drm
    cursor {
      no_hardware_cursors = true
      inactive_timeout = 3
    }

    # A display, not a desktop: nothing to draw but the face.
    general {
      border_size = 0
      gaps_in = 0
      gaps_out = 0
    }
    decoration {
      rounding = 0
    }
    animations {
      enabled = false
    }
    misc {
      disable_hyprland_logo = true
      disable_splash_rendering = true
      background_color = 0x000000
    }
    ecosystem {
      no_update_news = true
      no_donation_nag = true
    }

    # With a keyboard plugged in: a terminal, and a way out.
    bind = SUPER, Return, exec, foot
    bind = SUPER SHIFT, Q, killactive
  '';

  # agent-face's wgpu loads libvulkan.so.1 at run time, and NixOS has no
  # system library path for it to be found in.
  libPath = lib.makeLibraryPath (with pkgs; [ vulkan-loader wayland libxkbcommon ]);
in
{
  config = {
    assertions = [
      {
        assertion = config.services.pipewire.enable;
        message = "agent-face-screen profile requires the pipewire profile";
      }
    ];

    # ── NVIDIA bare-metal driver stack (as nvidia / sunshine-plasma-nvidia) ──
    nixpkgs.config.allowUnfree = true;
    services.xserver.videoDrivers = [ "nvidia" ];
    hardware.graphics.enable = true;
    hardware.nvidia.open = true;
    hardware.nvidia.modesetting.enable = true;  # nvidia-drm.modeset=1

    # ── Hyprland under UWSM, the regular user logged in at boot ──────────
    programs.hyprland = {
      enable = true;
      withUWSM = true;  # brings up graphical-session.target for user units
    };
    services.greetd = {
      enable = true;
      settings = {
        # At boot: straight into Hyprland as the regular user.
        initial_session = {
          inherit user;
          command = "${lib.getExe pkgs.uwsm} start -- hyprland-uwsm.desktop";
        };
        # After a logout or a crash: a login prompt on the monitor.
        default_session.command =
          "${lib.getExe pkgs.tuigreet} --time --cmd '${lib.getExe pkgs.uwsm} start -- hyprland-uwsm.desktop'";
      };
    };

    users.users.${user}.extraGroups = [ "video" "render" "input" ];

    systemd.tmpfiles.rules = [
      "d ${home}/.config 0755 ${user} users -"
      "d ${home}/.config/hypr 0755 ${user} users -"
      "C ${home}/.config/hypr/hyprland.conf 0644 ${user} users - ${hyprlandConf}"
    ];

    # The user's own agent-face@.service (from agent-face's systemd/) finds
    # Vulkan through this drop-in.
    systemd.user.services."agent-face@" = {
      overrideStrategy = "asDropin";
      environment.LD_LIBRARY_PATH = libPath;
    };

    # ── What agent-face needs at run time (docs/new-screen.md) ───────────
    fonts.packages = [ pkgs.liberation_ttf ];
    environment.systemPackages = with pkgs; [
      git
      curl
      ffmpeg      # ffmpeg, ffprobe
      grim
      wf-recorder
      zstd
      rsync
      foot
      vulkan-tools  # vulkaninfo
      wlr-randr
      # Building agent-face (with the rust profile's cargo)
      cmake
      gcc
      pkg-config
      wayland.dev
      libxkbcommon.dev
      libopus.dev
    ];

    # cargo builds find the C libraries agent-face links (the pipewire
    # profile adds alsa's the same way), and a hand-run agent-face finds Vulkan.
    environment.extraInit = ''
      export PKG_CONFIG_PATH="${lib.makeSearchPath "lib/pkgconfig" (with pkgs; [ wayland.dev libxkbcommon.dev libopus.dev ])}''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
      export LD_LIBRARY_PATH="${libPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    '';

    # Hyprland + ffmpeg + the driver stack (+ the rust profile, to build
    # agent-face) outgrow both the "auto" disk size and 16 GiB: a 16 GiB image
    # failed cptofs with rust added. The qcow2 is sparse, so the headroom is free.
    virtualisation.diskSize = lib.mkOverride 51 32768;
  };
}
