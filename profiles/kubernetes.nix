# Kubernetes client tools profile
{ config, lib, pkgs, ... }:

{
  config = {
    environment.systemPackages = with pkgs; [
      kubectl
      helm
      k9s
      kustomize
      kubectx
    ];
  };
}
