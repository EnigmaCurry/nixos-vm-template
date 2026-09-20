(ns vm.wireguard
  "WireGuard config generation wizard. Produces per-peer wg-quick configs
  (with matched keypairs) for a hub-and-spoke VPN into the hub's machine
  config directory (machines/<hub>/wireguard/), and updates
  machines/<hub>/wireguard.conf so `just upgrade <hub>` applies it.

  The .wg-state.edn file in machines/<hub>/wireguard/ is the source of
  truth; every .conf/.pub is regenerated from it. Never hand-edit the
  generated .conf files — edits will be lost the next time the
  `wireguard` command runs.

  Single entry point: `just wireguard <hub>`. If there is no state yet,
  runs the init wizard (prompts for subnet, hub params, and a list of
  spokes). If state exists, shows a menu that covers add-peer, remove,
  rename, address edits, and hub endpoint/port changes. Also exposes
  `generate-keypair!` reused by vm.machine when seeding a machine's
  initial wireguard.conf."
  (:require [clojure.string :as str]
            [clojure.edn :as edn]
            [clojure.pprint :as pp]
            [babashka.fs :as fs]
            [vm.proc :as proc]
            [vm.prompt :as prompt]
            [vm.machine :as machine]))

;; ─── key generation ──────────────────────────────────────────────────────────

(defn generate-keypair!
  "Generate a fresh WireGuard keypair via `nix run nixpkgs#wireguard-tools`.
  Returns {:private <base64> :public <base64>}."
  [cfg]
  (let [priv (proc/capture (concat (:nix cfg) ["run" "nixpkgs#wireguard-tools" "--" "genkey"]))
        pub  (proc/capture (concat (:nix cfg) ["run" "nixpkgs#wireguard-tools" "--" "pubkey"])
                           {:in priv})]
    {:private priv :public pub}))

;; ─── cidr helpers ────────────────────────────────────────────────────────────

(defn- v6-cidr?
  "True if `s` looks like an IPv6 CIDR/address (contains a colon)."
  [s]
  (str/includes? (or s "") ":"))

(defn- split-cidr
  "Split '10.0.0.1/24' -> ['10.0.0.1' 24]. nil on missing/invalid prefix."
  [cidr]
  (let [[a p] (str/split (str cidr) #"/" 2)]
    (when-let [n (try (Long/parseLong (str p)) (catch Exception _ nil))]
      [a n])))

(defn- addr-of
  "Strip prefix: '10.0.0.5/24' -> '10.0.0.5'."
  [cidr]
  (first (split-cidr cidr)))

(defn- host-cidr
  "Convert a CIDR to the /32 (v4) or /128 (v6) host form."
  [cidr]
  (let [a (addr-of cidr)]
    (format "%s/%d" a (if (v6-cidr? a) 128 32))))

(defn- parse-cidr
  "Parse '10.0.0.0/24' -> {:base [10 0 0 0] :prefix 24}. IPv4 only.
  Throws ex-info on bad input."
  [s]
  (let [t (str/trim (or s ""))
        [addr prefix] (str/split t #"/" 2)]
    (when (str/blank? prefix)
      (throw (ex-info (format "invalid CIDR '%s' (expected e.g. 10.0.0.0/24)" t) {})))
    (let [octets (try (mapv #(Long/parseLong %) (str/split addr #"\."))
                      (catch Exception _ nil))
          p (try (Long/parseLong prefix) (catch Exception _ nil))]
      (when (or (nil? octets) (not= 4 (count octets))
                (some #(or (< % 0) (> % 255)) octets)
                (nil? p) (< p 8) (> p 32))
        (throw (ex-info (format "invalid CIDR '%s' (expected e.g. 10.0.0.0/24)" t) {})))
      {:base octets :prefix p})))

(defn- subnet-str [{:keys [base prefix]}]
  (format "%s/%d" (str/join "." base) prefix))

(defn- primary-v4-subnet
  "First IPv4 entry in `:subnets`, parsed. nil if none."
  [subnets]
  (some (fn [s] (try (let [c (parse-cidr s)] c) (catch Exception _ nil)))
        subnets))

(defn- suggest-next-ip
  "For a /24 subnet, return 'a.b.c.N/24' for the smallest N in [1..254] not
  in used-set. nil for prefixes other than /24 (auto-suggestion off; user
  must type). `used-set` is a set of bare-IP strings."
  [subnet used-set]
  (when (and subnet (= 24 (:prefix subnet)))
    (let [[a b c _] (:base subnet)
          used-last (into #{} (keep (fn [ip]
                                      (try (Long/parseLong (last (str/split ip #"\.")))
                                           (catch Exception _ nil)))
                                    used-set))]
      (when-let [n (first (remove used-last (range 1 255)))]
        (format "%d.%d.%d.%d/%d" a b c n (:prefix subnet))))))

;; ─── config rendering ────────────────────────────────────────────────────────

(def ^:private warning-banner
  (str/join "\n"
            ["# ============================================================================"
             "# WARNING: This file is generated. Do NOT hand-edit."
             "#"
             "# It is rewritten from machines/<hub>/wireguard/.wg-state.edn every time"
             "# `just wireguard <hub>` runs — your edits WILL be lost."
             "#"
             "# To change addresses, endpoints, peer names, or add/remove peers, run"
             "# `just wireguard <hub>` on the workstation and pick from the menu."
             "# ============================================================================"]))

(defn- render-interface [self]
  (str/join "\n"
            (concat
             ["[Interface]"
              (format "# hostname: %s" (:name self))
              (format "PrivateKey = %s" (:private self))
              (format "Address    = %s" (str/join ", " (:addresses self)))]
             (when-let [port (:listen-port self)]
               [(format "ListenPort = %d" port)]))))

(defn- render-peer-block
  "One [Peer] block for `other` from `self`'s perspective. `allowed-ips` is
  a vec of CIDR strings to join for the AllowedIPs line."
  [self other allowed-ips]
  (let [roaming-self? (nil? (:listen-port self))
        listener-other? (some? (:endpoint other))]
    (str/join "\n"
              (concat
               ["[Peer]"
                (format "# hostname: %s" (:name other))
                (format "PublicKey  = %s" (:public other))]
               (when listener-other?
                 [(format "Endpoint   = %s" (:endpoint other))])
               [(format "AllowedIPs = %s" (str/join ", " allowed-ips))]
               (when (and roaming-self? listener-other?)
                 ["PersistentKeepalive = 25"])))))

(defn- render-config
  "Full wg-quick config for `self` in a hub-and-spoke topology."
  [subnets self peers]
  (let [banner (str/join "\n"
                         [warning-banner
                          ""
                          (format "# WireGuard config for '%s' (interface wg0)." (:name self))
                          (format "# Public key: %s" (:public self))
                          (format "# Generated by `just wireguard` — subnets %s, topology hub-spoke."
                                  (str/join ", " subnets))
                          "# Standard wg-quick format (man wg-quick / man wg)."])
        interface (render-interface self)
        others (remove #(= (:name %) (:name self)) peers)
        peer-blocks
        (if (= :hub (:role self))
          (for [p others]
            (render-peer-block self p (mapv host-cidr (:addresses p))))
          (let [hub (first (filter #(= :hub (:role %)) peers))]
            (when-not hub
              (throw (ex-info "hub-and-spoke topology has no hub peer" {})))
            [(render-peer-block self hub (vec subnets))]))]
    (str (str/join "\n\n" (cons banner (cons interface peer-blocks))) "\n")))

;; ─── prompts ─────────────────────────────────────────────────────────────────

(defn- retry
  "Call `f`; if it throws ex-info, print its message and retry. Any other
  exception propagates (bug, not user input error)."
  [f]
  (loop []
    (let [r (try [::ok (f)]
                 (catch clojure.lang.ExceptionInfo e [::retry (ex-message e)]))]
      (if (= ::ok (first r))
        (second r)
        (do (println (format "  ! %s" (second r))) (recur))))))

(defn- valid-peer-name? [s]
  (boolean (re-matches #"[A-Za-z0-9][A-Za-z0-9._-]*" (or s ""))))

(defn- ask-subnet []
  (let [s (parse-cidr (prompt/ask "VPN subnet (CIDR):" "10.0.0.0/24"))]
    (subnet-str s)))

(defn- parse-port [s]
  (try (let [n (Long/parseLong (str/trim (or s "")))]
         (when (or (< n 1) (> n 65535))
           (throw (ex-info "port out of range" {})))
         n)
       (catch NumberFormatException _
         (throw (ex-info (format "invalid port '%s'" s) {})))))

(defn- parse-addr-input
  "Accept 'a.b.c.d' or 'a.b.c.d/N' (IPv4). Returns 'a.b.c.d/N', filling in
  the prefix from `default-prefix` when the input has none. Throws ex-info
  on invalid input."
  [s default-prefix]
  (let [t (str/trim (or s ""))]
    (when (str/blank? t)
      (throw (ex-info "address is required" {})))
    (let [has-prefix? (str/includes? t "/")
          [addr p-str] (str/split t #"/" 2)]
      (when-not (re-matches #"\d+\.\d+\.\d+\.\d+" addr)
        (throw (ex-info (format "address '%s' must be an IPv4 (a.b.c.d[/N])" t) {})))
      (let [p (if has-prefix?
                (try (Long/parseLong p-str)
                     (catch Exception _
                       (throw (ex-info (format "invalid prefix in '%s'" t) {}))))
                default-prefix)]
        (when (or (< p 8) (> p 32))
          (throw (ex-info (format "prefix '/%d' out of range (8..32)" p) {})))
        (format "%s/%d" addr p)))))

(defn- ask-hub
  "Prompt for the hub peer's listener details. `name` is the hub's peer name
  (matches its VM machine dir) and is not prompted for."
  [subnet name]
  (retry
   (fn []
     (let [listen-port (parse-port (prompt/ask
                                    (format "ListenPort for '%s' (UDP):" name) "51820"))
           endpoint (let [h (str/trim (prompt/ask
                                       (format "Public Endpoint for '%s' (host or IP that peers dial):" name)))]
                      (when (str/blank? h)
                        (throw (ex-info "endpoint host is required for the hub" {})))
                      (format "%s:%d" h listen-port))
           suggested (suggest-next-ip subnet #{})
           addr (parse-addr-input
                 (prompt/ask
                  (format "Tunnel address for '%s' (inside %s):"
                          name (subnet-str subnet))
                  suggested)
                 (:prefix subnet))]
       {:name name :role :hub :addresses [addr]
        :listen-port listen-port :endpoint endpoint}))))

(defn- ask-spoke
  "Prompt for one spoke peer. `existing` are already-added peers so we can
  suggest the next address and prevent name/address collisions."
  [subnet existing]
  (retry
   (fn []
     (let [name (str/trim (prompt/ask "Peer name (used as filename and comment):"))]
       (when (str/blank? name) (throw (ex-info "peer name is required" {})))
       (when-not (valid-peer-name? name)
         (throw (ex-info "peer name must start alphanumeric; only letters, digits, . _ -" {})))
       (when (some #(= (:name %) name) existing)
         (throw (ex-info (format "peer name '%s' already used" name) {})))
       (let [used-addrs (into #{} (mapcat (fn [p] (map addr-of (:addresses p))) existing))
             suggested (suggest-next-ip subnet used-addrs)
             addr (parse-addr-input
                   (prompt/ask
                    (format "Tunnel address for '%s' (inside %s):"
                            name (subnet-str subnet))
                    suggested)
                   (:prefix subnet))]
         (when (contains? used-addrs (addr-of addr))
           (throw (ex-info (format "address %s already assigned to another peer" (addr-of addr)) {})))
         {:name name :role :spoke :addresses [addr]
          :listen-port nil :endpoint nil})))))

(defn- summarize-peer [p]
  (format "  %-16s  %-32s%s%s"
          (:name p)
          (str/join ", " (:addresses p))
          (case (:role p)
            :hub      "  [hub]"
            :spoke    "  [spoke]"
            "")
          (if (:endpoint p) (str "  -> " (:endpoint p)) "")))

;; ─── state file ──────────────────────────────────────────────────────────────

(def ^:private state-version 3)
(defn- state-path [out-dir] (str out-dir "/.wg-state.edn"))

(defn- migrate-state
  "Bring `data` up to `state-version`. Accepts v1, v2, v3 (v1/v2 shared
  the {:subnet, :peers [{:address :prefix ...}]} shape)."
  [data]
  (case (:version data)
    3 data
    (1 2) (-> data
              (assoc :version 3
                     :subnets [(:subnet data)])
              (dissoc :subnet)
              (update :peers
                      (fn [ps]
                        (mapv (fn [p]
                                (-> p
                                    (assoc :addresses
                                           [(format "%s/%d"
                                                    (:address p) (:prefix p))])
                                    (dissoc :address :prefix)))
                              ps))))
    (throw (ex-info (format "unsupported .wg-state.edn version %s" (:version data)) {}))))

(defn- write-state!
  "Persist subnets + peer metadata to .wg-state.edn. Private keys are never
  written here — they stay in <peer>.key."
  [out-dir subnets peers]
  (let [scrubbed (mapv #(select-keys % [:name :role :addresses
                                        :listen-port :endpoint :public])
                       peers)
        data {:version state-version
              :subnets (vec subnets)
              :topology :hub-spoke
              :peers scrubbed}]
    (fs/create-dirs out-dir)
    (spit (state-path out-dir)
          (binding [*print-namespace-maps* false]
            (with-out-str (pp/pprint data))))))

(defn- load-state-or-exit!
  "Read .wg-state.edn from an existing dir, migrate to current version, or
  print + exit 1 on any problem."
  [out-dir hub-name]
  (cond
    (not (fs/directory? out-dir))
    (do (println (format "Error: '%s' does not exist." out-dir))
        (println (format "  Run 'just wireguard %s' first." hub-name))
        (System/exit 1))

    (not (fs/exists? (state-path out-dir)))
    (do (println (format "Error: no .wg-state.edn in %s" out-dir))
        (println (format "  Run 'just wireguard %s' to create it." hub-name))
        (System/exit 1))

    :else
    (let [p (state-path out-dir)
          raw (try (edn/read-string (slurp p))
                   (catch Exception e
                     (println (format "Error: failed to parse %s: %s" p (ex-message e)))
                     (System/exit 1)))
          migrated (try (migrate-state raw)
                        (catch clojure.lang.ExceptionInfo e
                          (println (format "Error: %s in %s" (ex-message e) p))
                          (System/exit 1)))]
      (when (not= (:version raw) state-version)
        (println (format "Note: migrated %s from v%s to v%d (will rewrite on next change)."
                         p (:version raw) state-version)))
      migrated)))

(defn- rehydrate-peer!
  "Attach an existing peer's private key (read from <peer>.key on disk) so it
  can be re-rendered. Exits with a clear error if the .key file is missing.
  Peers already carrying a :private value (e.g. freshly generated via the
  add-spoke op) are returned unchanged."
  [out-dir peer]
  (if (:private peer)
    peer
    (let [name (:name peer)
          kp (str out-dir "/" name ".key")]
      (when-not (fs/exists? kp)
        (println (format "Error: state file lists peer '%s' but %s is missing." name kp))
        (println "  Cannot regenerate configs without the private key. Restore it from a")
        (println "  backup-* subdirectory or delete the wireguard/ dir and start over.")
        (System/exit 1))
      (assoc peer :private (str/trim (slurp kp))))))

;; ─── backup ──────────────────────────────────────────────────────────────────

(defn- ts-stamp []
  (.format (java.time.LocalDateTime/now)
           (java.time.format.DateTimeFormatter/ofPattern "yyyyMMdd-HHmmss")))

(defn- backup-existing!
  "Move every existing .conf/.key/.pub/README.txt/.wg-state.edn in `out-dir`,
  plus the hub's `<parent>/wireguard.conf` (identity file), into
  `out-dir/backup-<ts>/`. Returns the backup dir path, or nil if there was
  nothing to move."
  [out-dir hub-conf]
  (let [backup-dir (str out-dir "/backup-" (ts-stamp))
        globbed (when (fs/directory? out-dir)
                  (concat (map str (fs/glob out-dir "*.conf"))
                          (map str (fs/glob out-dir "*.key"))
                          (map str (fs/glob out-dir "*.pub"))))
        extras (filter fs/exists? [(str out-dir "/README.txt")
                                   (state-path out-dir)
                                   hub-conf])
        all (concat globbed extras)]
    (when (seq all)
      (fs/create-dirs backup-dir)
      (doseq [src all]
        (fs/move src (str backup-dir "/" (fs/file-name src)) {:replace-existing true}))
      backup-dir)))

;; ─── file writing / apply ────────────────────────────────────────────────────

(defn- write-peer-files!
  "Write <peer>.key/.pub/.conf into `out-dir`. Sets 0600 on private key + conf."
  [out-dir subnets peers]
  (fs/create-dirs out-dir)
  (doseq [self peers
          :let [name (:name self)
                key-path  (str out-dir "/" name ".key")
                pub-path  (str out-dir "/" name ".pub")
                conf-path (str out-dir "/" name ".conf")]]
    (spit key-path (str (:private self) "\n"))
    (fs/set-posix-file-permissions key-path "rw-------")
    (spit pub-path (str (:public self) "\n"))
    (spit conf-path (render-config subnets self peers))
    (fs/set-posix-file-permissions conf-path "rw-------")
    (println (format "  wrote %s.{key,pub,conf}" name))))

(defn- write-readme! [out-dir subnets hub-name peers]
  (let [lines
        (concat
         [(format "WireGuard configs — subnets %s, topology hub-spoke, hub '%s'."
                  (str/join ", " subnets) hub-name)
          ""
          "Source of truth: .wg-state.edn in this dir. The .conf/.pub files"
          "are regenerated from it every time `just wireguard <hub>` runs."
          "Never hand-edit the .conf files — use `just wireguard <hub>` on"
          "the workstation to change addresses, endpoints, or peer names."
          ""
          "Files per peer:"
          "  <peer>.key   private key  (mode 0600)"
          "  <peer>.pub   public key   (share)"
          "  <peer>.conf  wg-quick config  (mode 0600, generated)"
          ""
          (format "The hub's config is already applied at machines/%s/wireguard.conf." hub-name)
          (format "Run 'just upgrade %s' to push it into the VM." hub-name)
          ""
          "Deploying a spoke config:"
          "  * A VM in this repo:   copy <peer>.conf to  machines/<peer>/wireguard.conf"
          "                          then  just upgrade <peer>"
          "                          (the wizard offers to do this for you)."
          "  * A generic Linux box: copy <peer>.conf to  /etc/wireguard/wg0.conf  (mode 0600)"
          "                          then  sudo wg-quick up wg0"
          "                                sudo systemctl enable wg-quick@wg0"
          "  * A phone (WireGuard app): import <peer>.conf, or scan its QR."
          ""
          "Peers:"]
         (map summarize-peer peers)
         [""
          "Notes:"
          " * Spoke configs route the whole VPN subnet(s) through the hub."
          " * The hub must have UDP <ListenPort> reachable from the internet"
          "   (port-forward on the router if behind NAT)."
          " * On this repo's VMs the wireguard profile already opens UDP 51820;"
          "   change udp_ports if you use a different ListenPort."
          ""
          (format "Add / edit peers later:  just wireguard %s" hub-name)
          ""])]
    (spit (str out-dir "/README.txt") (str/join "\n" lines))))

(defn- write-hub-conf!
  "Copy the hub's generated <hub>.conf to machines/<hub>/wireguard.conf so
  identity sync picks it up. The wireguard/ dir remains the source of truth."
  [cfg hub-name out-dir]
  (let [src (str out-dir "/" hub-name ".conf")
        dst (str (machine/machine-dir cfg hub-name) "/wireguard.conf")]
    (fs/copy src dst {:replace-existing true})
    (fs/set-posix-file-permissions dst "rw-------")
    (println (format "  applied -> %s" dst))
    (println (format "    run: just upgrade %s" hub-name))))

(defn- offer-apply-spokes!
  "For every spoke whose name matches an existing machine dir, ask whether to
  copy the generated .conf into machines/<name>/wireguard.conf."
  [cfg out-dir peers]
  (let [known (into #{} (map :name (machine/list-machines cfg)))
        spokes (filter #(= :spoke (:role %)) peers)
        matches (filter #(contains? known (:name %)) spokes)]
    (when (seq matches)
      (println)
      (println (format "Detected %d spoke peer name(s) that match existing machines in %s:"
                       (count matches) (:machines-dir cfg)))
      (doseq [p matches] (println (format "  %s" (:name p))))
      (println)
      (when (prompt/confirm "Copy those .conf files into their machines/<name>/wireguard.conf?" :yes)
        (doseq [p matches
                :let [name (:name p)
                      src (str out-dir "/" name ".conf")
                      dst (str (machine/machine-dir cfg name) "/wireguard.conf")]]
          (when (or (not (fs/exists? dst))
                    (prompt/confirm (format "%s already exists — overwrite?" dst) :no))
            (fs/copy src dst {:replace-existing true})
            (fs/set-posix-file-permissions dst "rw-------")
            (println (format "  copied -> %s" dst))
            (println (format "    run: just upgrade %s" name))))))))

;; ─── main entrypoints ────────────────────────────────────────────────────────

(defn- require-name! [name usage]
  (when (or (nil? name) (str/blank? name))
    (println "Error: hub VM name is required.")
    (println (str "Usage: " usage))
    (System/exit 1)))

(defn- require-machine! [cfg name]
  (when-not (machine/exists? cfg name)
    (println (format "Error: no machine config at %s." (machine/machine-dir cfg name)))
    (println (format "  Create it first:  just create %s wireguard" name))
    (System/exit 1)))

(defn- out-dir-for [cfg name]
  (str (machine/machine-dir cfg name) "/wireguard"))

(defn- hub-conf-for [cfg name]
  (str (machine/machine-dir cfg name) "/wireguard.conf"))

(defn- write-all!
  "Write per-peer files, README, and state file. Common tail of all wizards."
  [cfg hub-name out-dir subnets peers]
  (write-peer-files! out-dir subnets peers)
  (write-readme! out-dir subnets hub-name peers)
  (write-state! out-dir subnets peers)
  (println "  wrote README.txt and .wg-state.edn")
  (write-hub-conf! cfg hub-name out-dir))

(defn- init-flow
  "First-run: prompt for subnet, hub params, and a list of spokes. Generates
  keypairs and wg-quick configs into machines/<hub>/wireguard/. Copies the
  hub's own config to machines/<hub>/wireguard.conf so `just upgrade <hub>`
  applies it. For spoke peer names that match other machine dirs, offers to
  apply their configs too."
  [cfg name]
  (let [out-dir (out-dir-for cfg name)
        hub-conf (hub-conf-for cfg name)]
    (println "WireGuard config wizard")
    (println (format "  Hub VM:  %s" name))
    (println (format "  Output:  %s/" out-dir))
    (println "  Generates matched keypairs and wg-quick configs for a hub-and-spoke VPN.")
    (println "  Nothing is written until you confirm the plan.")
    (println)
    (let [subnet-str-in (ask-subnet)
          subnet (parse-cidr subnet-str-in)
          _ (println (format "Subnet: %s" subnet-str-in))
          _ (when-not (= 24 (:prefix subnet))
              (println "  (auto-address suggestion is disabled for non-/24 subnets — type the address manually)"))
          _ (println)
          _ (println (format "── Hub peer '%s' ─────────────────────────" name))
          hub (ask-hub subnet name)
          _ (println (summarize-peer hub))
          _ (println)
          _ (println "Now add the spoke peers.")
          peers
          (loop [acc [hub]]
            (println (format "── Spoke %d ─────────────────────────" (count acc)))
            (let [p (ask-spoke subnet acc)
                  acc' (conj acc p)]
              (println (summarize-peer p))
              (println)
              (if (and (>= (count acc') 2)
                       (not (prompt/confirm "Add another peer?" :yes)))
                acc'
                (recur acc'))))]
      (println)
      (println "Plan:")
      (println (format "  Subnet:   %s" subnet-str-in))
      (println (format "  Hub:      %s" name))
      (println (format "  Peers:    %d" (count peers)))
      (doseq [p peers] (println (summarize-peer p)))
      (println (format "  Output:   %s" out-dir))
      (println (format "  Hub cfg:  %s" hub-conf))
      (println)
      (when-not (prompt/confirm "Generate keys and write files?" :yes)
        (println "Aborted.")
        (System/exit 0))
      (println)
      (println "Generating keypairs...")
      (let [peers-kp (mapv (fn [p] (merge p (generate-keypair! cfg))) peers)]
        (println)
        (when-let [b (backup-existing! out-dir hub-conf)]
          (println (format "Backed up previous files -> %s" b)))
        (println (format "Writing configs to %s" out-dir))
        (write-all! cfg name out-dir [subnet-str-in] peers-kp)
        (offer-apply-spokes! cfg out-dir peers-kp)
        (println)
        (println "Done.")
        (println (format "  Hub state:  %s/" out-dir))
        (println "  See README.txt for how to deploy each spoke's config.")
        (println (format "  Add / edit later:  just wireguard %s" name))))))

;; ─── editor ──────────────────────────────────────────────────────────────────

(defn- pick-peer
  "Prompt the user to pick a peer by name from `peers`. Returns the chosen
  peer map, or nil if the user aborts. `predicate` optionally filters the
  list (e.g. spokes only)."
  ([peers msg] (pick-peer peers msg identity))
  ([peers msg predicate]
   (let [candidates (filter predicate peers)]
     (if (empty? candidates)
       (do (println "  (no eligible peers)") nil)
       (let [labels (mapv :name candidates)
             choice (prompt/choose msg labels)]
         (first (filter #(= (:name %) choice) candidates)))))))

(defn- used-addrs-except
  "Set of bare-IP addresses across `peers`, excluding those belonging to
  `except-name`."
  [peers except-name]
  (into #{}
        (mapcat (fn [p]
                  (when (not= (:name p) except-name)
                    (map addr-of (:addresses p))))
                peers)))

(defn- op-add-spoke
  "Prompt for a new spoke, generate its keypair, and add it to state.
  Peer arrives fully hydrated (with :private/:public), so no disk lookup
  is required at apply time."
  [cfg state]
  (let [subnet (primary-v4-subnet (:subnets state))
        peer (ask-spoke subnet (:peers state))]
    (println "  generating keypair...")
    (let [hydrated (merge peer (generate-keypair! cfg))]
      (println (format "  will add %s (%s, pub %s)"
                       (:name hydrated)
                       (str/join ", " (:addresses hydrated))
                       (:public hydrated)))
      (update state :peers conj hydrated))))

(defn- op-add-address
  "Prompt for a target peer and a new address, return updated state."
  [_cfg state]
  (let [peers (:peers state)
        target (pick-peer peers "Add address to which peer?")]
    (if-not target
      state
      (let [subnet (primary-v4-subnet (:subnets state))
            default-prefix (or (:prefix subnet) 24)
            used (used-addrs-except peers (:name target))
            addr (retry
                  (fn []
                    (let [in (prompt/ask
                              (format "New address for '%s' (a.b.c.d[/N] or IPv6 CIDR):"
                                      (:name target)))
                          t (str/trim (or in ""))]
                      (when (str/blank? t)
                        (throw (ex-info "address is required" {})))
                      (cond
                        (v6-cidr? t)
                        (do (when-not (str/includes? t "/")
                              (throw (ex-info "IPv6 address needs an explicit /prefix" {})))
                            t)

                        :else
                        (let [normalized (parse-addr-input t default-prefix)]
                          (when (contains? used (addr-of normalized))
                            (throw (ex-info (format "address %s already assigned"
                                                    (addr-of normalized)) {})))
                          (when (some #(= % normalized) (:addresses target))
                            (throw (ex-info "peer already has that address" {})))
                          normalized)))))]
        (println (format "  will add %s to %s" addr (:name target)))
        (update-in state [:peers]
                   (fn [ps]
                     (mapv (fn [p]
                             (if (= (:name p) (:name target))
                               (update p :addresses conj addr)
                               p))
                           ps)))))))

(defn- op-remove-address
  "Prompt for a target peer and one of its addresses to remove."
  [_cfg state]
  (let [peers (:peers state)
        target (pick-peer peers "Remove address from which peer?"
                          (fn [p] (> (count (:addresses p)) 1)))]
    (cond
      (nil? target)
      (do (println "  (no peer has more than one address to remove)")
          state)

      :else
      (let [choice (prompt/choose (format "Which address to remove from '%s'?"
                                          (:name target))
                                  (vec (:addresses target)))]
        (println (format "  will remove %s from %s" choice (:name target)))
        (update-in state [:peers]
                   (fn [ps]
                     (mapv (fn [p]
                             (if (= (:name p) (:name target))
                               (update p :addresses (fn [as] (vec (remove #(= % choice) as))))
                               p))
                           ps)))))))

(defn- op-rename-peer
  "Prompt for a spoke to rename. Hub rename is disallowed — see note."
  [_cfg state]
  (let [peers (:peers state)
        target (pick-peer peers "Rename which peer? (spokes only)"
                          (fn [p] (= (:role p) :spoke)))]
    (if-not target
      state
      (retry
       (fn []
         (let [new-name (str/trim (prompt/ask (format "New name for '%s':" (:name target))))]
           (when (str/blank? new-name)
             (throw (ex-info "name is required" {})))
           (when-not (valid-peer-name? new-name)
             (throw (ex-info "name must start alphanumeric; only letters, digits, . _ -" {})))
           (when (some #(= (:name %) new-name) peers)
             (throw (ex-info (format "name '%s' already used" new-name) {})))
           (println (format "  will rename %s -> %s" (:name target) new-name))
           (update-in state [:peers]
                      (fn [ps]
                        (mapv (fn [p]
                                (if (= (:name p) (:name target))
                                  (assoc p :name new-name)
                                  p))
                              ps)))))))))

(defn- op-remove-spoke
  [_cfg state]
  (let [peers (:peers state)
        target (pick-peer peers "Remove which spoke?"
                          (fn [p] (= (:role p) :spoke)))]
    (if-not target
      state
      (if (prompt/confirm (format "Really remove peer '%s'?" (:name target)) :no)
        (do (println (format "  will remove %s" (:name target)))
            (update-in state [:peers]
                       (fn [ps] (vec (remove #(= (:name %) (:name target)) ps)))))
        state))))

(defn- op-change-hub-endpoint
  [_cfg state]
  (let [hub (first (filter #(= :hub (:role %)) (:peers state)))]
    (if-not hub
      (do (println "  (no hub in state — cannot edit)") state)
      (retry
       (fn []
         (let [host (str/trim
                     (prompt/ask
                      (format "Public Endpoint host for '%s' (host or IP that peers dial):"
                              (:name hub))
                      (or (some-> (:endpoint hub) (str/split #":" 2) first) "")))]
           (when (str/blank? host)
             (throw (ex-info "endpoint host is required" {})))
           (let [port (:listen-port hub)
                 endpoint (format "%s:%d" host port)]
             (println (format "  will set endpoint = %s" endpoint))
             (update-in state [:peers]
                        (fn [ps]
                          (mapv (fn [p]
                                  (if (= :hub (:role p))
                                    (assoc p :endpoint endpoint)
                                    p))
                                ps))))))))))

(defn- op-change-hub-listen-port
  [_cfg state]
  (let [hub (first (filter #(= :hub (:role %)) (:peers state)))]
    (if-not hub
      (do (println "  (no hub in state — cannot edit)") state)
      (retry
       (fn []
         (let [port (parse-port (prompt/ask
                                 (format "ListenPort for '%s' (UDP):" (:name hub))
                                 (str (:listen-port hub))))
               host (some-> (:endpoint hub) (str/split #":" 2) first)
               endpoint (when host (format "%s:%d" host port))]
           (println (format "  will set ListenPort = %d%s" port
                            (if endpoint (format ", Endpoint = %s" endpoint) "")))
           (update-in state [:peers]
                      (fn [ps]
                        (mapv (fn [p]
                                (if (= :hub (:role p))
                                  (cond-> (assoc p :listen-port port)
                                    endpoint (assoc :endpoint endpoint))
                                  p))
                              ps)))))))))

(def ^:private edit-ops
  ;; ordered so the menu is stable
  [["Add spoke peer"               op-add-spoke]
   ["Add address to a peer"        op-add-address]
   ["Remove address from a peer"   op-remove-address]
   ["Rename a spoke"               op-rename-peer]
   ["Remove a spoke"               op-remove-spoke]
   ["Change hub endpoint (host)"   op-change-hub-endpoint]
   ["Change hub listen-port"       op-change-hub-listen-port]
   ["Apply changes and regenerate" ::apply]
   ["Quit without saving"          ::quit]])

(defn- print-state-summary [state]
  (println (format "  Subnets:  %s" (str/join ", " (:subnets state))))
  (println (format "  Peers:    %d" (count (:peers state))))
  (doseq [p (:peers state)] (println (summarize-peer p))))

(defn- menu-flow
  "Menu-driven editor when state already exists. Covers add-spoke plus
  every edit op; commits the queued changes atomically on Apply."
  [cfg name]
  (let [out-dir (out-dir-for cfg name)
        hub-conf (hub-conf-for cfg name)
        initial (load-state-or-exit! out-dir name)]
    (println "WireGuard editor")
    (println (format "  Hub VM:  %s" name))
    (println (format "  State:   %s" (state-path out-dir)))
    (println)
    (loop [state initial
           dirty? false]
      (println "Current state:")
      (print-state-summary state)
      (println)
      (let [labels (mapv first edit-ops)
            choice (prompt/choose "Action:" labels)
            op (second (first (filter #(= (first %) choice) edit-ops)))]
        (cond
          (= op ::quit)
          (if (and dirty?
                   (not (prompt/confirm "Discard pending changes?" :no)))
            (recur state dirty?)
            (do (println "Aborted; no files changed.")
                (System/exit 0)))

          (= op ::apply)
          (cond
            (not dirty?)
            (do (println "No changes to apply.")
                (System/exit 0))

            (not (prompt/confirm "Back up, regenerate all configs, and rewrite state?" :yes))
            (recur state dirty?)

            :else
            (let [subnets (:subnets state)
                  peers (:peers state)
                  hydrated (mapv #(rehydrate-peer! out-dir %) peers)
                  backup-dir (backup-existing! out-dir hub-conf)]
              (when backup-dir
                (println (format "  backed up previous files -> %s" backup-dir)))
              (println (format "Writing configs to %s" out-dir))
              (write-all! cfg name out-dir subnets hydrated)
              (offer-apply-spokes! cfg out-dir hydrated)
              (println)
              (println "Done.")
              (println (format "  Backup:  %s" (or backup-dir "(nothing to back up)")))
              (println "  Existing peers' configs may have changed — redeploy any you didn't apply.")))

          :else
          (let [state' (op cfg state)]
            (println)
            (recur state' (or dirty? (not= state state')))))))))

(defn command
  "Single entry point for `just wireguard <hub>`. If no state exists yet,
  runs the init wizard; otherwise drops into the menu editor."
  [cfg name]
  (require-name! name "just wireguard <hub>")
  (require-machine! cfg name)
  (let [out-dir (out-dir-for cfg name)]
    (if (fs/exists? (state-path out-dir))
      (menu-flow cfg name)
      (do (println (format "No WireGuard state at %s." (state-path out-dir)))
          (if (prompt/confirm "Initialize a new hub-and-spoke deployment?" :yes)
            (init-flow cfg name)
            (do (println "Aborted.")
                (System/exit 0)))))))
