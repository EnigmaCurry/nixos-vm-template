# OpenCode profile - open source coding agent CLI
# https://github.com/sst/opencode
{ config, lib, pkgs, opencode, ... }:

{
  imports = [
    ../modules/block-private-networks.nix
  ];

  config = {
    environment.systemPackages = [
      opencode.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];

    # Create default opencode config for Opus 4.5 if not present
    environment.interactiveShellInit = ''
      # Skip for root user
      if [ "$(id -u)" != "0" ]; then
        if [ ! -f "$HOME/.config/opencode/config.json" ]; then
          mkdir -p "$HOME/.config/opencode"
          cat > "$HOME/.config/opencode/config.json" <<'OCEOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "anthropic/claude-opus-4-5-20251101",
  "provider": {
    "anthropic": {}
  }
}
OCEOF
        fi
      fi
    '';
  };
}
