{ config, lib, imageVersion, ... }:

{
  environment.etc."nixos-image-version" = {
    text = imageVersion;
    mode = "0444";
  };
}
