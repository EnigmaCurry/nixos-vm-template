# Docker development profile - Docker with user access
{ config, lib, pkgs, ... }:

{
  imports = [ ./docker.nix ];

  # Add regular user to docker group
  users.users.${config.core.regularUser}.extraGroups = [ "docker" ];
}
