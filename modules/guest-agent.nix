{ config, lib, ... }:
# VM-only: the QEMU guest agent is meaningless in an LXC container.
lib.mkIf (!config.vm.container) {
  services.qemuGuest.enable = true;
}
