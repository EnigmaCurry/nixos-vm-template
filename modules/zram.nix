# Optional zram compressed swap support
{ config, lib, ... }:

{
  options.vm.zram = {
    enable = lib.mkEnableOption "zram compressed swap";

    memoryPercent = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = "Percentage of RAM to use for zram (100 = same size as RAM)";
    };

    algorithm = lib.mkOption {
      type = lib.types.str;
      default = "zstd";
      description = "Compression algorithm (zstd, lz4, lzo)";
    };
  };

  config = lib.mkIf config.vm.zram.enable {
    zramSwap = {
      enable = true;
      memoryPercent = config.vm.zram.memoryPercent;
      algorithm = config.vm.zram.algorithm;
    };

    # High swappiness to prefer zram over OOM
    boot.kernel.sysctl."vm.swappiness" = 100;
  };
}
