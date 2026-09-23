(ns vm.machine
  "The persisted-state layer: the only reader/writer of $MACHINES_DIR/<name>/.
  File names and contents are frozen for byte-compatibility with the Bash
  implementation (existing machines and the .claude skills depend on them)."
  (:require [clojure.string :as str]
            [babashka.fs :as fs]
            [vm.proc :as proc]
            [vm.prompt :as prompt]
            [vm.profile :as profile]
            [vm.net :as net]))

(defn machine-dir [cfg name] (str (:machines-dir cfg) "/" name))

(defn exists? [cfg name] (fs/directory? (machine-dir cfg name)))

(defn field-path [cfg name field] (str (machine-dir cfg name) "/" field))

(defn read-field
  "Read a machine config file trimmed of surrounding whitespace, or nil if absent."
  [cfg name field]
  (let [f (field-path cfg name field)]
    (when (fs/exists? f) (str/trim (slurp f)))))

(defn read-raw
  "Read a machine config file verbatim (no trimming), or nil if absent."
  [cfg name field]
  (let [f (field-path cfg name field)]
    (when (fs/exists? f) (slurp f))))

(defn profile-of [cfg name] (or (read-field cfg name "profile") ""))

(defn- profile-has?
  "True if `token` is a member of the comma-separated profile list."
  [cfg name token]
  (str/includes? (str "," (profile-of cfg name) ",") (str "," token ",")))

(defn mutable? [cfg name] (profile-has? cfg name "mutable"))
(defn semi-mutable? [cfg name] (profile-has? cfg name "semi-mutable"))
(defn pipewire? [cfg name] (profile-has? cfg name "pipewire"))

(defn mode-of
  "VM mutability mode as a display string."
  [cfg name]
  (cond (mutable? cfg name) "mutable"
        (semi-mutable? cfg name) "semi-mutable"
        :else "immutable"))

(defn list-machines
  "Return a sorted vector of {:name :profile} for every machine config dir.
  :profile is \"unknown\" when the machine has no profile file."
  [cfg]
  (let [dir (:machines-dir cfg)]
    (if (fs/directory? dir)
      (->> (fs/list-dir dir)
           (filter fs/directory?)
           (mapv (fn [d]
                   (let [name (fs/file-name d)]
                     {:name name
                      :profile (or (read-field cfg name "profile") "unknown")})))
           (sort-by :name)
           vec)
      [])))

;; ─── pure helpers ────────────────────────────────────────────────────────────

(defn normalize-size
  "Add a 'G' suffix when no unit is given: \"30\" -> \"30G\", \"500M\" -> \"500M\"."
  [size]
  (let [s (str size)]
    (if (re-matches #"[0-9]+" s) (str s "G") s)))

(defn vm-ip
  "The VM's display IP: the static address (CIDR stripped) or \"<ip>\" for DHCP."
  [cfg name]
  (let [f (field-path cfg name "static_ip")]
    (or (when (fs/exists? f)
          (let [addr (->> (str/split-lines (slurp f))
                          (keep #(second (re-matches #"address=(.*)" %)))
                          first)]
            (when-not (str/blank? addr) (first (str/split addr #"/")))))
        "<ip>")))

;; ─── identity generation ─────────────────────────────────────────────────────

(defn- new-uuid [] (str (java.util.UUID/randomUUID)))
(defn- new-machine-id [] (str/replace (new-uuid) "-" ""))
(defn- new-mac []
  (format "52:54:00:%02x:%02x:%02x" (rand-int 256) (rand-int 256) (rand-int 256)))

(defn- key-count
  "Count non-comment, non-blank lines in a file (the Bash `grep -cv '^#\\|^$'`)."
  [path]
  (if (fs/exists? path)
    (->> (str/split-lines (slurp path))
         (remove #(or (str/starts-with? % "#") (str/blank? %)))
         count)
    0))

(def ^:private samba-credentials-template
  "Commented samba_credentials seeded when the samba-mount profile is selected.
  All-commented = no credentials = the mount generator refuses to run."
  (str/join "\n"
            ["# CIFS/SMB mount credentials — mount.cifs credentials-file format."
             "# Consumed by the samba-mount profile (see profiles/samba-mount.nix)."
             "# File is mode 0600 — safe to store plaintext."
             "#"
             "# Uncomment and fill in to enable mounts. Apply changes with:"
             "#   just upgrade <name>   (or  just sync-identity <name> on proxmox-lxc)"
             "#"
             "# Example:"
             "#   username=alice"
             "#   password=hunter2"
             "#   domain=WORKGROUP   # optional"
             ""]))

(def ^:private samba-client-shares-template
  "Commented samba_client_shares seeded when the samba-mount profile is selected.
  All-commented = no shares = the mount generator is a no-op."
  (str/join "\n"
            ["# CIFS/SMB client mounts — one share per line, whitespace-separated:"
             "#   <mount-point>  <//server/share>  [extra,mount,opts]"
             "#"
             "# Consumed by the samba-mount profile. Each entry becomes a systemd"
             "# .automount unit so an unreachable server never blocks boot."
             "# Credentials come from samba_credentials (same directory)."
             "#"
             "# Mount points must live on a writable filesystem. On immutable /"
             "# semi-mutable VMs the root filesystem is read-only, so /mnt, /opt,"
             "# /srv etc. can't be used. Use /var/mnt/* by convention (writable,"
             "# persistent, on the /var disk). Paths under /home and /tmp also work."
             "#"
             "# Default ownership: user:users (uid 1001/gid 100), mode 0664/0775."
             "# Common overrides (put in the extras column; later values win):"
             "#   uid=N,gid=N,forceuid,forcegid   present as UID N; perms enforced"
             "#                                    (docker container running as N)"
             "#   noperm                           disable client perm checks — any"
             "#                                    UID can rw (multi-container / mixed)"
             "#   file_mode=NNNN,dir_mode=NNNN     override the 0664/0775 defaults"
             "#   ro                               read-only mount"
             "# CIFS uid=/gid= are numeric only (no user/group names)."
             "#"
             "# Apply changes with:"
             "#   just upgrade <name>   (or  just sync-identity <name> on proxmox-lxc)"
             "#"
             "# Examples:"
             "#   /var/mnt/roms    //nas.local/roms"
             "#   /var/mnt/media   //10.0.0.5/media  ro"
             "#   # docker container as UID 1000, perms enforced client-side:"
             "#   /var/mnt/immich  //nas.local/immich  uid=1000,gid=1000,forceuid,forcegid"
             "#   # fully open — any host/container UID can rw:"
             "#   /var/mnt/scratch //nas.local/scratch  uid=0,gid=0,file_mode=0666,dir_mode=0777,noperm"
             ""]))

(def ^:private nas-passwd-template
  "Commented NAS users file (mode 0600) seeded for nas containers. Shared by
  Samba and copyparty."
  (str/join "\n"
            ["# NAS users (Samba + copyparty) — one per line: <user> <password>"
             "# Plaintext (this file is mode 0600). Apply changes with:"
             "#   just sync-identity <name>"
             "#"
             "# Examples:"
             "#   alice  s3cret"
             "#   bob    hunter2"
             ""]))

(def ^:private nas-acl-template
  "Commented NAS ACL seeded for nas containers. Shared by Samba and copyparty;
  deny-by-default (no rule = no access)."
  (str/join "\n"
            ["# NAS per-user ACL (Samba + copyparty web/WebDAV)."
             "#"
             "# One rule per line:   <user> <share> <access>"
             "#   access = r | rw   (r = read-only, rw = read-write)"
             "#   user   = a name (must be defined in nas_passwd), or * for guest/anonymous"
             "#   share  = a share name (bind-mount basename, e.g. nas), or * for ALL shares"
             "#"
             "# DENY BY DEFAULT: a user/guest gets only what an explicit rule grants;"
             "# no rule means no access (over both Samba and copyparty)."
             "#"
             "# Apply changes with:  just sync-identity <name>"
             "#"
             "# Examples:"
             "#   alice  *      rw     # alice: read-write on every share"
             "#   bob    nas    r      # bob: read-only on share 'nas'"
             "#   *      media  r      # guests: read-only on 'media'"
             ""]))

(def ^:private nas-hosts-template
  "Required per-host share allowlist seeded for nas containers. A blank/all-
  commented file is DENY-ALL — nothing reachable over Samba/NFS until at least
  one active rule grants access. Uncomment one of the LAN/open examples to
  restore today's LAN-accessible-by-default behaviour."
  (str/join "\n"
            ["# NAS per-host share allowlist (Samba + NFS)."
             "#"
             "# REQUIRED FILE — a blank / all-commented file DENIES EVERY SHARE."
             "# Every access must be listed explicitly here. The nas_acl user gate"
             "# still applies on top; this is the network-layer gate underneath."
             "#"
             "# One line per HOST:   <host-token>  <share>..."
             "# A host may appear on at most one line — put all its shares together."
             "# Multiple hosts may list the same share; the share's allow list is"
             "# the union of every host that mentions it."
             "#"
             "# Host tokens:"
             "#   <cidr>      literal CIDR, e.g. 192.168.1.0/24 or 10.0.0.5/32"
             "#   0.0.0.0/0   any IPv4 address (fully open at the network layer)"
             "#   wg:<peer>   that wg peer's tunnel IP(s) (from wireguard.conf)"
             "#   wg:*        every wg peer currently in wireguard.conf"
             "#"
             "# Share tokens:"
             "#   <name>      a specific share name (a bind-mount basename under /srv)"
             "#   *           every share currently under /srv (expanded at emit time)"
             "#"
             "# Bare `*` is NOT accepted as a host — it is ambiguous between \"any"
             "# IP\" and \"every wg peer\". Use 0.0.0.0/0 or wg:* to disambiguate."
             "# The wg: tokens require the 'wireguard' profile to also be enabled"
             "# on this VM. Literal CIDRs and 0.0.0.0/0 work regardless."
             "#"
             "# Apply changes with:  just sync-identity <name>"
             "#"
             "# ── Quick-start: pick one of these to open things up ──"
             "#"
             "# Fully open (matches today's pre-nas_hosts behaviour, no restrictions):"
             "#   0.0.0.0/0         *"
             "#"
             "# LAN-accessible to every share (replace with your LAN CIDR):"
             "#   192.168.0.0/16    *"
             "#"
             "# ── Realistic per-host examples ──"
             "#"
             "#   wg:mike           mike-private family-shared mixed-share"
             "#   wg:sarah          family-shared"
             "#   wg:kids           family-shared"
             "#   wg:*              public-over-wg           # every wg peer"
             "#   192.168.1.0/24    media-store mixed-share public-over-wg"
             "#   192.168.1.10/32   backups                 # a single LAN host"
             "#   0.0.0.0/0         guest pubdocs           # world-readable shares"
             ""]))

(defn- generate-wg-keypair!
  "Generate a fresh WireGuard keypair via `nix run nixpkgs#wireguard-tools`.
  Returns {:private <base64> :public <base64>}."
  [cfg]
  (let [priv (proc/capture (concat (:nix cfg) ["run" "nixpkgs#wireguard-tools" "--" "genkey"]))
        pub  (proc/capture (concat (:nix cfg) ["run" "nixpkgs#wireguard-tools" "--" "pubkey"])
                           {:in priv})]
    {:private priv :public pub}))

(def ^:private mounts-template
  "Commented mounts seeded on LXC backends. All-commented = no bind mounts
  applied — apply-mounts iterates comment-stripped lines via port-lines."
  (str/join "\n"
            ["# LXC host bind mounts — one per line:  <host-spec>:<container-path>"
             "#"
             "# host-spec forms:"
             "#   /abs/host/path       literal PVE host directory (must exist)."
             "#                        Use this to bind-mount a subdirectory of a"
             "#                        dataset — the dataset forms below always"
             "#                        mount the WHOLE dataset."
             "#   <pool>/<dataset>     ZFS dataset (auto-`zfs create`d if missing;"
             "#                        parent must exist). Names are pool-relative:"
             "#                        e.g. `rust/backup` on a pool named `rust`,"
             "#                        or `rpool/data/nas` on a stock Proxmox layout."
             "#                        Nested datasets are separate filesystems, NOT"
             "#                        directories — use the literal-path form for"
             "#                        real subdirectories."
             "#   <pve-storage>/<sub>  A PVE `zfspool` storage entry (see /etc/pve/"
             "#                        storage.cfg). Resolved to its underlying ZFS"
             "#                        dataset, then treated as above. Useful on"
             "#                        stock Proxmox where storage `local-zfs` maps"
             "#                        to `rpool/data`; passing `local-zfs/nas`"
             "#                        expands to `rpool/data/nas`."
             "#"
             "# Applied by `pct set -mpN` at container-create time. `sync-identity`"
             "# does NOT re-apply changes — edits require `just recreate`, which"
             "# destroys the container rootfs. Back up /var/lib/traefik/acme.json"
             "# first if traefik is in use."
             "#"
             "# Examples:"
             "#   /tank/media:/srv/media                        literal host dir"
             "#   rust/backup:/srv/backup                       dataset on pool `rust`"
             "#   rpool/data/nas:/srv/nas                       dataset on stock PVE"
             "#   local-zfs/nas:/srv/nas                        via PVE storage entry"
             "#   /rust/backup/archive:/srv/archive             subdir of a dataset"
             "#   rust/traefik-nas:/var/lib/traefik             persist state through recreate"
             "#                                                 (traefik ACME certs, etc.)"
             ""]))

(def ^:private wg-users-template
  "Commented wg_users seeded when both wireguard and traefik profiles are
  selected. Consumed by the wg-auth service (wired in by the traefik profile)
  to inject an X-Remote-User header based on the wg-peer source IP."
  (str/join "\n"
            ["# wg_users — wireguard peer -> user identity mapping."
             "#"
             "# The wg-auth service (shipped by the traefik profile when wg is"
             "# enabled) reads this file and, for each incoming request whose"
             "# source IP matches a listed peer's AllowedIPs (looked up in"
             "# wireguard.conf), returns an X-Remote-User header for Traefik"
             "# to attach to the proxied request. Attach the wg-user or"
             "# wg-required middleware to a router in traefik/dynamic/*.yml"
             "# to opt that route into the injection."
             "#"
             "# Format: <wg-peer>  <user>"
             "#   wg-peer  a peer name (the `# hostname:` comment above a"
             "#            [Peer] block in wireguard.conf)."
             "#   user     a string echoed back as X-Remote-User. Downstream"
             "#            services decide what it means (e.g. copyparty's"
             "#            idp-h-usr matches it against its own accounts)."
             "#"
             "# Multiple wg peers (i.e. multiple devices) may map to the same"
             "# user — list one line per peer. Unlisted peers pass through"
             "# with no identity asserted (wg-user) or get 403 (wg-required)."
             "#"
             "# Apply changes with:  just sync-identity <name>"
             "#"
             "# Examples:"
             "#   laptop     alice"
             "#   phone      alice"
             "#   admin      alice"
             "#   guest-pc   bob"
             ""]))

(def ^:private wireguard-nft-template
  "Commented wireguard.nft seeded whenever the wireguard profile is selected.
  Two chains (wg-input, wg-forward) both default-drop until users add rules."
  (str/join "\n"
            ["# WireGuard peer ACL — nftables rules for wg0 traffic on this VM."
             "# Read at boot by the wireguard profile."
             "#"
             "# Two chains govern wg0 traffic:"
             "#"
             "#   wg-input   — traffic from wg0 hitting THIS peer's own services."
             "#                Applies to every peer (including hubs). Because wg0"
             "#                is in networking.firewall.trustedInterfaces, this"
             "#                chain is the SOLE authority for wg-side port access;"
             "#                tcp_ports / udp_ports do not apply to wg traffic."
             "#"
             "#   wg-forward — traffic passing between wg peers through this peer."
             "#                Only meaningful when this peer acts as a hub — leave"
             "#                the chain empty (drop only) on spokes."
             "#"
             "#   wg-prerouting (optional) — NAT prerouting for wg0 traffic."
             "#                Use for `redirect to :PORT` or `dnat to ADDR:PORT`."
             "#                Only installed if this chain is present; unmatched"
             "#                packets fall through unchanged (no default deny)."
             "#"
             "# Peer names come from `# hostname: <name>` comments in this VM's"
             "# wireguard.conf and are exposed as $name below. Bare CIDRs work too."
             "# Reply traffic is handled by conntrack; you only describe *new*"
             "# connections you want to permit. Both chains end with `drop`."
             "#"
             "# Group peers with an anonymous set  { $a, $b }  inline, or with a"
             "# named `set` block at the top of this file referenced as @name."
             "# wg-input is already scoped to iifname wg0 (and wg validates source"
             "# addresses), so a rule with no ip saddr matches every wg peer."
             "#"
             "# Apply changes with:  just upgrade <name>   (or  just sync-identity"
             "# <name> + `sudo systemctl restart wireguard-nft` inside the guest)."
             "#"
             "# Default is deny-everything: if this file is missing (or a chain"
             "# body is missing here), the service synthesizes a drop-only chain"
             "# for that direction. Delete a chain to lock wg0 down completely"
             "# for that direction."
             ""
             "# ── Named set example: define once at the top of this file, then"
             "# reference as @trusted in any chain below."
             "# set trusted {"
             "#   type ipv4_addr"
             "#   elements = { $laptop, $phone }"
             "# }"
             ""
             "chain wg-input {"
             "  # Reply traffic — do not remove:"
             "  ct state established,related accept"
             ""
             "  # Note: ICMP echo-request (ping) is accepted unconditionally by"
             "  # the hook chain BEFORE this chain sees it, so there's no need"
             "  # to allow ping here."
             ""
             "  # ── Examples: allow specific wg peers to reach services on THIS VM"
             "  # ip saddr $laptop tcp dport 22   accept   # SSH from laptop"
             "  # ip saddr $laptop tcp dport 443  accept   # HTTPS from laptop"
             "  # ip saddr $laptop tcp dport 445  accept   # Samba from laptop"
             "  # ip saddr $laptop tcp dport 3923 accept   # copyparty (web + WebDAV)"
             "  # ip saddr $phone  tcp dport 445  accept   # Samba from phone"
             "  # ip saddr $admin                 accept   # admin peer: full access"
             ""
             "  # ── Grouped examples"
             "  # tcp dport 445 accept                                 # any wg peer -> Samba"
             "  # ip saddr { $laptop, $phone } tcp dport 445 accept    # anonymous set"
             "  # ip saddr @trusted tcp dport { 22, 443, 3923 } accept # named set (see top of file)"
             ""
             "  # Default deny — keep as the last rule:"
             "  drop"
             "}"
             ""
             "chain wg-forward {"
             "  # Reply traffic — do not remove:"
             "  ct state established,related accept"
             ""
             "  # ── Ping between peers through this hub"
             "  # ip saddr $laptop ip daddr $homeassistant icmp   type echo-request accept"
             "  # ip saddr $laptop ip daddr $homeassistant icmpv6 type echo-request accept"
             ""
             "  # ── Per-peer, per-service forwarding (spoke -> spoke via this hub)"
             "  # ip saddr $laptop ip daddr $homeassistant tcp dport 22  accept   # laptop SSH to homeassistant"
             "  # ip saddr $phone  ip daddr $homeassistant tcp dport 443 accept   # phone HTTPS to homeassistant"
             "  # ip saddr $laptop ip daddr $phone         tcp dport 22  accept   # laptop SSH to phone"
             ""
             "  # ── One peer allowed to reach everything on wg0 through this hub"
             "  # ip saddr $admin accept"
             ""
             "  # ── Unrestricted spoke-to-spoke (uncomment to disable the ACL)"
             "  # accept"
             ""
             "  drop"
             "}"
             ""
             "# ── Optional NAT prerouting for wg0 (uncomment to enable) ───────────────"
             "# Redirect / dnat rules for traffic arriving on wg0. Filter rules must"
             "# still allow the POST-rewrite dport in wg-input (or wg-forward)."
             "#"
             "# chain wg-prerouting {"
             "#   # Redirect port 443 to a local service on 3923:"
             "#   ip saddr @trusted tcp dport 443 redirect to :3923"
             "#"
             "#   # DNAT to another host on the wg network:"
             "#   # ip saddr $laptop tcp dport 8080 dnat to $homeassistant:80"
             "# }"
             ""]))

(defn- wireguard-template
  "wg-quick config seeded on first create when the wireguard profile is
  selected. The private key stays pinned in this file, so recreate/upgrade
  reuse the same VPN identity (the file is copied verbatim from
  machines/<name>/wireguard.conf)."
  [name {:keys [private public]}]
  (str/join "\n"
            [(format "# WireGuard config for VM '%s' (interface wg0)." name)
             "# Read at boot by wg-quick from /var/identity/wireguard.conf."
             "# Standard wg-quick format: one [Interface] + any number of [Peer] sections."
             "#"
             (format "# Apply changes with:  just sync-identity %s   (or  just upgrade %s)" name name)
             "# If you set ListenPort, also add the UDP port to udp_ports (WireGuard is UDP-only)."
             "#"
             (format "# Public key (share with peers): %s" public)
             "#"
             "# The `# hostname: <name>` comments below are used by the"
             "# wireguard profile to resolve names in wireguard.nft rules."
             ""
             "[Interface]"
             (format "# hostname: %s" name)
             (format "PrivateKey = %s" private)
             "# Address can be specified multiple times:"
             "Address    = 10.0.0.2/24"
             "# Address  = fd00:0:0::2/64"
             "ListenPort = 51820"
             "# DNS = 10.0.0.1                     # push DNS through the tunnel"
             "# MTU = 1420                         # lower (1280/1380) if the path drops large packets"
             ""
             "# [Peer]"
             "# hostname: <peer-name>"
             "# PublicKey    = <peer-public-key>"
             "# PresharedKey = <optional PSK — `wg genpsk` — extra hardening on top of the keypair>"
             "# Endpoint     = hub.example.com:51820"
             "# AllowedIPs can be specified multiple times."
             "# Set to `0.0.0.0/0, ::/0` on a spoke's [Peer] to full-tunnel through it."
             "# AllowedIPs = 10.0.0.0/24"
             "# AllowedIPs = fd00:0:0::/64"
             "# PersistentKeepalive = 25           # send a keepalive every N sec when this peer is behind NAT"
             ""]))

(defn- traefik-yml-template
  "Static Traefik config seeded on first create when the traefik profile is
  selected. `mutable?` decides which on-VM path the file-provider references."
  [name mutable?]
  (let [cfg-dir (if mutable? "/etc/traefik" "/var/identity/traefik")
        dyn-dir (str cfg-dir "/dynamic")]
    (str/join "\n"
              [(format "# Traefik static config for VM '%s'." name)
               (format "# Read at boot by services.traefik from %s/traefik.yml" cfg-dir)
               "#"
               (format "# Apply changes with:  just sync-identity %s" name)
               "# then (inside the VM):    sudo systemctl restart traefik"
               "#"
               "# Files in dynamic/*.yml are hot-reloaded by Traefik itself."
               "#"
               "# Docs: https://doc.traefik.io/traefik/reference/install-configuration/introduction/"
               ""
               "global:"
               "  checkNewVersion: false"
               "  sendAnonymousUsage: false"
               ""
               "log:"
               "  level: INFO"
               ""
               "# ── Entry points ────────────────────────────────────────────────────────────"
               "# Bind on all interfaces:   address: \":80\""
               "# Bind on a wireguard IP:   address: \"10.0.0.1:80\""
               "# (net.ipv4.ip_nonlocal_bind=1 is set by the profile so binding an address"
               "# that isn't up yet at boot still succeeds.)"
               "# `http.aliasHeadersStrategy: delete` strips headers whose names alias a"
               "# canonical header (e.g. X_Auth_User → X-Auth-User) before routing, so a"
               "# client cannot spoof headers Traefik manages. Valid: keep|delete|reject."
               "entryPoints:"
               "  web:"
               "    address: \":80\""
               "    http:"
               "      aliasHeadersStrategy: delete"
               "  websecure:"
               "    address: \":443\""
               "    http:"
               "      aliasHeadersStrategy: delete"
               "    # Disable the 60s default readTimeout so long-running uploads"
               "    # (e.g. large files via copyparty/WebDAV) aren't cut off."
               "    transport:"
               "      respondingTimeouts:"
               "        readTimeout: \"0s\""
               ""
               "# ── Providers ───────────────────────────────────────────────────────────────"
               "providers:"
               "  file:"
               (format "    directory: %s" dyn-dir)
               "    watch: true"
               ""
               "# ── Dashboard (uncomment to enable) ─────────────────────────────────────────"
               "# api:"
               "#   dashboard: true"
               "#   insecure: false"
               "#"
               "# Then expose it via a router in dynamic/, e.g.:"
               "#   http:"
               "#     routers:"
               "#       dashboard:"
               "#         rule: \"Host(`traefik.example.local`)\""
               "#         service: api@internal"
               "#         entryPoints: [web]"
               ""
               "# ── Wireguard peer → user injection (wg-auth) ───────────────────────────────"
               "# When the wireguard profile is also enabled, the traefik profile ships"
               "# two forward-auth middlewares (defined in the generated"
               "# dynamic/wg-users.yml — do not hand-edit that file):"
               "#"
               "#   wg-user      Attach X-Remote-User to the proxied request when the"
               "#                source IP matches a wg peer listed in machines/<name>/wg_users."
               "#                Unmapped peers pass through with no identity asserted."
               "#   wg-required  Same, but return 403 for unmapped peers (peers-only site)."
               "#"
               "# Both fail closed if the map is unavailable or the auth service is down."
               "# Attach either to a router in dynamic/*.yml, e.g.:"
               "#   http:"
               "#     routers:"
               "#       copyparty:"
               "#         rule: \"Host(`copyparty.nas.example.com`)\""
               "#         entryPoints: [websecure]"
               "#         middlewares: [wg-user]"
               "#         service: copyparty"
               "#"
               "# ── ACME / Let's Encrypt via acme-dns (uncomment + edit) ────────────────────"
               "# Uses Traefik's built-in ACME client with the acme-dns DNS-01 provider."
               "# Preconditions:"
               "#   1. Populate acme-dns.env with ACME_DNS_API_BASE + register each domain:"
               (format "#        just acme-register %s <domain>" name)
               "#   2. Publish the CNAME record the helper prints (per domain)."
               "#   3. Uncomment this block and set `email:`."
               "# Certs are renewed automatically; no VM restart needed."
               "# certificatesResolvers:"
               "#   letsencrypt:"
               "#     acme:"
               "#       email: you@example.com"
               "#       storage: /var/lib/traefik/acme.json"
               "#       dnsChallenge:"
               "#         provider: acmedns"
               ""])))

(defn- acme-dns-env-template
  "Seed for machines/<name>/acme-dns.env: a systemd EnvironmentFile that
  Traefik's built-in ACME client reads for the acme-dns DNS-01 provider.
  The storage path is constant across modes because a boot-time helper
  copies acme-dns.json into traefik's writable state dir; sync-identity
  drops the workstation copy at /etc or /var/identity."
  [_mutable?]
  (str/join "\n"
            ["# acme-dns provider config for Traefik's built-in ACME client (dnsChallenge)."
             "#"
             "# ACME_DNS_API_BASE is written on the first run of:"
             "#   just acme-register <vm> <domain>"
             "# which also POSTs to the acme-dns server, appends per-domain credentials to"
             "# acme-dns.json, and prints the CNAME record to publish."
             "#"
             "# systemd loads this via EnvironmentFile=- on traefik.service, so an absent"
             "# ACME_DNS_API_BASE just leaves the ACME resolver disabled at boot; lego is"
             "# only initialized once a router in dynamic/*.yml references a certResolver."
             "#"
             "# ACME_DNS_STORAGE_PATH points at traefik's state dir (not the on-disk"
             "# workstation copy): lego needs write access to save challenge state, and"
             "# services.traefik runs with ProtectSystem=strict so /etc is read-only."
             "# A oneshot in the traefik profile copies /etc/acme-dns.json (or"
             "# /var/identity/acme-dns.json) into /var/lib/traefik/acme-dns.json with"
             "# traefik ownership before the service starts."
             ""
             "# ACME_DNS_API_BASE=https://acme-dns.example.com:2890"
             "ACME_DNS_STORAGE_PATH=/var/lib/traefik/acme-dns.json"
             ""]))

(def ^:private traefik-dynamic-example
  "Placeholder dynamic-config example seeded alongside traefik.yml. Named with a
  .disabled suffix so Traefik's file provider ignores it until the user renames."
  (str/join "\n"
            ["# Example dynamic Traefik config. Rename this file (drop the .disabled"
             "# suffix) or add other *.yml files in this directory to define routers,"
             "# services, and middlewares. Traefik hot-reloads changes."
             "#"
             "# The example below fronts copyparty (from the `nas` profile) on port"
             "# 3923. copyparty terminates TLS with a self-signed cert, so the"
             "# loadBalancer talks HTTPS to 127.0.0.1:3923 via a serversTransport"
             "# with insecureSkipVerify (upstream is loopback; client-to-traefik TLS"
             "# is the trust boundary that matters). The router publishes on the"
             "# `websecure` entry point with the `letsencrypt` certresolver and"
             "# pins the cert to the wildcard `*.nas.example.com` via `tls.domains`"
             "# — precondition: `just acme-register <vm> '*.nas.example.com'`,"
             "# publish the CNAME the helper prints, and uncomment the ACME block"
             "# in ../traefik.yml. Adjust the Host rule + wildcard to match a name"
             "# that resolves to this VM."
             "#"
             "# Docs: https://doc.traefik.io/traefik/reference/dynamic-configuration/file/"
             ""
             "# http:"
             "#   routers:"
             "#     copyparty:"
             "#       rule: \"Host(`copyparty.nas.example.com`)\""
             "#       entryPoints: [websecure]"
             "#       # Optional: with the wireguard profile also enabled, attach"
             "#       # wg-user to auto-authenticate mapped wg peers as their user"
             "#       # (or wg-required for a peers-only site). See wg_users."
             "#       # middlewares: [wg-user]"
             "#       service: copyparty"
             "#       tls:"
             "#         certResolver: letsencrypt"
             "#         domains:"
             "#           - main: \"*.nas.example.com\""
             "#   services:"
             "#     copyparty:"
             "#       loadBalancer:"
             "#         serversTransport: copyparty-selfsigned"
             "#         servers:"
             "#           - url: \"https://127.0.0.1:3923\""
             "#   serversTransports:"
             "#     copyparty-selfsigned:"
             "#       insecureSkipVerify: true"
             ""]))

(defn- write-authorized-keys!
  "Port of init_machine's per-account authorized_keys handling. `account` is
  \"admin\" or \"user\"; `header-lines` are the comment header; `preset` are
  explicit keys (newline-separated) or nil."
  [cfg name account header-lines ssh-key-mode preset]
  (let [path (field-path cfg name (str account "_authorized_keys"))
        needed? (or (not (fs/exists? path)) (zero? (key-count path)))
        admin? (= account "admin")]
    (when needed?
      (spit path (str (str/join "\n" header-lines) "\n"))
      (cond
        (not (str/blank? preset))
        (do (spit path (str preset "\n") :append true)
            (println (format "Saved: %s" path)))

        (= ssh-key-mode "agent")
        (let [r (proc/capture-result ["ssh-add" "-L"])]
          (if (zero? (:exit r))
            (do (spit path (:out r) :append true)
                (println (format "Saved: %s (from SSH agent)" path)))
            (if admin?
              (do (println "Error: No SSH agent keys found. Start ssh-agent and add a key first:")
                  (println "  eval $(ssh-agent) && ssh-add")
                  (System/exit 1))
              (println "Warning: No keys in SSH agent, user SSH login will be disabled"))))

        (= ssh-key-mode "skip")
        (println (format "No %s authorized_keys configured (%s SSH login will be disabled)"
                         account account))

        :else
        (let [label (if admin? "'admin' (has sudo access)" "'user' (no sudo access)")]
          (println)
          (println (format "Enter SSH public key(s) for %s:" label))
          (println "(Paste key, then press Enter, then Ctrl+D. Leave empty and press Ctrl+D to skip)")
          (spit path (str (slurp *in*)) :append true)
          (if (pos? (key-count path))
            (println (format "Saved: %s" path))
            (println (format "No %s authorized_keys configured (%s SSH login will be disabled)"
                             account account))))))))

(defn- seed-ssh-host-key-templates!
  "Drop `#`-comment-only ssh_host_ed25519_key(.pub) templates in the machine
  dir. Users populate them BEFORE `just create` / `just recreate` to pin a
  stable host key; sync-identity / upgrade / clone leave the VM's key alone
  (and warn if a real key is sitting here unused)."
  [md name]
  (when-not (fs/exists? (str md "/ssh_host_ed25519_key"))
    (spit (str md "/ssh_host_ed25519_key")
          (str/join "\n"
                    [(format "# ed25519 SSH host private key for VM '%s'." name)
                     "# Populate BEFORE 'just create'/'just recreate' to pin the host key."
                     "# Absent (or `#`-comment-only) -> openssh regenerates on first boot."
                     "# Generate with:"
                     (format "#   ssh-keygen -t ed25519 -N '' -f %s/ssh_host_ed25519_key" md)
                     "# `#` comment and blank lines are stripped when installed."
                     ""]))
    (fs/set-posix-file-permissions (str md "/ssh_host_ed25519_key") "rw-------")
    (println (format "Created: %s/ssh_host_ed25519_key (template - openssh will regen if left as-is)" md)))
  (when-not (fs/exists? (str md "/ssh_host_ed25519_key.pub"))
    (spit (str md "/ssh_host_ed25519_key.pub")
          (str/join "\n"
                    [(format "# ed25519 SSH host public key for VM '%s' (companion to the private key)." name)
                     "# Optional: openssh can derive the public key from the private, so shipping"
                     "# this is only useful for out-of-band verification."
                     ""]))
    (println (format "Created: %s/ssh_host_ed25519_key.pub (template)" md))))

(defn init-machine
  "Initialize a machine config directory, creating identity files if absent.
  opts: :profile :network :ssh-key-mode (\"agent\"|\"skip\"|nil) :admin-keys :user-keys."
  [cfg name {:keys [profile network ssh-key-mode admin-keys user-keys]
             :or {profile "core" network "nat"}}]
  (let [md (machine-dir cfg name)
        normalized (profile/normalize-profiles profile)]
    (profile/ensure-no-exclusive-conflicts! normalized)
    (fs/create-dirs md)
    ;; profile
    (cond
      (not (fs/exists? (str md "/profile")))
      (do (spit (str md "/profile") (str normalized "\n"))
          (println (format "Created: %s/profile (%s)" md normalized)))
      (not= profile "core")
      (do (spit (str md "/profile") (str normalized "\n"))
          (println (format "Updated: %s/profile (%s)" md normalized)))
      :else
      (println (format "Using existing profile: %s" (read-field cfg name "profile"))))
    ;; network
    (cond
      (not (fs/exists? (str md "/network"))) (net/network-config cfg name network)
      (not= network "nat") (net/network-config cfg name network)
      :else (println (format "Using existing network config: %s" (read-field cfg name "network"))))
    ;; hosts
    (when-not (fs/exists? (str md "/hosts"))
      (spit (str md "/hosts")
            (str/join "\n" ["# Extra /etc/hosts entries (one per line)"
                            "# Example:" "# 10.0.0.1 myserver.local myserver" ""]))
      (println (format "Created: %s/hosts" md)))
    ;; root password hash
    (when-not (fs/exists? (str md "/root_password_hash"))
      (spit (str md "/root_password_hash") "")
      (fs/set-posix-file-permissions (str md "/root_password_hash") "rw-------")
      (println (format "Created: %s/root_password_hash (empty - no root password)" md)))
    ;; machine-id
    (when-not (fs/exists? (str md "/machine-id"))
      (spit (str md "/machine-id") (str (new-machine-id) "\n"))
      (println (format "Generated: %s/machine-id" md)))
    ;; mac-address
    (when-not (fs/exists? (str md "/mac-address"))
      (let [mac (new-mac)]
        (spit (str md "/mac-address") (str mac "\n"))
        (println (format "Generated: %s/mac-address (%s)" md mac))))
    ;; uuid
    (when-not (fs/exists? (str md "/uuid"))
      (spit (str md "/uuid") (str (new-uuid) "\n"))
      (println (format "Generated: %s/uuid" md)))
    ;; hostname
    (when-not (fs/exists? (str md "/hostname"))
      (spit (str md "/hostname") (str name "\n"))
      (println (format "Created: %s/hostname" md)))
    ;; authorized_keys
    (write-authorized-keys! cfg name "admin"
                            ["# SSH authorized_keys for 'admin' user (has sudo access)"
                             (format "# Add one public key per line. Run 'just upgrade %s' to apply changes." name)
                             ""]
                            ssh-key-mode admin-keys)
    (write-authorized-keys! cfg name "user"
                            ["# SSH authorized_keys for 'user' account (no sudo access)"
                             (format "# Add one public key per line. Run 'just upgrade %s' to apply changes." name)
                             ""]
                            ssh-key-mode user-keys)
    ;; SSH host key templates (populate BEFORE create/recreate to pin the key)
    (seed-ssh-host-key-templates! md name)
    ;; tcp_ports — seeded once at creation; the nas / moonshine-nvidia /
    ;; sunshine-plasma-nvidia profiles add their service ports here (not in the
    ;; image) so they stay visible/editable. Remove any you don't want exposed.
    (let [profs (set (map str/trim (str/split (or profile "") #",")))
          nas? (contains? profs "nas")
          samba-mount? (contains? profs "samba-mount")
          wireguard? (contains? profs "wireguard")
          traefik? (contains? profs "traefik")
          lxc? (= (:backend cfg) "proxmox-lxc")
          ;; True when the target's rootfs is writable (either the `mutable`
          ;; profile is enabled on KVM, or the backend is proxmox-lxc which is
          ;; mutable-only). Drives per-mode paths in seeded templates.
          mutable? (or (contains? profs "mutable") lxc?)
          moonshine? (contains? profs "moonshine-nvidia")
          sunshine? (contains? profs "sunshine-plasma-nvidia")
          ;; Both Moonlight-protocol servers use the same well-known ports and
          ;; both need Proxmox GPU passthrough. Exclusivity is enforced upstream
          ;; in profile.clj, so at most one of these is ever true.
          streaming? (or moonshine? sunshine?)
          streaming-label (cond moonshine? "moonshine" sunshine? "sunshine" :else "")]
      (when-not (fs/exists? (str md "/tcp_ports"))
        (spit (str md "/tcp_ports")
              (str/join "\n" (concat ["# TCP ports to open in firewall (one per line)"
                                      (format "# Run 'just upgrade %s' to apply changes." name)
                                      "22" "80" "443"]
                                     (when nas?
                                       ["# nas profile — SMB (445), NFSv4 (2049), WSD (5357):"
                                        "# copyparty listens on loopback only; HTTP/WebDAV goes via traefik."
                                        "445" "2049" "5357"])
                                     (when streaming?
                                       [(format "# %s — Moonlight HTTPS (47984), HTTP (47989), RTSP (48010):"
                                                streaming-label)
                                        "47984" "47989" "48010"])
                                     [""])))
        (println (format "Created: %s/tcp_ports%s" md
                         (str/join "" [(when nas? " + nas")
                                       (when streaming? (str " + " streaming-label))]))))
      ;; udp_ports
      (when-not (fs/exists? (str md "/udp_ports"))
        (spit (str md "/udp_ports")
              (str/join "\n" (concat ["# UDP ports to open in firewall (one per line)"
                                      (format "# Run 'just upgrade %s' to apply changes." name)]
                                     (when nas?
                                       ["# nas profile — mDNS (5353), WS-Discovery (3702):"
                                        "5353" "3702"])
                                     (when streaming?
                                       [(format "# %s — Moonlight video (47998), control (47999), audio (48000):"
                                                streaming-label)
                                        "47998" "47999" "48000"])
                                     (when wireguard?
                                       ["# wireguard profile — default ListenPort:"
                                        "51820"])
                                     [""])))
        (println (format "Created: %s/udp_ports%s" md
                         (str/join "" [(when nas? " (nas)")
                                       (when streaming? (str " (" streaming-label ")"))
                                       (when wireguard? " (wireguard)")]))))
      ;; pci_devices — seeded for the streaming profiles (Proxmox GPU passthrough).
      ;; Users can also add this file for any Proxmox VM to pass through PCI
      ;; devices without a streaming profile.
      (when (and streaming? (not (fs/exists? (str md "/pci_devices"))))
        (spit (str md "/pci_devices")
              (str/join "\n" ["# Proxmox PCI passthrough — one --hostpciN entry per line."
                              "# See `man qm` for the full hostpci syntax."
                              "#"
                              "# Common forms:"
                              "#   0000:01:00.0"
                              "#   0000:01:00,pcie=1,x-vga=1"
                              "#"
                              "# For NVIDIA GPUs, pass BOTH the VGA function (00.0) AND the audio"
                              "# function (00.1) so HDMI audio works. `just create` should have"
                              "# offered a picker; edit here and run `just upgrade` to change."
                              ""]))
        (println (format "Created: %s/pci_devices (edit to pass PCI devices through)" md)))
      ;; samba-mount — seed commented placeholders so users can discover the
      ;; identity files without reading the profile source. All-commented = no
      ;; mounts (the mount generator skips missing/empty credentials).
      (when samba-mount?
        (when-not (fs/exists? (str md "/samba_credentials"))
          (spit (str md "/samba_credentials") samba-credentials-template)
          (fs/set-posix-file-permissions (str md "/samba_credentials") "rw-------")
          (println (format "Created: %s/samba_credentials (edit to add mount.cifs credentials)" md)))
        (when-not (fs/exists? (str md "/samba_client_shares"))
          (spit (str md "/samba_client_shares") samba-client-shares-template)
          (println (format "Created: %s/samba_client_shares (edit to add CIFS mounts)" md))))
      ;; nas — seed commented Samba users + ACL + host allowlist. All-commented
      ;; nas_hosts is deny-all; users edit it to grant access. nas_passwd is
      ;; optional (empty file works — a user simply can't authenticate).
      (when nas?
        (when-not (fs/exists? (str md "/nas_passwd"))
          (spit (str md "/nas_passwd") nas-passwd-template)
          (fs/set-posix-file-permissions (str md "/nas_passwd") "rw-------")
          (println (format "Created: %s/nas_passwd (NAS users — edit to add credentials)" md)))
        (when-not (fs/exists? (str md "/nas_acl"))
          (spit (str md "/nas_acl") nas-acl-template)
          (println (format "Created: %s/nas_acl (NAS ACL — edit to grant per-user access)" md)))
        (when-not (fs/exists? (str md "/nas_hosts"))
          (spit (str md "/nas_hosts") nas-hosts-template)
          (println (format "Created: %s/nas_hosts (REQUIRED — blank file denies every share; uncomment examples to open access)" md))))
      ;; wireguard — generate a keypair once and pin it in wireguard.conf.
      ;; Preserved across recreate/upgrade because the file lives here and is
      ;; copied verbatim to /var/identity by identity sync.
      (when (and wireguard? (not (fs/exists? (str md "/wireguard.conf"))))
        (println (format "Generating WireGuard keypair for %s..." name))
        (let [kp (generate-wg-keypair! cfg)
              path (str md "/wireguard.conf")]
          (spit path (wireguard-template name kp))
          (fs/set-posix-file-permissions path "rw-------")
          (println (format "Created: %s/wireguard.conf (public key: %s)" md (:public kp)))))
      ;; wireguard.nft — peer ACL template (wg-input + wg-forward chains,
      ;; both default-drop until the user uncomments allow rules). Seeded
      ;; alongside wireguard.conf; users can still add or delete the file
      ;; later by hand.
      (when (and wireguard? (not (fs/exists? (str md "/wireguard.nft"))))
        (spit (str md "/wireguard.nft") wireguard-nft-template)
        (println (format "Created: %s/wireguard.nft (all-commented — edit to allow wg traffic)" md)))
      ;; mounts — LXC host bind mounts. All-commented on first create;
      ;; the wizard overwrites this file when the user picks datasets, and
      ;; preserves it when they don't (see wizard-lxc-mounts's blank branch).
      (when (and lxc? (not (fs/exists? (str md "/mounts"))))
        (spit (str md "/mounts") mounts-template)
        (println (format "Created: %s/mounts (all-commented — edit to add host bind mounts)" md)))
      ;; wg_users — traefik + wireguard together: seed the peer→user map
      ;; consumed by the wg-auth service. All-commented = no auto-login.
      (when (and traefik? wireguard? (not (fs/exists? (str md "/wg_users"))))
        (spit (str md "/wg_users") wg-users-template)
        (println (format "Created: %s/wg_users (all-commented — edit to auto-authenticate wg peers)" md)))
      ;; traefik — seed static config + empty dynamic dir with a disabled example.
      ;; Static file path in the seed depends on mutable mode (immutable ->
      ;; /var/identity/traefik/dynamic; mutable -> /etc/traefik/dynamic). Switching
      ;; modes later means editing the providers.file.directory line.
      (when traefik?
        (let [tdir (str md "/traefik")
              ydir (str tdir "/dynamic")]
          (fs/create-dirs ydir)
          (when-not (fs/exists? (str tdir "/traefik.yml"))
            (spit (str tdir "/traefik.yml") (traefik-yml-template name mutable?))
            (println (format "Created: %s/traefik.yml (edit to configure Traefik)" tdir)))
          (when-not (fs/exists? (str ydir "/example.yml.disabled"))
            (spit (str ydir "/example.yml.disabled") traefik-dynamic-example)
            (println (format "Created: %s/example.yml.disabled (rename to *.yml to activate)" ydir))))
        ;; acme-dns.env — seeded alongside traefik so `just acme-register` has a
        ;; file to append ACME_DNS_API_BASE to. acme-dns.json is created lazily
        ;; by the helper on first successful /register response.
        (when-not (fs/exists? (str md "/acme-dns.env"))
          (spit (str md "/acme-dns.env") (acme-dns-env-template mutable?))
          (fs/set-posix-file-permissions (str md "/acme-dns.env") "rw-------")
          (println (format "Created: %s/acme-dns.env (populate via `just acme-register`)" md)))))
    ;; resolv.conf
    (when-not (fs/exists? (str md "/resolv.conf"))
      (spit (str md "/resolv.conf")
            (str/join "\n" [(format "# DNS configuration. Run 'just upgrade %s' to apply changes." name)
                            "nameserver 1.1.1.1" "nameserver 1.0.0.1" ""]))
      (println (format "Created: %s/resolv.conf (Cloudflare DNS)" md)))
    (println (format "Machine config ready: %s/" md))))

(defn init-machine-clone
  "Initialize a clone's machine config: copy config from source, fresh identity."
  [cfg source dest network]
  (let [src (machine-dir cfg source)
        dst (machine-dir cfg dest)]
    (fs/create-dirs dst)
    (doseq [f ["admin_authorized_keys" "user_authorized_keys" "tcp_ports" "udp_ports"
               "resolv.conf" "hosts" "root_password_hash" "profile"]]
      (when (fs/exists? (str src "/" f))
        (fs/copy (str src "/" f) (str dst "/" f) {:replace-existing true})))
    ;; network: override or copy from source
    (cond
      (not (str/blank? network))
      (if (and (= network "bridge") (fs/exists? (str src "/network")))
        (let [snet (str/trim (slurp (str src "/network")))]
          (spit (str dst "/network") (str (if (str/starts-with? snet "bridge:") snet "bridge:br0") "\n")))
        (spit (str dst "/network") (str network "\n")))
      (fs/exists? (str src "/network"))
      (fs/copy (str src "/network") (str dst "/network") {:replace-existing true})
      :else
      (spit (str dst "/network") "nat\n"))
    ;; fresh identity
    (spit (str dst "/machine-id") (str (new-machine-id) "\n"))
    (println (format "Generated: %s/machine-id" dst))
    (let [mac (new-mac)]
      (spit (str dst "/mac-address") (str mac "\n"))
      (println (format "Generated: %s/mac-address (%s)" dst mac)))
    (spit (str dst "/uuid") (str (new-uuid) "\n"))
    (println (format "Generated: %s/uuid" dst))
    (spit (str dst "/hostname") (str dest "\n"))
    (println (format "Created: %s/hostname" dst))
    (when (fs/exists? (str dst "/root_password_hash"))
      (fs/set-posix-file-permissions (str dst "/root_password_hash") "rw-------"))
    (seed-ssh-host-key-templates! dst dest)
    (println (format "Machine config ready: %s/ (cloned from %s)" dst source))))

(defn- save-resource!
  "Write a resource file (memory/vcpus/var_size) with the Created/Updated/Using
  messages and default-aware overwrite, matching config_vm. Returns the value."
  [cfg name field value default unit-fmt]
  (let [md (machine-dir cfg name)
        path (str md "/" field)]
    (cond
      (not (fs/exists? path))
      (do (spit path (str value "\n"))
          (println (format "Created: %s/%s (%s)" md field (unit-fmt value)))
          value)
      (not= value default)
      (do (spit path (str value "\n"))
          (println (format "Updated: %s/%s (%s)" md field (unit-fmt value)))
          value)
      :else
      (let [existing (read-field cfg name field)]
        (println (format "Using existing %s: %s" field (unit-fmt existing)))
        existing))))

(defn write-static-ip!
  "Write static_ip from an \"address,gateway\" string (gateway optional)."
  [cfg name static-ip]
  (let [md (machine-dir cfg name)
        [addr gw] (str/split static-ip #"," 2)]
    (spit (str md "/static_ip")
          (str "address=" addr "\n"
               (when-not (str/blank? gw) (str "gateway=" gw "\n"))))
    (println (format "Created: %s/static_ip (%s)" md addr))))

(defn config-vm
  "Non-interactive VM configuration (machine config only, no VM created)."
  [cfg name {:keys [profile memory vcpus var-size network static-ip]
             :or {profile "core" memory "2048" vcpus "2" var-size "30G" network "nat"}}]
  (let [var-size (normalize-size var-size)]
    (init-machine cfg name {:profile profile :network network :ssh-key-mode "agent"})
    (let [memory (save-resource! cfg name "memory" memory "2048" #(str % "M"))
          vcpus (save-resource! cfg name "vcpus" vcpus "2" str)
          var-size (save-resource! cfg name "disk_size" var-size "30G" str)]
      (when-not (str/blank? static-ip)
        (write-static-ip! cfg name static-ip))
      (println)
      (println (format "VM '%s' configured (profile: %s, memory: %sM, vcpus: %s, var: %s)"
                       name (read-field cfg name "profile") memory vcpus var-size))
      (println (format "To create the VM, run: just create %s" name)))))

(defn seed-config
  "Fill in any missing per-VM config files under machines/<name>/ based on
  the VM's *current* profile. Reads machines/<name>/profile from disk and
  re-runs init-machine, which is idempotent for files that already exist —
  only genuinely missing templates (e.g. wireguard.nft on a VM that
  predates the peer-ACL feature) get created. Non-interactive: SSH-key
  prompts are skipped, so run `just config <name>` if authorized_keys is
  missing and needs populating."
  [cfg name]
  (when-not (exists? cfg name)
    (println (format "Error: machine '%s' does not exist under %s/" name (:machines-dir cfg)))
    (System/exit 1))
  (let [profile (or (read-field cfg name "profile") "core")]
    (println (format "Seeding missing config files for '%s' (profile: %s)..." name profile))
    (init-machine cfg name {:profile profile :ssh-key-mode "skip"})))

(defn set-profile
  "Set the profile(s) for an existing VM (the `just profile` recipe). `profiles`
  is a comma-separated string."
  [cfg name profiles]
  (when-not (exists? cfg name)
    (println (format "Error: Machine '%s' does not exist" name))
    (System/exit 1))
  (spit (str (machine-dir cfg name) "/profile") (str profiles "\n"))
  (println (format "Set profile for %s: %s" name profiles))
  (println (format "Run 'just upgrade %s' to apply the new profile." name)))

(defn set-password
  "Set or clear the root password hash for a VM (interactive prompt)."
  [cfg name]
  (let [md (machine-dir cfg name)]
    (when-not (fs/directory? md)
      (println (format "Error: Machine config not found: %s" md))
      (System/exit 1))
    (println (format "Set root password for VM '%s'" name))
    (println "(leave blank to disable root password)")
    (let [password (prompt/read-password "Password: ")]
      (if (str/blank? password)
        (do (spit (str md "/root_password_hash") "")
            (println "Root password disabled."))
        (let [confirm (prompt/read-password "Confirm: ")]
          (when (not= password confirm)
            (println "Error: passwords do not match.")
            (System/exit 1))
          (let [hash (str/trim (:out (proc/capture-result
                                      (concat (:nix cfg) ["run" "nixpkgs#mkpasswd" "--"
                                                          "-m" "sha-512" "--stdin"])
                                      {:in password :out :string})))]
            (spit (str md "/root_password_hash") hash)
            (println "Root password hash saved."))))
      (fs/set-posix-file-permissions (str md "/root_password_hash") "rw-------")
      (println (format "Run 'just upgrade %s' to apply." name)))))
