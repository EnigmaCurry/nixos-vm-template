{ buildGoModule, lib }:

buildGoModule {
  pname = "wg-auth";
  version = "0.1.0";
  src = ./.;

  # No external module deps — vendorHash = null skips vendor fetching.
  vendorHash = null;

  meta = {
    description = "IP-to-wg-peer-user forward-auth service for Traefik";
    license = lib.licenses.mit;
    mainProgram = "wg-auth";
  };
}
