# Core profile - base system with SSH
{ config, lib, pkgs, ... }:

{
  imports = [
    ../modules/ssh.nix
  ];

  options.core = {
    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Username for the admin account (has sudo access)";
    };

    regularUser = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = "Username for the regular account (no sudo access)";
    };
  };

  config = {
    # Create /bin/bash symlink during image build (for scripts with #!/bin/bash)
    system.activationScripts.binbash = lib.stringAfter [ "binsh" ] ''
      ln -sfn ${pkgs.bashInteractive}/bin/bash /bin/bash
    '';

    # Minimal packages for all VMs
    environment.systemPackages = with pkgs; [
      vim
      curl
      htop
      git
      duf
      ripgrep
      jq
      dig
      just
      pciutils
      parted
      unzip
      wireguard-tools
      file
    ];

    # Enable firewall - blocks all incoming by default
    networking.firewall.enable = true;

    # Subuid/subgid allocation for user namespaces (rootless containers, etc.)
    users.users.${config.core.adminUser} = {
      subUidRanges = [{ startUid = 100000; count = 65536; }];
      subGidRanges = [{ startGid = 100000; count = 65536; }];
    };

    users.users.${config.core.regularUser} = {
      subUidRanges = [{ startUid = 200000; count = 65536; }];
      subGidRanges = [{ startGid = 200000; count = 65536; }];
    };
  };
}
