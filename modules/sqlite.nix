# SQLite module - provides sqlite3 for development
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    sqlite
  ];
}
