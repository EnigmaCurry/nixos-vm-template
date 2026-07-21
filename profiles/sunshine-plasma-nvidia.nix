# Sunshine (github.com/LizardByte/Sunshine): a Moonlight-protocol streaming
# server that *captures an existing desktop* (unlike moonshine-nvidia, which
# spawns per-app headless sessions). This profile pairs Sunshine with a KDE
# Plasma 6 Wayland desktop, autologged-in via SDDM, so a Moonlight client
# gets a full KDE desktop to interact with.
#
# Requirements (like moonshine-nvidia):
#   - discrete NVIDIA GPU passed through to the VM (see PROXMOX.md,
#     "GPU passthrough")
#   - the pipewire profile for audio capture
#
# Mutually exclusive with moonshine-nvidia (both bind the same well-known
# Moonlight ports); the exclusion is enforced by modules/streaming-server.nix
# at Nix eval time, and by src/vm/profile.clj at `just create` time.
{ config, lib, pkgs, nix-flatpak, ... }:

let
  user = config.core.regularUser;

  # ── Headless virtual display config ───────────────────────────────────
  # In a GPU-passthrough VM the GPU's HDMI/DP ports have nothing plugged in,
  # so the connector reads "disconnected", KMS allocates no framebuffer,
  # KWin sees zero outputs — and Sunshine has nothing to capture.
  #
  # `video=<connector>:<mode>e` forces the connector enabled at the given
  # mode without needing a real EDID or a firmware blob. Combined with
  # nvidia-drm.modeset=1 (from hardware.nvidia.modesetting.enable), this
  # gives KWin a real output to render into.
  #
  # If this doesn't take effect after first boot, the connector name is
  # wrong for your GPU. Check `ls /sys/class/drm/` inside the VM — common
  # names are HDMI-A-1, DP-1, DVI-D-1. Override with:
  #   boot.kernelParams = lib.mkForce [ "video=DP-1:1920x1080@60e" ];
  # in machines/<name>/default.nix, or edit this let-binding.
  #
  # Ultrawide (3440x1440, 5120x1440, ...): change displayMode below. If the
  # GPU refuses the mode without a full EDID, fall back to
  # drm.edid_firmware=<connector>:edid/<blob>.bin with a bundled blob.
  displayConnector = "HDMI-A-1";
  displayMode = "1920x1080@60";
in
{
  imports = [
    # NixOS-level flatpak module (declarative remotes + package installs).
    # nix-flatpak is already a flake input; profiles/home-manager.nix uses
    # its home-manager variant, but we want *system*-level flatpak here so
    # Bazaar and Discover both talk to the shared system daemon.
    nix-flatpak.nixosModules.nix-flatpak
  ];

  config = {
    assertions = [{
      assertion = config.services.pipewire.enable;
      message = "sunshine-plasma-nvidia profile requires the pipewire profile (audio capture)";
    }];

    # Claim the Moonlight-protocol streaming ports. Nix errors here if
    # moonshine-nvidia also tries to claim them — see modules/streaming-server.nix.
    vm.streamingServer = "sunshine";

    # ── NVIDIA bare-metal driver stack (mirrors moonshine-nvidia) ───────
    nixpkgs.config.allowUnfree = true;
    services.xserver.videoDrivers = [ "nvidia" ];
    hardware.graphics.enable = true;
    hardware.nvidia.open = true;                # open kernel modules (Turing+ / RTX)
    hardware.nvidia.modesetting.enable = true;  # sets nvidia-drm.modeset=1

    # Force-enable the virtual display (see displayConnector/displayMode above).
    boot.kernelParams = [ "video=${displayConnector}:${displayMode}e" ];

    # ── SDDM + Plasma 6 Wayland, autologin to the regular user ──────────
    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;  # SDDM runs under Wayland (NVIDIA >= 555 handles this fine)
    };
    services.displayManager.autoLogin = {
      enable = true;
      user = user;
    };
    # Plasma 6 provides "plasma" (Wayland) and "plasmax11". Wayland is the
    # default target for Sunshine's KMS/portal capture path.
    services.displayManager.defaultSession = "plasma";
    services.desktopManager.plasma6.enable = true;

    # xdg-desktop-portal-kde is what Sunshine's Wayland capture negotiates
    # with on Plasma 6. plasma6 usually wires this up automatically, but
    # be explicit.
    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.kdePackages.xdg-desktop-portal-kde ];
    };

    # ── Sunshine streaming server ───────────────────────────────────────
    services.sunshine = {
      enable = true;
      # Autostart the user service on graphical login. SDDM autologin
      # brings Plasma up on boot, which then starts sunshine.
      autoStart = true;
      # Wayland KMS grab needs CAP_SYS_ADMIN on the sunshine binary; the
      # nixpkgs module installs a setcap wrapper when this is true.
      capSysAdmin = true;
      # Firewall handled per-VM via machines/<name>/tcp_ports & udp_ports
      # (same pattern as moonshine-nvidia — see src/vm/machine.clj).
      openFirewall = false;
    };

    # ── Virtual input devices (mirrors moonshine-nvidia) ────────────────
    # Sunshine uses uinput to inject keyboard/mouse/gamepad events from
    # Moonlight clients.
    hardware.uinput.enable = true;
    boot.kernelModules = [ "uhid" ];
    services.udev.extraRules = ''
      KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess", GROUP="input", MODE="0660"
      KERNEL=="uhid", TAG+="uaccess", GROUP="input", MODE="0660"
      SUBSYSTEM=="hidraw", KERNELS=="uhid", TAG+="uaccess", GROUP="input", MODE="0660"
    '';

    # linger: keep the user's systemd user instance alive even if the
    #   graphical session ever exits, so the sunshine user service survives.
    # extraGroups: input/uinput for virtual input, video/render for GPU access.
    users.users.${user} = {
      linger = true;
      extraGroups = [ "input" "uinput" "video" "render" ];
    };

    # ── mDNS advertisement (mirrors moonshine-nvidia) ───────────────────
    # Sunshine registers _nvstream._tcp via Avahi so Moonlight clients on
    # the LAN discover the host without manual IP entry.
    services.avahi = {
      enable = true;
      publish.enable = true;
      publish.userServices = true;
      openFirewall = true;  # UDP 5353 (mDNS)
    };
    # /etc is read-only on the immutable base image; upstream avahi-daemon.service
    # sets ConfigurationDirectory=avahi which fails EROFS at start. Clearing it
    # is safe because environment.etc has baked /etc/avahi/avahi-daemon.conf
    # into the image already. Same fix as moonshine-nvidia.
    systemd.services.avahi-daemon.serviceConfig.ConfigurationDirectory =
      lib.mkForce "";

    # ── Flatpak + Bazaar app store ──────────────────────────────────────
    # Bazaar (github.com/kolunmi/bazaar) is a new Flatpak-first app store;
    # installed *via Flathub* rather than a bespoke Nix derivation so we
    # ride upstream releases of a young project.
    #
    # First-boot install runs in the background via a systemd oneshot
    # (nix-flatpak's activation service). Bazaar won't show up in Plasma's
    # application menu until that finishes — a couple minutes on a fresh
    # VM depending on network. Discover is bundled with Plasma; users get
    # a choice of two Flatpak-capable stores out of the box.
    services.flatpak.enable = true;
    services.flatpak.remotes = [{
      name = "flathub";
      location = "https://flathub.org/repo/flathub.flatpakrepo";
    }];
    services.flatpak.packages = [
      "flathub:app/io.github.kolunmi.Bazaar//stable"
    ];

    # ── Minimal usable desktop ──────────────────────────────────────────
    # Kept intentionally small — the point of bundling Bazaar is that the
    # user installs everything else themselves via GUI post-boot.
    environment.systemPackages = with pkgs; [
      firefox
      kdePackages.konsole
      kdePackages.dolphin
      kdePackages.kate
    ];

    # Plasma 6 + full driver stack bloats the base image past the default
    # disk allocation (same rationale as moonshine-nvidia). Bump to 16 GiB;
    # the output qcow2 is sparse so unused space costs nothing on disk.
    virtualisation.diskSize = lib.mkForce 16384;

    # Moonlight/GameStream firewall ports are seeded into the per-VM
    # machines/<name>/tcp_ports + udp_ports at machine-init time (see
    # src/vm/machine.clj) rather than baked into the image — this matches
    # how every other profile in this repo handles ports and keeps them
    # visible/editable via `just upgrade`.
  };
}
