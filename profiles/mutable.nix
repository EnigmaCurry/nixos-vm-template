# Mutable profile - standard read-write NixOS system
#
# Enables mutable mode: single read-write disk with full nix toolchain.
# Users can nixos-rebuild, install packages, and modify the system freely.
# Use as a base and add profiles on top: mutable,docker, mutable,dev, etc.
{ config, lib, ... }:

{
  config = {
    assertions = [{
      assertion = !config.vm.nixOverlay;
      message = "The mutable and semi-mutable profiles are mutually exclusive.";
    }];
    vm.mutable = true;
  };
}
