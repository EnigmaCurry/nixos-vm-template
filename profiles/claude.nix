# Claude Code profile - Anthropic's CLI for Claude
{ config, lib, pkgs, ... }:

let
  claude-backup = pkgs.writeShellScriptBin "claude-backup" ''
    set -euo pipefail
    TIMESTAMP=$(date +%Y%m%dT%H%M%S)
    BACKUP_NAME="claude-backup-$(hostname).$TIMESTAMP.tar.gz"
    BACKUP_PATH="$HOME/$BACKUP_NAME"

    # Build list of existing paths to backup
    PATHS_TO_BACKUP=()
    for p in "$HOME/.ssh" "$HOME/.claude" "$HOME/.claude.json" "$HOME/git"; do
      if [ -e "$p" ]; then
        PATHS_TO_BACKUP+=("$p")
      fi
    done

    if [ ''${#PATHS_TO_BACKUP[@]} -eq 0 ]; then
      echo "No files to backup."
      exit 0
    fi

    echo "Creating backup: $BACKUP_PATH"
    tar -czf "$BACKUP_PATH" --exclude='target' --exclude='node_modules' "''${PATHS_TO_BACKUP[@]}"
    echo "Backup complete: $BACKUP_PATH"
    ls -lh "$BACKUP_PATH"
  '';
in
{
  imports = [
    ../modules/block-private-networks.nix
  ];

  config = {
    environment.systemPackages = with pkgs; [
      nodejs
      claude-backup
    ];

    # Configure npm to use user-local directory and install claude-code
    environment.interactiveShellInit = ''
      # Set up npm global directory in user home (nix store is read-only)
      export NPM_CONFIG_PREFIX="$HOME/.npm-global"
      export PATH="$HOME/.npm-global/bin:$PATH"

      # Install claude-code on first login (skip for root)
      if [ "$(id -u)" != "0" ] && [ ! -x "$HOME/.npm-global/bin/claude" ]; then
        echo "Installing Claude Code..."
        mkdir -p "$HOME/.npm-global"
        npm install -g @anthropic-ai/claude-code
        echo "Claude Code installed! Run 'claude' to start."
      fi
    '';
  };
}
