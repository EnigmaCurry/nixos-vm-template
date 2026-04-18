# pocket-tts profile - Text-to-Speech service
# https://github.com/enigmacurry/pocket-tts
{ config, lib, pkgs, ... }:

{
  imports = [
    ./python.nix
  ];

  config = {
    networking.firewall.allowedTCPPorts = [ 8956 ];

    systemd.services.pocket-tts = {
      description = "pocket-tts TTS server";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.uv}/bin/uvx pocket-tts serve --port 8956";
        Restart = "on-failure";
        RestartSec = 5;
        User = "user";
        Group = "users";
        WorkingDirectory = "/var/home/user";
        Environment = [
          "HOME=/var/home/user"
          "UV_CACHE_DIR=/var/home/user/.cache/uv"
        ];
      };
    };
  };
}
