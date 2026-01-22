# Core profile - base system with SSH
{ config, lib, pkgs, ... }:

{
  imports = [
    ./base.nix
    ./ssh.nix
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
}
