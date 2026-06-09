# Woodpecker CI agent profile - local/exec backend
#
# Runs a Woodpecker agent using the "local" backend (no containers).
# Pipeline steps execute directly on the VM, making Nix builds straightforward.
#
# Configuration via /var/identity/woodpecker.env:
#   WOODPECKER_SERVER=woodpecker.example.com:9000
#   WOODPECKER_AGENT_SECRET=your-shared-secret
#
# Additional environment variables can be set in this file, see:
# https://woodpecker-ci.org/docs/administration/configuration/agent
{ config, lib, pkgs, ... }:

{
  config = {
    services.woodpecker-agents.agents.exec = {
      enable = true;
      environment = {
        WOODPECKER_BACKEND = "local";
        WOODPECKER_HEALTHCHECK = "true";
        WOODPECKER_GRPC_SECURE = "true";
        WOODPECKER_AGENT_CONFIG_FILE = "/var/lib/woodpecker/agent.conf";
      };
      environmentFile = [ "/var/identity/woodpecker.env" ];
      path = [
        pkgs.git
        pkgs.git-lfs
        pkgs.woodpecker-plugin-git
        pkgs.bash
        pkgs.coreutils
        pkgs.nix
        pkgs.gnutar
        pkgs.gzip
        pkgs.curl
        pkgs.jq
        pkgs.qemu-utils
        pkgs.openssh
      ];
    };

    # The upstream NixOS module uses DynamicUser + ProtectSystem=strict,
    # which prevents the local backend from running nix builds or writing
    # to the workspace. Override to run as a dedicated system user instead.
    systemd.services.woodpecker-agent-exec = {
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "woodpecker";
        Group = "woodpecker";
        ProtectSystem = lib.mkForce "full";
        PrivateTmp = lib.mkForce false;
        PrivateDevices = lib.mkForce false;
        PrivateUsers = lib.mkForce false;
        PrivateMounts = lib.mkForce false;
        MemoryDenyWriteExecute = lib.mkForce false;
        ReadWritePaths = [
          "/var/lib/woodpecker"
          "/nix"
          "/tmp"
        ];
        WorkingDirectory = "/var/lib/woodpecker";
        SystemCallFilter = lib.mkForce "";
      };
    };

    # Dedicated woodpecker user with nix access
    users.users.woodpecker = {
      isSystemUser = true;
      group = "woodpecker";
      home = "/var/lib/woodpecker";
      shell = pkgs.bash;
    };
    users.groups.woodpecker = {};

    # Ensure workspace directory exists on /var
    systemd.tmpfiles.rules = [
      "d /var/lib/woodpecker 0755 woodpecker woodpecker -"
    ];

    # Allow woodpecker user to use nix
    nix.settings.trusted-users = [ "woodpecker" ];

    # Generate SSH config and gitconfig from deploy keys at boot.
    # Deploy keys in /var/identity/deploy_keys/ as pairs:
    #   <name>      - private key file
    #   <name>.conf - config with host, port, owner, repo (one key=value per line)
    # Example .conf for GitHub:
    #   host=github.com
    #   owner=EnigmaCurry
    #   repo=nixos-vm-template
    # Example .conf for self-hosted Forgejo on port 2222:
    #   host=git.example.com
    #   port=2222
    #   owner=org
    #   repo=project
    systemd.services.woodpecker-deploy-keys = {
      description = "Configure SSH and git for deploy keys";
      wantedBy = [ "multi-user.target" ];
      before = [ "woodpecker-agent-exec.service" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        DEPLOY_DIR="/var/identity/deploy_keys"
        HOME_DIR="/var/lib/woodpecker"
        SSH_DIR="$HOME_DIR/.ssh"

        if [ ! -d "$DEPLOY_DIR" ] || [ -z "$(ls -A "$DEPLOY_DIR"/*.conf 2>/dev/null)" ]; then
          echo "No deploy keys found, skipping."
          exit 0
        fi

        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"

        SSH_CONFIG="$SSH_DIR/config"
        GIT_CONFIG="$HOME_DIR/.gitconfig"

        : > "$SSH_CONFIG"
        : > "$GIT_CONFIG"

        for conf in "$DEPLOY_DIR"/*.conf; do
          [ -f "$conf" ] || continue
          keyfile="''${conf%.conf}"
          if [ ! -f "$keyfile" ]; then
            echo "Skipping $(basename "$conf"): no matching key file"
            continue
          fi

          # Parse config
          host="" port="22" owner="" repo=""
          while IFS='=' read -r k v; do
            case "$k" in
              host) host="$v" ;;
              port) port="$v" ;;
              owner) owner="$v" ;;
              repo) repo="$v" ;;
            esac
          done < "$conf"

          if [ -z "$host" ] || [ -z "$owner" ] || [ -z "$repo" ]; then
            echo "Skipping $(basename "$conf"): missing host, owner, or repo"
            continue
          fi

          filename="$(basename "$keyfile")"
          host_alias="''${host//./-}"
          alias="deploy--''${host_alias}--''${owner}--''${repo}"

          # Copy key to .ssh so permissions are under woodpecker's home
          cp "$keyfile" "$SSH_DIR/$filename"
          chmod 600 "$SSH_DIR/$filename"

          printf '%s\n' \
            "Host $alias" \
            "    HostName $host" \
            "    Port $port" \
            "    User git" \
            "    IdentityFile $SSH_DIR/$filename" \
            "    IdentitiesOnly yes" \
            "    StrictHostKeyChecking accept-new" \
            "" >> "$SSH_CONFIG"

          if [ "$port" = "22" ]; then
            # Standard port: rewrite git@host:owner/repo style URLs
            ${pkgs.git}/bin/git config -f "$GIT_CONFIG" \
              "url.git@''${alias}:''${owner}/''${repo}.insteadOf" \
              "git@''${host}:''${owner}/''${repo}"
          fi
          # Always add ssh:// rewrite (works for any port)
          ${pkgs.git}/bin/git config -f "$GIT_CONFIG" \
            "url.ssh://git@''${alias}/''${owner}/''${repo}.insteadOf" \
            "ssh://git@''${host}:''${port}/''${owner}/''${repo}"
          # Rewrite HTTPS URLs to SSH (Woodpecker clones via HTTPS)
          ${pkgs.git}/bin/git config -f "$GIT_CONFIG" --add \
            "url.ssh://git@''${alias}/''${owner}/''${repo}.insteadOf" \
            "https://''${host}/''${owner}/''${repo}"

          echo "Configured deploy key: ssh://git@$host:$port/$owner/$repo -> $alias"
        done

        chmod 600 "$SSH_CONFIG"
        chown -R woodpecker:woodpecker "$SSH_DIR" "$GIT_CONFIG"
        echo "Deploy key configuration complete."
      '';
    };
  };
}
