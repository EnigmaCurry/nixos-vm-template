# Podman development profile - rootless Podman for development
{ config, lib, pkgs, ... }:

{
  imports = [ ./podman.nix ];

  # Podman is rootless by default, so both admin and regular users
  # can use it without additional group membership (unlike Docker).
  # Subuid/subgid ranges are configured in core.nix.

  environment.systemPackages = with pkgs; [
    distrobox
    buildah
    skopeo
  ];
}
