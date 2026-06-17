# Semi-mutable profile - writable /nix overlay on immutable root
#
# Adds an overlayfs on /nix backed by /var/nix-overlay, allowing
# runtime package installation while keeping the root read-only.
# The overlay is wiped on upgrade.
#
# Combine with other profiles: woodpecker,docker,semi-mutable
{ config, lib, ... }:

{
  config = {
    assertions = [{
      assertion = !config.vm.mutable;
      message = "The mutable and semi-mutable profiles are mutually exclusive.";
    }];
    vm.nixOverlay = true;
  };
}
