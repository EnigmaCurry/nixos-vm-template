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
  };
}
