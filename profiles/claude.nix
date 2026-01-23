# Claude Code profile - Anthropic's CLI for Claude
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

    # Configure npm to use user-local directory and install claude-code
    environment.interactiveShellInit = ''
      # Set up npm global directory in user home (nix store is read-only)
      export NPM_CONFIG_PREFIX="$HOME/.npm-global"
      export PATH="$HOME/.npm-global/bin:$PATH"

      # Install claude-code on first login
      if [ ! -x "$HOME/.npm-global/bin/claude" ]; then
        echo "Installing Claude Code..."
        mkdir -p "$HOME/.npm-global"
        npm install -g @anthropic-ai/claude-code
        echo "Claude Code installed! Run 'claude' to start."
      fi
    '';
  };
}
