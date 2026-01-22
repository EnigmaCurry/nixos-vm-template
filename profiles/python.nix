# Python development profile - uv package manager
{ config, lib, pkgs, ... }:

{
  imports = [
    ../modules/sqlite.nix
  ];

  config = {
    # Enable nix-ld to run dynamically linked binaries (uv downloads pre-built Python)
    programs.nix-ld.enable = true;

    environment.systemPackages = with pkgs; [
      uv
      # Build tools for compiling Python packages with C extensions
      gcc
      gnumake
      pkg-config
      openssl.dev
      zlib.dev
      libffi.dev
    ];
  };
}
