# WireGuard VPN driven by a single per-VM identity file. Standard wg-quick
# format — one [Interface] section plus any number of [Peer] sections. The
# on-VM path differs by mode:
#
#   immutable:  /var/identity/wireguard.conf   (staged onto /var disk)
#   mutable:    /etc/wireguard/wg0.conf        (staged into rootfs at create)
#
# Absent (or the service condition fails) -> wg-quick silently skips at boot,
# so the same image serves configured and unconfigured VMs.
#
# Example:
#   [Interface]
#   # hostname: this-vm            # optional — read by wireguard-nft
#   PrivateKey = <this-vm-private-key>
#   Address    = 10.0.0.2/24
#   # ListenPort = 51820           # only for peers that accept inbound
#
#   [Peer]
#   # hostname: hub                # optional — exposed as $hub in wireguard.nft
#   PublicKey  = <hub-public-key>
#   Endpoint   = hub.example.com:51820
#   AllowedIPs = 10.0.0.0/24
#   PersistentKeepalive = 25
#
# The interface name is fixed as `wg0`. If ListenPort is set, also add the
# UDP port to udp_ports (WireGuard is UDP-only). `just create` seeds a
# fresh keypair the first time it sees the profile; recreate/upgrade
# preserve the key because it lives in machines/<name>/wireguard.conf.
#
# ── Peer ACL (wireguard.nft) ─────────────────────────────────────────────
# machines/<name>/wireguard.nft holds up to three nftables chains that
# govern wg0 traffic on this VM:
#
#   chain wg-input      — traffic from wg0 hitting THIS peer's own services.
#                         Authoritative for wg0 (bypasses tcp_ports/udp_ports
#                         via networking.firewall.trustedInterfaces).
#   chain wg-forward    — traffic passing between wg peers through this peer.
#                         Only meaningful if this peer is a hub.
#   chain wg-prerouting — optional NAT prerouting rules for wg0 (redirect /
#                         dnat). Only installed if defined; unmatched packets
#                         fall through unchanged.
#
# Peer names come from `# hostname: <name>` comments in wireguard.conf and
# are exposed as `$name` variables. Each filter chain defaults to drop;
# users add explicit accept rules.
#
# Default is deny-everything for wg0 in both filter directions. If
# wireguard.nft is missing (or omits a chain body for a direction), the
# service synthesizes a drop-only chain for that direction — so a VM with
# the `wireguard` profile but no ACL file has wg0 fully locked down. Users
# open traffic by writing accept rules; `just create` seeds an
# all-commented template. wg-prerouting has no default (NAT is opt-in).
#
# ── Forwarding note ──────────────────────────────────────────────────────
# net.ipv4.ip_forward is enabled unconditionally so any peer can act as a
# hub by writing accept rules into wg-forward. Safe on single-NIC VMs (the
# usual case in this repo). On a multi-NIC VM (bridges, docker, wlan0+eth0),
# non-wg forwarding paths are left at the kernel default and are NOT
# filtered by this profile — add your own drop rules if that matters.

{ config, lib, pkgs, ... }:

let
  mutable = config.vm.mutable;
  wgConfPath = if mutable then "/etc/wireguard/wg0.conf"       else "/var/identity/wireguard.conf";
  wgNftPath  = if mutable then "/etc/wireguard/wireguard.nft"  else "/var/identity/wireguard.nft";

  builder = pkgs.writeShellScript "wireguard-nft-build" ''
    set -euo pipefail

    wg_conf=${wgConfPath}
    wg_nft=${wgNftPath}

    # No wg config -> tear down any prior table and exit clean; wg-quick
    # isn't running so wg0 doesn't exist and there's nothing to filter.
    if [ ! -f "$wg_conf" ]; then
      ${pkgs.nftables}/bin/nft "add table inet wireguard; delete table inet wireguard" || true
      exit 0
    fi

    # ACL is default-deny. If wireguard.nft is missing OR doesn't define a
    # chain body for a direction, we synthesize a drop-only chain for it.
    # Users open specific traffic by writing wg-input / wg-forward chains
    # in machines/<name>/wireguard.nft; anything they don't allow is dropped.
    has_input=0
    has_forward=0
    has_prerouting=0
    if [ -f "$wg_nft" ]; then
      ${pkgs.gnugrep}/bin/grep -qE '^[[:space:]]*chain[[:space:]]+wg-input[[:space:]]*\{'      "$wg_nft" && has_input=1      || true
      ${pkgs.gnugrep}/bin/grep -qE '^[[:space:]]*chain[[:space:]]+wg-forward[[:space:]]*\{'    "$wg_nft" && has_forward=1    || true
      ${pkgs.gnugrep}/bin/grep -qE '^[[:space:]]*chain[[:space:]]+wg-prerouting[[:space:]]*\{' "$wg_nft" && has_prerouting=1 || true
    fi

    ruleset=$(mktemp)
    trap 'rm -f "$ruleset"' EXIT

    {
      # Idempotent reset (all three statements run in one nft transaction).
      echo "add table inet wireguard"
      echo "delete table inet wireguard"
      echo ""
      echo "table inet wireguard {"

      # Peer defines from `# hostname: X` comments. [Interface] uses the
      # Address = A.B.C.D/N line; [Peer] uses AllowedIPs = A.B.C.D/N (first
      # entry). Missing hostname -> that peer has no define and can only
      # be referenced by bare IP.
      #
      # Peer names may contain characters (`-`, `.`) that are legal in wg /
      # DNS naming but illegal in nftables identifiers. We translate those
      # to `_` for the define name and print the original as a `# peer:`
      # comment so the mapping is discoverable in `nft list table inet
      # wireguard`. Reference the translated form in your rules
      # (e.g. peer `mike-xps13` → `$mike_xps13`).
      ${pkgs.gawk}/bin/awk '
        function nft_id(s,   r) { r = s; gsub(/[^A-Za-z0-9_]/, "_", r); return r }
        BEGIN { name = "" }
        /^\[/ { name = "" }
        /^#[[:space:]]*hostname:[[:space:]]*/ {
          sub(/^#[[:space:]]*hostname:[[:space:]]*/, "");
          name = $1;
        }
        /^Address[[:space:]]*=/ && name != "" {
          split($0, parts, "=");
          ip = parts[2];
          gsub(/[[:space:]]/, "", ip);
          sub(/\/.*/, "", ip);
          id = nft_id(name);
          if (id != name) printf "  # peer: %s\n", name;
          printf "  define %s = %s\n", id, ip;
          name = "";
        }
        /^AllowedIPs[[:space:]]*=/ && name != "" {
          split($0, parts, "=");
          ip = parts[2];
          gsub(/[[:space:]]/, "", ip);
          sub(/,.*/, "", ip);
          sub(/\/.*/, "", ip);
          id = nft_id(name);
          if (id != name) printf "  # peer: %s\n", name;
          printf "  define %s = %s\n", id, ip;
          name = "";
        }
      ' "$wg_conf"

      # User's chain bodies verbatim (indented one level), if present.
      if [ -f "$wg_nft" ]; then
        echo ""
        ${pkgs.gawk}/bin/awk '{ print "  " $0 }' "$wg_nft"
      fi

      # Synthesize a drop-only chain for any direction the user didn't
      # define. This is what makes the default deny-everything.
      if [ "$has_input" = 0 ]; then
        echo ""
        echo "  chain wg-input {"
        echo "    ct state established,related accept"
        echo "    drop"
        echo "  }"
      fi

      if [ "$has_forward" = 0 ]; then
        echo ""
        echo "  chain wg-forward {"
        echo "    ct state established,related accept"
        echo "    drop"
        echo "  }"
      fi

      # Hook chains — always installed so the ACL is authoritative.
      # priority 1: run AFTER nixos-fw (which hooks at priority 0) so our
      # drop overrides its accept (wg0 is in trustedInterfaces so nixos-fw
      # waves it through). Numeric priority is used instead of the `filter`
      # keyword because some nftables builds reject the keyword form here.
      #
      # ICMP echo-request is accepted here (before the jump to wg-input) so
      # ping/reachability testing always works regardless of user rules.
      echo ""
      echo "  chain input {"
      echo "    type filter hook input priority 1;"
      echo "    iifname \"wg0\" icmp   type echo-request accept"
      echo "    iifname \"wg0\" icmpv6 type echo-request accept"
      echo "    iifname \"wg0\" jump wg-input"
      echo "  }"

      # priority 0: nixos-fw doesn't hook forward, so this owns the
      # wg0->wg0 decision outright.
      echo ""
      echo "  chain forward {"
      echo "    type filter hook forward priority 0;"
      echo "    iifname \"wg0\" oifname \"wg0\" jump wg-forward"
      echo "  }"

      # NAT prerouting hook — only installed if the user defined a
      # wg-prerouting chain. Unmatched packets fall through unchanged
      # (no default deny here; that's wg-input's job in the filter path).
      # priority dstnat: standard destination NAT slot, runs before routing.
      if [ "$has_prerouting" = 1 ]; then
        echo ""
        echo "  chain prerouting {"
        echo "    type nat hook prerouting priority -100;"
        echo "    iifname \"wg0\" jump wg-prerouting"
        echo "  }"
      fi

      echo "}"
    } > "$ruleset"

    # Fail closed: if the user's wireguard.nft has a syntax error (or any
    # other reason nft rejects the ruleset), install a minimal drop-only
    # `wireguard` table so wg0 traffic is *not* left unfiltered. Without
    # this, a failed load leaves either the previous table intact OR — on
    # fresh boot — no `wireguard` table at all, which combined with wg0
    # being a trustedInterface means nixos-fw waves everything through.
    # That's how a typo in wireguard.nft silently opens the wg surface.
    #
    # We still exit 1 so the unit is `failed` and shows up red in
    # `systemctl status` / `just upgrade` output — the operator sees the
    # nft error above, fixes wireguard.nft, and re-runs.
    if ! ${pkgs.nftables}/bin/nft -f "$ruleset"; then
      echo "wireguard-nft: RULESET LOAD FAILED — installing fail-closed drop-everything table on wg0" >&2
      echo "wireguard-nft: fix wireguard.nft syntax errors above, then: sudo systemctl restart wireguard-nft" >&2
      failclosed=$(mktemp)
      cat > "$failclosed" <<'FAILCLOSED'
add table inet wireguard
delete table inet wireguard
table inet wireguard {
  chain input {
    type filter hook input priority 1;
    iifname "wg0" drop
  }
  chain forward {
    type filter hook forward priority 0;
    iifname "wg0" drop
  }
}
FAILCLOSED
      if ! ${pkgs.nftables}/bin/nft -f "$failclosed"; then
        echo "wireguard-nft: fail-closed fallback ALSO failed to load — wg0 filtering is in an unknown state" >&2
      fi
      rm -f "$failclosed"
      exit 1
    fi
  '';
in
{
  environment.systemPackages = [ pkgs.wireguard-tools pkgs.nftables ];

  # Enable IP forwarding so this peer can act as a hub when wg-forward
  # rules permit. See the "Forwarding note" in the header.
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  # wg peers are already authenticated by key; skip nixos-fw for wg0 so
  # the wg-input chain is the sole authority for wg-side port exposure.
  # (The chain default-drops if wireguard.nft doesn't override it, so
  # this "trust" is only relative to nixos-fw — traffic still has to
  # pass wg-input.)
  networking.firewall.trustedInterfaces = [ "wg0" ];

  networking.wg-quick.interfaces.wg0.configFile = wgConfPath;

  systemd.services.wg-quick-wg0 = lib.mkMerge [
    { unitConfig.ConditionPathExists = wgConfPath; }
    (lib.mkIf (!mutable) {
      unitConfig.RequiresMountsFor = "/var/identity";
      after = [ "var.mount" ];
    })
  ];

  systemd.services.wireguard-nft = {
    description = "Apply wireguard nftables ACLs";
    wantedBy = [ "multi-user.target" ];
    after = [ "wg-quick-wg0.service" ] ++ lib.optional (!mutable) "var.mount";
    partOf = [ "wg-quick-wg0.service" ];
    unitConfig = {
      ConditionPathExists = wgConfPath;
    } // lib.optionalAttrs (!mutable) {
      RequiresMountsFor = "/var/identity";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${builder}";
      ExecStop  = "${pkgs.nftables}/bin/nft delete table inet wireguard";
      ExecStopPost = "${pkgs.coreutils}/bin/true";
    };
  };
}
