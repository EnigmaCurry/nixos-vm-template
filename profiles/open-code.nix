# OpenCode profile - open source coding agent CLI
# https://github.com/sst/opencode
{ config, lib, pkgs, ... }:

{
  imports = [
    ./dev.nix
    ../modules/block-private-networks.nix
  ];

  config = {
    environment.systemPackages = with pkgs; [
      nodejs
    ];

    # Configure npm to use user-local directory and install opencode-ai
    environment.interactiveShellInit = ''
      # Set up npm global directory in user home (nix store is read-only)
      export NPM_CONFIG_PREFIX="$HOME/.npm-global"
      export PATH="$HOME/.npm-global/bin:$PATH"

      # Skip installation for root user
      if [ "$(id -u)" != "0" ]; then
        # Install opencode-ai on first login
        if [ ! -x "$HOME/.npm-global/bin/opencode" ]; then
          echo "Installing OpenCode..."
          mkdir -p "$HOME/.npm-global"
          npm install -g opencode-ai@latest
          echo "OpenCode installed! Run 'opencode' to start."
        fi

        # Create default opencode config for Opus 4.5 if not present
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
