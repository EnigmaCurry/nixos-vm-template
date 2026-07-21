# Mutual-exclusion marker for Moonlight-protocol streaming servers.
# Both moonshine-nvidia and sunshine-plasma-nvidia bind the same well-known
# ports (47984/47989/48010 TCP, 47998-48000 UDP), so at most one may be
# active in a given VM. Each streaming profile assigns this option; Nix
# errors naturally on double-assignment since we don't use mkDefault.
{ lib, ... }:

{
  options.vm.streamingServer = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum [ "moonshine" "sunshine" ]);
    default = null;
    description = ''
      Which Moonlight-protocol server (if any) owns the streaming ports on
      this VM. Set by the moonshine-nvidia and sunshine-plasma-nvidia
      profiles; users should not set it directly.
    '';
  };
}
