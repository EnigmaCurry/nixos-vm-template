# Kubernetes client tools profile
{ config, lib, pkgs, ... }:

{
  config = {
    environment.systemPackages = with pkgs; [
      kubectl
      kubernetes-helm
      k9s
      kustomize
      kubectx
      talosctl
      cmctl
    ];
  };
}
