# Traefik reverse proxy driven by a single per-VM config directory in the
# machine dir. Standard Traefik YAML/TOML — put the static config in
# machines/<name>/traefik/traefik.yml and any dynamic (file provider) rules
# under machines/<name>/traefik/dynamic/*.yml. Both are staged verbatim.
#
# The on-VM path differs by mode:
#
#   immutable:  /var/identity/traefik/{traefik.yml,dynamic/*}
#   mutable:    /etc/traefik/{traefik.yml,dynamic/*}
#
# Absent (ConditionPathExists on traefik.yml fails) -> the service silently
# no-ops at boot, so the same image serves configured and unconfigured VMs.
#
# ── Dynamic config ───────────────────────────────────────────────────────────
# This profile does not touch Traefik's dynamic config. To use the file
# provider (routers/middlewares/services in per-file YAML), declare it inside
# your static traefik.yml, e.g.:
#
#   providers:
#     file:
#       directory: /var/identity/traefik/dynamic   # or /etc/traefik/dynamic
#       watch: true
#
# Files under dynamic/ are hot-reloaded by Traefik itself. Static config
# changes require: sudo systemctl restart traefik.
#
# ── Persistent state ─────────────────────────────────────────────────────────
# /var/lib/traefik (traefik:traefik, mode 0700) is created by the upstream
# module and lives on the /var disk. Point ACME storage at it, e.g.:
#
#   certificatesResolvers:
#     letsencrypt:
#       acme:
#         storage: /var/lib/traefik/acme.json
#         ...
#
# ── Listening on wireguard only ──────────────────────────────────────────────
# Set the entrypoint address to the wg IP in traefik.yml, e.g.:
#
#   entryPoints:
#     web:
#       address: 10.0.0.1:80
#
# net.ipv4.ip_nonlocal_bind = 1 (set below) lets traefik bind that address
# even before wg0 is up. Traffic still has to pass wg-input in wireguard.nft.

{ config, lib, pkgs, ... }:

let
  mutable = config.vm.mutable;
  cfgDir  = if mutable then "/etc/traefik" else "/var/identity/traefik";
  staticFile = "${cfgDir}/traefik.yml";
  # acme-dns provider config for the built-in ACME client. The env file sets
  # ACME_DNS_API_BASE (server URL) and ACME_DNS_STORAGE_PATH (per-domain JSON).
  # "-" prefix on EnvironmentFile makes it non-fatal if missing, so a VM with
  # no acme-dns setup boots traefik normally.
  acmeDnsEnv = if mutable then "/etc/acme-dns.env" else "/var/identity/acme-dns.env";
  # Source of truth (workstation-managed, staged by sync-identity) vs. runtime
  # copy in traefik's writable state dir. `services.traefik` runs with
  # `ProtectSystem=strict` (via NixOS defaults), so /etc is a read-only FS
  # from lego's perspective — lego calls storage.Save() on every challenge,
  # which fails EROFS. Copy the file into /var/lib/traefik at boot with
  # traefik ownership so lego can read + write it freely.
  acmeDnsJsonSrc = if mutable then "/etc/acme-dns.json" else "/var/identity/acme-dns.json";
  acmeDnsJsonDst = "/var/lib/traefik/acme-dns.json";
in
{
  services.traefik = {
    enable = true;
    staticConfigFile = staticFile;
  };

  systemd.services.traefik = lib.mkMerge [
    { unitConfig.ConditionPathExists = staticFile;
      serviceConfig.EnvironmentFile = [ "-${acmeDnsEnv}" ];
      requires = [ "acme-dns-storage.service" ];
      after = [ "acme-dns-storage.service" ]; }
    (lib.mkIf (!mutable) {
      unitConfig.RequiresMountsFor = "/var/identity";
      after = [ "var.mount" ];
    })
  ];

  # Copy the workstation-staged acme-dns.json into traefik's writable state
  # dir before traefik starts. No-op if the source file is absent (acme-dns
  # feature disabled). Runs on every boot so sync-identity → reboot picks up
  # workstation edits; lego's own runtime writes are lost on reboot, which is
  # fine because our `just acme-register` workflow pre-populates every domain
  # (lego never auto-registers).
  systemd.services.acme-dns-storage = {
    description = "Stage acme-dns.json into traefik's state dir";
    before = [ "traefik.service" ];
    wantedBy = [ "traefik.service" ];
    unitConfig.ConditionPathExists = acmeDnsJsonSrc;
    serviceConfig.Type = "oneshot";
    # Deliberately no RemainAfterExit: we want the copy to re-run on every
    # `systemctl restart traefik`, so sync-identity edits take effect without
    # a reboot or a manual restart of this unit.
    script = ''
      mkdir -p /var/lib/traefik
      install -m 0600 -o traefik -g traefik "${acmeDnsJsonSrc}" "${acmeDnsJsonDst}"
    '';
  };

  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;
}
