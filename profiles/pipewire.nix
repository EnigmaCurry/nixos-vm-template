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
      pavucontrol      # PulseAudio volume control (works with pipewire)
      pulseaudio       # For pactl, paplay utilities
      alsa-utils       # For aplay, speaker-test
    ];

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
