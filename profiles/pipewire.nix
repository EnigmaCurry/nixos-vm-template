# Pipewire audio server profile
# Enables pipewire with ALSA, PulseAudio, and JACK compatibility
# For host audio passthrough, also enable pipewire in machines/<name>/pipewire
{ config, lib, pkgs, ... }:

{
  config = {
    # Enable pipewire as the audio server
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      jack.enable = true;
    };

    # Disable PulseAudio (pipewire replaces it)
    services.pulseaudio.enable = false;

    # Enable rtkit for realtime scheduling (improves audio latency)
    security.rtkit.enable = true;

    # Add audio group to users
    users.users.${config.core.adminUser}.extraGroups = [ "audio" ];
    users.users.${config.core.regularUser}.extraGroups = [ "audio" ];

    # Install useful audio tools
    environment.systemPackages = with pkgs; [
      # Pipewire tools
      pipewire         # pw-top, pw-cli, pw-dump, pw-mon
      wireplumber      # wpctl (session manager CLI)

      # PulseAudio-compatible tools (work with pipewire)
      pamixer          # CLI mixer
      pulsemixer       # TUI mixer
      pulseaudio       # pactl, paplay utilities

      # ALSA tools and development libraries
      alsa-lib         # ALSA library
      alsa-lib.dev     # ALSA headers and pkg-config (for cargo builds)
      pkg-config       # pkg-config tool
      alsa-utils       # aplay, arecord, amixer, speaker-test
      alsa-plugins     # Additional ALSA plugins

      # MIDI synthesizers and soundfonts
      fluidsynth
      soundfont-fluid
      soundfont-generaluser
      soundfont-ydp-grand
      x42-gmsynth
    ];

    # Set PKG_CONFIG_PATH so cargo builds can find alsa.pc
    environment.sessionVariables.PKG_CONFIG_PATH = "/run/current-system/sw/lib/pkgconfig";

    # Configure ALSA to use pipewire as the default device
    environment.etc."asound.conf".text = ''
      pcm.!default {
        type pipewire
      }
      ctl.!default {
        type pipewire
      }
    '';
  };
}
