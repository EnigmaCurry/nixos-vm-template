(ns vm.wizard
  "Interactive VM configuration wizard (config_vm_interactive from common.sh).
  Backend-aware (libvirt vs proxmox) but self-contained: it carries its own
  pve-ssh for proxmox discovery so it never requires the proxmox backend ns
  (which requires this ns), avoiding a cycle."
  (:require [clojure.string :as str]
            [babashka.fs :as fs]
            [cheshire.core :as json]
            [vm.proc :as proc]
            [vm.prompt :as prompt]
            [vm.machine :as machine]
            [vm.profile :as profile]
            [vm.net :as net]))

(defn- pve-ssh [cfg cmd]
  (try (proc/capture (concat (:ssh cfg) ["-o" "BatchMode=yes" "-o" "StrictHostKeyChecking=accept-new"
                                         (:pve-host cfg) cmd]))
       (catch Exception _ "")))

(defn- pve-list-display-pci
  "Query PVE for PCI devices in display classes (0x03xx) plus any multimedia
  device (0x04xx) sharing the same BB:SS slot — for NVIDIA GPUs that's the
  HDMI audio function. Returns [{:id :label :group} ...] sorted by id.
  Returns [] on any failure (no PVE, no lspci output, network error)."
  [cfg]
  (let [out (pve-ssh cfg (format "pvesh get /nodes/%s/hardware/pci --pci-class-blacklist \"\" --output-format json"
                                 (:pve-node cfg)))]
    (if (str/blank? out)
      []
      (try
        (let [all (json/parse-string out true)
              slot (fn [d] (second (re-find #"^[0-9a-fA-F]+:([0-9a-fA-F]+:[0-9a-fA-F]+)\." (or (:id d) ""))))
              display-class? #(str/starts-with? (or (:class %) "") "0x03")
              multimedia?    #(str/starts-with? (or (:class %) "") "0x04")
              display-slots  (->> all (filter display-class?) (keep slot) set)
              matches?       #(or (display-class? %)
                                  (and (multimedia? %) (contains? display-slots (slot %))))]
          (->> all
               (filter matches?)
               (map (fn [d]
                      (let [vendor (or (:vendor_name d) "")
                            device (or (:device_name d) "")
                            group  (or (:iommugroup d) "")
                            label  (str (:id d)
                                        (when-not (str/blank? group) (format "  [iommu %s]" group))
                                        (when (or (seq vendor) (seq device))
                                          (format "  %s %s" vendor device)))]
                        {:id (:id d) :label label :group group})))
               (sort-by :id)
               vec))
        (catch Exception _ [])))))

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

(def ^:private nfs-clients-template
  "Commented NFS client allowlist seeded for nas containers. All-commented = no
  NFS export (deny by default)."
  (str/join "\n"
            ["# NFS client allowlist for the nas profile."
             "# Each line:  <cidr-or-host> [ro]      (default is read-write)"
             "#"
             "# NFS has no per-user auth (sec=sys), so access is HOST-based and"
             "# DENY-BY-DEFAULT: until you add an entry, NFS exports nothing to anyone"
             "# (Samba is unaffected). All client users map to the shared 'nas' owner"
             "# (all_squash), so any user on an allowed host can read/write every file —"
             "# list only hosts you trust."
             "#"
             "# Apply changes with:  just sync-identity <name>"
             "#"
             "# Examples:"
             "#   10.13.0.0/16       # a LAN subnet, read-write"
             "#   192.168.1.50 ro    # a single host, read-only"
             ""]))

(defn- choose-d
  "choose with an optional 0-based default index (passed to the pod as the value)."
  [msg options idx]
  (if (and idx (< idx (count options)))
    (prompt/choose msg options (nth options idx))
    (prompt/choose msg options)))

(defn- available-profiles
  "profiles/*.nix names excluding core/mutable/semi-mutable."
  [cfg]
  (->> (fs/glob (str (:repo-dir cfg) "/profiles") "*.nix")
       (map #(str/replace (fs/file-name %) #"\.nix$" ""))
       (remove #{"core" "mutable" "semi-mutable"})
       sort vec))

(defn- err-exit [msg] (println msg) (System/exit 1))

(defn- pve-list-bridges-detailed
  "Returns [[name label] ...] for bridges on the PVE node."
  [cfg]
  (let [script "for d in /sys/class/net/*/bridge; do
  [ -d \"$d\" ] || continue
  br=$(basename \"$(dirname \"$d\")\")
  case \"$br\" in fwbr*) continue ;; esac
  ip=$(ip -4 addr show dev \"$br\" 2>/dev/null | awk '/inet /{print $2; exit}')
  ports=\"\"
  if [ -d \"/sys/class/net/$br/brif\" ]; then
    ports=$(ls /sys/class/net/$br/brif 2>/dev/null | tr '\\n' ',' | sed 's/,$//')
  fi
  detail=\"\"
  [ -n \"$ip\" ] && detail=\"$ip\"
  [ -n \"$ports\" ] && detail=\"${detail:+$detail, }$ports\"
  printf '%s\\t%s (%s)\\n' \"$br\" \"$br\" \"$detail\"
done 2>/dev/null"]
    (->> (str/split-lines (pve-ssh cfg script))
         (remove str/blank?)
         (map #(str/split % #"\t" 2))
         (filter #(= 2 (count %)))
         vec)))

(defn- save-static-ip!
  "Persist static_ip + resolv.conf (or remove static_ip for DHCP)."
  [cfg name addr gw dns1 dns2]
  (let [md (machine/machine-dir cfg name)]
    (if (str/blank? addr)
      (fs/delete-if-exists (str md "/static_ip"))
      (do
        (spit (str md "/static_ip")
              (str "address=" addr "\n" (when-not (str/blank? gw) (str "gateway=" gw "\n"))))
        (println (format "Created: %s/static_ip (%s)" md addr))
        (when-not (str/blank? dns1)
          (spit (str md "/resolv.conf")
                (str/join "\n" [(format "# DNS configuration. Run 'just upgrade %s' to apply changes." name)
                                (str "nameserver " dns1)
                                (str "nameserver " (if (str/blank? dns2) "1.0.0.1" dns2)) ""]))
          (println (format "Updated: %s/resolv.conf (%s, %s)" md dns1 (if (str/blank? dns2) "1.0.0.1" dns2))))))))

(defn- prompt-dns
  "DNS server selection; returns [dns1 dns2]."
  [cfg name gateway]
  (let [choice (prompt/choose "DNS servers:"
                              [(format "Gateway (%s)" (if (str/blank? gateway) "N/A" gateway))
                               "Cloudflare (1.1.1.1, 1.0.0.1)" "Google (8.8.8.8, 8.8.4.4)" "Custom"])
        [d1 d2] (cond
                  (str/starts-with? choice "Gateway") [(if (str/blank? gateway) "1.1.1.1" gateway) "1.1.1.1"]
                  (str/starts-with? choice "Cloudflare") ["1.1.1.1" "1.0.0.1"]
                  (str/starts-with? choice "Google") ["8.8.8.8" "8.8.4.4"]
                  :else (let [resolv (str (machine/machine-dir cfg name) "/resolv.conf")
                              [c1 c2] (if (fs/exists? resolv)
                                        (let [ns (->> (str/split-lines (slurp resolv))
                                                      (keep #(second (re-find #"^nameserver (.*)" %))))]
                                          [(first ns) (second ns)])
                                        [nil nil])]
                          [(prompt/ask "Primary DNS server:" c1) (prompt/ask "Secondary DNS server:" c2)]))
        d2 (if (= d1 d2) "1.0.0.1" d2)]
    (println (format "DNS: %s, %s" d1 d2))
    [d1 d2]))

(defn- iface-attr [br attr]
  (try (str/trim (slurp (str "/sys/class/net/" br "/" attr))) (catch Exception _ "")))

(defn- iface-ip [iface]
  (->> (:out (proc/capture-result ["ip" "-4" "addr" "show" "dev" iface]))
       str/split-lines (keep #(second (re-find #"inet (\S+)" %))) first))

(defn- wizard-network-proxmox
  "Proxmox network selection (bridge + always-prompt static IP). Returns
  {:network :addr :gw :dns1 :dns2}."
  [cfg name md cur-net]
  (let [cur-bridge (when (str/starts-with? (or cur-net "") "bridge:") (subs cur-net 7))
        bridges (pve-list-bridges-detailed cfg)
        network (if (empty? bridges)
                  (do (println "Warning: Could not list bridges from Proxmox node.")
                      (str "bridge:" (prompt/ask "Enter bridge name:" (or cur-bridge "vmbr0"))))
                  (let [labels (mapv second bridges)
                        default (when cur-bridge
                                  (some (fn [[n l]] (when (= n cur-bridge) l)) bridges))
                        choice (if default
                                 (prompt/choose "Select network bridge:" labels default)
                                 (prompt/choose "Select network bridge:" labels))
                        sel (first (str/split choice #" "))]
                    (str "bridge:" sel)))
        _ (println (format "Network: %s" network))
        sel-bridge (subs network 7)
        ip-cidr (str/trim (pve-ssh cfg (format "ip -4 addr show dev %s 2>/dev/null | awk '/inet /{print $2; exit}'" sel-bridge)))
        [bip bcidr] (if (str/includes? ip-cidr "/") (str/split ip-cidr #"/") [nil nil])
        gw0 (str/trim (pve-ssh cfg (format "ip route show dev %s 2>/dev/null | awk '/^default/{print $3}'" sel-bridge)))
        gw (if (and (str/blank? gw0) (not (str/blank? bip)))
             (str (str/join "." (butlast (str/split bip #"\."))) ".1") gw0)
        cur-static (when (fs/exists? (str md "/static_ip")) (slurp (str md "/static_ip")))
        ip-choice (prompt/choose "IP address configuration:" ["DHCP (automatic)" "Static IP"]
                                 (if cur-static "Static IP" "DHCP (automatic)"))]
    (println)
    (if (str/starts-with? ip-choice "Static")
      (let [da (when cur-static (second (re-find #"address=(.*)" cur-static)))
            dg (or (when cur-static (second (re-find #"gateway=(.*)" cur-static))) gw)
            addr0 (prompt/ask (format "Enter IP address (e.g. %s/%s):" (or bip "10.0.0.5") (or bcidr "24")) da)
            _ (when (str/blank? addr0) (err-exit "Error: IP address is required for static IP configuration."))
            addr (if (str/includes? addr0 "/") addr0
                     (let [m (or bcidr "24")] (println (format "  (using /%s subnet mask)" m)) (str addr0 "/" m)))
            gwv (prompt/ask "Enter gateway IP:" dg)
            _ (println (format "Static IP: %s (gateway: %s)" addr (if (str/blank? gwv) "none" gwv)))
            _ (println)
            [d1 d2] (prompt-dns cfg name gwv)]
        {:network network :addr addr :gw gwv :dns1 d1 :dns2 d2})
      (do (println "IP: DHCP") {:network network}))))

(defn- wizard-network-libvirt
  "libvirt network selection (NAT/Bridge + static IP for bridge). Returns
  {:network :addr :gw :dns1 :dns2}."
  [cfg name md cur-net]
  (let [net-idx (cond (= cur-net "nat") 0 (str/starts-with? (or cur-net "") "bridge") 1 :else nil)
        choice (choose-d "Select network mode:" ["NAT" "Bridge"] net-idx)]
    (if (= choice "NAT")
      (do (println "Network: nat") {:network "nat"})
      (let [bridges0 (net/local-bridges)
            bridges (if (empty? bridges0)
                      (do (println "No bridge interfaces found. Creating one...")
                          (let [n (let [v (prompt/ask "Bridge name:" "br0")] (if (str/blank? v) "br0" v))]
                            (proc/run! ["sudo" "nmcli" "connection" "add" "type" "bridge" "ifname" n "con-name" n "stp" "no"])
                            (println (format "Bridge '%s' created." n))
                            [n]))
                      bridges0)
            labels (mapv (fn [br] (format "%s (%s)" br
                                          (let [state (iface-attr br "operstate")
                                                ip (iface-ip br)
                                                ports (when (fs/directory? (str "/sys/class/net/" br "/brif"))
                                                        (->> (fs/list-dir (str "/sys/class/net/" br "/brif"))
                                                             (map fs/file-name) sort (str/join ",")))]
                                            (cond-> (if (str/blank? state) "unknown" state)
                                              (not (str/blank? ip)) (str ", " ip)
                                              (not (str/blank? ports)) (str ", " ports)))))
                         bridges)
            labels (conj labels "Create new bridge")
            cur-bridge (when (str/starts-with? (or cur-net "") "bridge:") (subs cur-net 7))
            default (when cur-bridge (some (fn [[i br]] (when (= br cur-bridge) (nth labels i)))
                                           (map-indexed vector bridges)))
            lb-choice (if default (prompt/choose "Select network bridge:" labels default)
                          (prompt/choose "Select network bridge:" labels))
            sel0 (first (str/split lb-choice #" "))
            sel (if (= sel0 "Create")
                  (let [n (let [v (prompt/ask "Bridge name:" "br0")] (if (str/blank? v) "br0" v))]
                    (proc/run! ["sudo" "nmcli" "connection" "add" "type" "bridge" "ifname" n "con-name" n "stp" "no"])
                    (println (format "Bridge '%s' created." n))
                    n)
                  sel0)
            network (str "bridge:" sel)]
        ;; offer to add a physical interface if none attached
        (when (str/blank? (when (fs/directory? (str "/sys/class/net/" sel "/brif"))
                            (->> (fs/list-dir (str "/sys/class/net/" sel "/brif")) seq)))
          (println (format "Bridge '%s' has no physical interfaces attached." sel))
          (when (prompt/confirm (format "Add a physical interface to %s?" sel) :yes)
            (let [ifaces (->> (fs/list-dir "/sys/class/net")
                              (map fs/file-name)
                              (remove #(re-find #"^(lo|veth|fwbr|fwln|fwpr|tap|virbr|docker|br-)" %))
                              (remove #(fs/directory? (str "/sys/class/net/" % "/bridge")))
                              (filter #(= "1" (iface-attr % "type")))
                              (filter #(fs/exists? (str "/sys/class/net/" % "/device")))
                              sort vec)]
              (if (empty? ifaces)
                (println "No physical interfaces found to bridge.")
                (let [labels (mapv (fn [i] (format "%s (%s%s)" i (let [s (iface-attr i "operstate")] (if (str/blank? s) "unknown" s))
                                                   (let [ip (iface-ip i)] (if (str/blank? ip) "" (str ", " ip))))) ifaces)
                      pc (prompt/choose (format "Select interface to add to %s:" sel) labels)
                      pi (first (str/split pc #" "))
                      slave (str "bridge-slave-" pi)]
                  (println (format "Adding %s to bridge %s (persistent via NetworkManager)..." pi sel))
                  (proc/run! ["sudo" "nmcli" "connection" "add" "type" "bridge-slave" "ifname" pi "master" sel "con-name" slave])
                  (proc/run-ok? ["sudo" "nmcli" "connection" "up" slave])
                  (println (format "Interface %s added to %s." pi sel)))))))
        ;; offer to bring the bridge up if down
        (when (= (iface-attr sel "operstate") "down")
          (println (format "Bridge '%s' is currently down." sel))
          (when (prompt/confirm (format "Bring up %s?" sel) :yes)
            (or (proc/run-ok? ["sudo" "nmcli" "connection" "up" sel])
                (proc/run! ["sudo" "ip" "link" "set" sel "up"]))
            (println (format "Bridge '%s' activated." sel))))
        (println (format "Network: %s" network))
        ;; static IP
        (println)
        (let [cur-static (when (fs/exists? (str md "/static_ip")) (slurp (str md "/static_ip")))
              br-ipcidr (iface-ip sel)
              br-gw (or (->> (:out (proc/capture-result ["ip" "route" "show" "default" "dev" sel]))
                             str/split-lines (keep #(second (re-find #"via (\S+)" %))) first)
                        (when br-ipcidr (str (str/join "." (butlast (str/split (first (str/split br-ipcidr #"/")) #"\."))) ".1")))
              example (if br-ipcidr
                        (str (str/join "." (butlast (str/split (first (str/split br-ipcidr #"/")) #"\."))) ".X/" (or (second (str/split br-ipcidr #"/")) "24"))
                        "10.56.0.5/24")
              ip-choice (prompt/choose "IP address configuration:" ["DHCP (automatic)" "Static IP"]
                                       (if cur-static "Static IP" "DHCP (automatic)"))]
          (if (str/starts-with? ip-choice "Static")
            (let [da (when cur-static (second (re-find #"address=(.*)" cur-static)))
                  dg (or (when cur-static (second (re-find #"gateway=(.*)" cur-static))) br-gw)
                  addr0 (prompt/ask (format "Enter IP address (CIDR notation, e.g. %s):" example) da)
                  _ (when (str/blank? addr0) (err-exit "Error: IP address is required for static IP configuration."))
                  addr (if (str/includes? addr0 "/") addr0
                           (let [m (or (when br-ipcidr (second (str/split br-ipcidr #"/"))) "24")]
                             (println (format "  (using /%s subnet mask)" m)) (str addr0 "/" m)))
                  gwv (prompt/ask (format "Enter gateway IP (e.g. %s):" (or br-gw "10.56.0.1")) dg)
                  _ (println (format "Static IP: %s (gateway: %s)" addr (if (str/blank? gwv) "none" gwv)))
                  _ (println)
                  [d1 d2] (prompt-dns cfg name gwv)]
              {:network network :addr addr :gw gwv :dns1 d1 :dns2 d2})
            (do (println "IP: DHCP") {:network network})))))))

;; ── lxc: host ZFS bind-mount selection (introspected from the PVE node) ───────

(defn- zfs-pools
  "ZFS pool names on the PVE node (empty if introspection fails)."
  [cfg]
  (->> (str/split-lines (pve-ssh cfg "zpool list -H -o name 2>/dev/null"))
       (map str/trim) (remove str/blank?) vec))

(defn- zfs-subvols
  "Datasets under `pool` (excluding the pool root and Proxmox-managed guest
  volumes like subvol-100-disk-0 / vm-… / base-…)."
  [cfg pool]
  (->> (str/split-lines (pve-ssh cfg (format "zfs list -H -o name -r %s 2>/dev/null" pool)))
       (map str/trim) (remove str/blank?)
       (remove #(= % pool))
       (remove #(re-find #"/(subvol|vm|base|basevol)-\d+" %))
       vec))

(defn- subvol-leaf [dataset] (last (str/split dataset #"/")))

(defn- ask-nonblank [msg]
  (loop [] (let [v (str/trim (prompt/ask msg))] (if (str/blank? v) (recur) v))))

(defn- choose-dataset
  "Pool -> existing-or-create -> dataset name. Returns the full dataset name."
  [cfg pools]
  (let [pool (prompt/choose "Select a ZFS pool to hold the shared data:" pools)
        action (prompt/choose "Shared dataset:" ["Use an existing dataset" "Create a new dataset"])]
    (if (str/starts-with? action "Use an existing")
      (let [kids (zfs-subvols cfg pool)]
        (if (empty? kids)
          (do (println (format "No datasets under '%s' yet — creating a new one." pool))
              (str pool "/" (ask-nonblank (format "New dataset name under '%s' (e.g. nas):" pool))))
          (prompt/choose "Select an existing dataset to share:" kids)))
      (str pool "/" (ask-nonblank (format "New dataset name under '%s' (e.g. nas):" pool))))))

(defn- wizard-lxc-mounts
  "Build the host ZFS bind-mount list for an LXC container by introspecting the
  PVE node's pools/datasets. Each volume mounts at /srv/<sub-volume-leaf>.
  Returns a newline-joined string of `<dataset>:/srv/<leaf>` lines (or \"\")."
  [cfg nas?]
  (println)
  (println "Host data volumes — ZFS datasets on the Proxmox host that get bind-mounted")
  (println "into this container as shared storage (NFS/Samba). This is NOT the container's")
  (println "root disk (that lives on PVE_STORAGE).")
  (let [pools (zfs-pools cfg)]
    (cond
      ;; no introspection (not a ZFS host / ssh failed): manual entry
      (empty? pools)
      (do (println "Could not list ZFS pools on the Proxmox host — enter mounts manually.")
          (loop [acc []]
            (let [spec (prompt/ask "Bind mount as <host-dataset-or-path>:<container-path> (blank to finish):")]
              (if (str/blank? spec) (str/join "\n" acc) (recur (conj acc spec))))))

      ;; non-nas containers: mounts are optional
      (and (not nas?) (not (prompt/confirm "Bind-mount a host ZFS dataset into this container?" :no)))
      ""

      :else
      (loop [acc []]
        (let [dataset (choose-dataset cfg pools)
              ctpath (str "/srv/" (subvol-leaf dataset))
              acc' (conj acc (str dataset ":" ctpath))]
          (println (format "  Share: host %s  ->  container %s" dataset ctpath))
          (if (prompt/confirm "Bind-mount another host dataset?" :no)
            (recur acc')
            (str/join "\n" acc')))))))

(defn config-vm-interactive
  "Interactive machine configuration via script-wizard. Mutates the machine dir.
  from-create? skips the trailing 'just create' hint and lets create reuse config."
  [cfg name0 profile0 from-create?]
  (let [backend (:backend cfg)
        name (if (str/blank? name0)
               (let [n (prompt/ask "Enter VM name:")]
                 (when (str/blank? n) (err-exit "Error: VM name is required."))
                 n)
               name0)
        md (machine/machine-dir cfg name)
        reconfigure? (fs/directory? md)]
    (when reconfigure?
      (println (format "Machine config already exists: %s" md))
      (when-not (prompt/confirm "Reconfigure this VM?" :no)
        (if from-create?
          (do (println "Using existing config.") (System/exit 0))
          (do (println "Aborted.") (System/exit 0)))))
    (let [cur-profile (or (machine/read-field cfg name "profile") "")
          cur-memory (or (machine/read-field cfg name "memory") "")
          cur-vcpus (or (machine/read-field cfg name "vcpus") "")
          cur-var (or (machine/read-field cfg name "var_size") "")
          cur-net (or (machine/read-field cfg name "network") "")
          ;; ── mutable mode ──
          lxc? (= backend "proxmox-lxc")
          _ (when-not lxc? (println))
          mode-idx (cond (str/includes? (str "," cur-profile ",") ",semi-mutable,") 1
                         (str/includes? (str "," cur-profile ",") ",mutable,") 2
                         :else 0)
          ;; LXC is mutable-only and the image is made mutable by the builder
          ;; (vm.container), so there is no mode picker and no "mutable" token.
          mode-choice (if lxc?
                        "Mutable (LXC container)"
                        (choose-d "Select VM mode:"
                                  ["Immutable (read-only root, upgradeable, recommended)"
                                   "Semi-mutable (read-only root + writable /nix overlay)"
                                   "Mutable (read-write pet VM, use nixos-rebuild)"]
                                  mode-idx))
          mutable-profile (cond lxc? ""
                                (str/starts-with? mode-choice "Mutable") "mutable"
                                (str/starts-with? mode-choice "Semi-mutable") "semi-mutable"
                                :else "")
          _ (when-not lxc? (println (format "Mode: %s" mode-choice)))
          ;; lxc-only profiles (nas) are hidden on KVM backends; kernel-bound
          ;; profiles can't run in a container.
          avail (let [a (available-profiles cfg)]
                  (if lxc?
                    (remove #{"nvidia" "pipewire" "zram"} a)
                    (remove profile/lxc-only-profiles a)))
          ;; ── profile(s) ──
          profile
          (if-not (str/blank? profile0)
            profile0
            (do (println)
                (let [defaults (->> (str/split cur-profile #",")
                                    (map str/trim)
                                    (remove #{"" "core" "mutable" "semi-mutable"})
                                    vec)
                      sel (if (seq defaults)
                            (prompt/select "Select profile(s) to include:" avail defaults)
                            (prompt/select "Select profile(s) to include:" avail))]
                  (if (empty? sel) "core" (str/join "," sel)))))
          profile (if (str/blank? mutable-profile) profile (str profile "," mutable-profile))
          _ (println (format "Selected profile(s): %s" profile))
          ;; ── lxc: privileged + host ZFS bind mounts ──
          nas? (and lxc? (boolean (some #(= % "nas") (str/split profile #","))))
          privileged (when lxc?
                       (if nas?
                         (do (println "Privileged: yes (required by the nas profile for kernel NFS)") "1")
                         (if (prompt/confirm "Run as a privileged container? (needed for kernel NFS)" :no) "1" "0")))
          mounts (when lxc? (wizard-lxc-mounts cfg nas?))
          ;; ── memory ──
          _ (println)
          mem-opts ["1G" "2G" "4G" "8G" "16G" "32G" "Custom"]
          mem-idx (case cur-memory "1024" 0 "2048" 1 "4096" 2 "8192" 3 "16384" 4 "32768" 5
                        (if (str/blank? cur-memory) nil 6))
          mem-choice (choose-d "Select memory size:" mem-opts mem-idx)
          memory (case mem-choice
                   "1G" "1024" "2G" "2048" "4G" "4096" "8G" "8192" "16G" "16384" "32G" "32768"
                   "Custom" (let [v (prompt/ask "Enter memory in MB (e.g., 3072):" cur-memory)]
                              (if (str/blank? v) "2048" v))
                   "2048")
          _ (println (format "Memory: %sM" memory))
          ;; ── vcpus ──
          _ (println)
          vcpu-opts ["1" "2" "4" "8" "Custom"]
          vcpu-idx (case cur-vcpus "1" 0 "2" 1 "4" 2 "8" 3 (if (str/blank? cur-vcpus) nil 4))
          vcpu-choice (choose-d "Select number of vCPUs:" vcpu-opts vcpu-idx)
          vcpus (case vcpu-choice
                  "1" "1" "2" "2" "4" "4" "8" "8"
                  "Custom" (let [v (prompt/ask "Enter number of vCPUs:" cur-vcpus)]
                             (if (str/blank? v) "2" v))
                  "2")
          _ (println (format "vCPUs: %s" vcpus))
          ;; ── disk ──
          _ (println)
          disk-opts ["20G" "30G" "50G" "100G" "200G" "500G" "Custom"]
          disk-idx (case cur-var "20G" 0 "30G" 1 "50G" 2 "100G" 3 "200G" 4 "500G" 5
                         (if (str/blank? cur-var) nil 6))
          disk-choice (choose-d "Select /var disk size:" disk-opts disk-idx)
          var-size (case disk-choice
                     "20G" "20G" "30G" "30G" "50G" "50G" "100G" "100G" "200G" "200G" "500G" "500G"
                     "Custom" (let [v (prompt/ask "Enter disk size (e.g., 40G):" cur-var)]
                                (if (str/blank? v) "30G" v))
                     "30G")
          _ (println (format "Disk size: %s" var-size))
          ;; ── PCI passthrough (moonshine-nvidia only, proxmox KVM only) ──
          moonshine? (boolean (some #(= % "moonshine-nvidia")
                                    (map str/trim (str/split (or profile "") #","))))
          pci-selected
          (when (and moonshine? (= backend "proxmox"))
            (println)
            (println "PCI passthrough (moonshine-nvidia requires a discrete NVIDIA GPU):")
            (let [devs (pve-list-display-pci cfg)]
              (cond
                (empty? devs)
                (do (println (str "  No display-class PCI devices found on " (or (:pve-node cfg) "PVE")
                                  " (or query failed)."))
                    (println (format "  Edit %s/pci_devices by hand after creation." md))
                    nil)
                :else
                (let [labels (mapv :label devs)
                      ;; Default-preselect display-class devices only; users can
                      ;; add or remove the audio sibling(s) themselves.
                      default (->> devs
                                   (filter #(seq (:group %)))  ;; always allowed to preselect
                                   (mapv :label))
                      picks (if (seq default)
                              (prompt/select "Select PCI devices to pass through:" labels default)
                              (prompt/select "Select PCI devices to pass through:" labels))
                      ids (->> picks
                               (map (fn [lbl]
                                      (some #(when (= (:label %) lbl) (:id %)) devs)))
                               (remove nil?)
                               vec)]
                  (println (if (seq ids)
                             (format "PCI passthrough: %s" (str/join ", " ids))
                             "PCI passthrough: (none — edit pci_devices to add later)"))
                  ids))))
          ;; ── network ──
          _ (println)
          net-result (if (#{"proxmox" "proxmox-lxc"} backend)
                       (wizard-network-proxmox cfg name md cur-net)
                       (wizard-network-libvirt cfg name md cur-net))
          network (:network net-result)
          sip-addr (:addr net-result) sip-gw (:gw net-result)
          sip-dns1 (:dns1 net-result) sip-dns2 (:dns2 net-result)
          ;; ── SSH keys ──
          _ (println)
          agent-count (let [r (proc/capture-result ["ssh-add" "-L"])]
                        (if (zero? (:exit r)) (count (remove str/blank? (str/split-lines (:out r)))) 0))
          has-existing? (and reconfigure?
                             (let [f (str md "/admin_authorized_keys")]
                               (and (fs/exists? f)
                                    (pos? (->> (str/split-lines (slurp f))
                                               (remove #(or (str/starts-with? % "#") (str/blank? %)))
                                               count)))))
          ssh-choice (cond
                       has-existing?
                       (if (pos? agent-count)
                         (prompt/choose "SSH authorized keys:"
                                        ["Keep existing keys" (format "Use current SSH agent keys (%d key(s))" agent-count)
                                         "Enter keys manually" "Skip (no SSH access)"] "Keep existing keys")
                         (prompt/choose "SSH authorized keys:"
                                        ["Keep existing keys" "Enter keys manually" "Skip (no SSH access)"] "Keep existing keys"))
                       (pos? agent-count)
                       (prompt/choose "SSH authorized keys:"
                                      [(format "Use current SSH agent keys (%d key(s))" agent-count)
                                       "Enter keys manually" "Skip (no SSH access)"])
                       :else
                       (prompt/choose "SSH authorized keys:" ["Enter keys manually" "Skip (no SSH access)"]))
          ssh-mode (cond
                     (str/starts-with? ssh-choice "Keep existing keys") "keep"
                     (str/starts-with? ssh-choice "Use current SSH agent keys") "agent"
                     (str/starts-with? ssh-choice "Enter keys manually") "manual"
                     (str/starts-with? ssh-choice "Skip") "skip"
                     :else "keep")
          clean-keys (fn [s] (->> (str/split-lines (or s ""))
                                  (remove #(or (str/starts-with? % "#") (str/blank? %)))
                                  (str/join "\n")))
          [admin-keys user-keys]
          (if (= ssh-mode "manual")
            (do (println)
                (println "Enter SSH public key(s) for 'admin' (has sudo access):")
                (println "(Paste key(s), one per line, then press Ctrl+D to finish)")
                (let [ak (clean-keys (slurp *in*))]
                  (println)
                  (let [same (prompt/choose "User account SSH keys:"
                                            ["Same as admin" "Enter different keys" "No user SSH access"])]
                    (cond
                      (str/starts-with? same "Same as admin") [ak ak]
                      (str/starts-with? same "Enter different keys")
                      (do (println)
                          (println "Enter SSH public key(s) for 'user' (no sudo access):")
                          (println "(Paste key(s), one per line, then press Ctrl+D to finish)")
                          [ak (clean-keys (slurp *in*))])
                      :else [ak ""]))))
            [nil nil])
          ;; ── proxmox VMID ──
          pve-vmid (when (#{"proxmox" "proxmox-lxc"} backend)
                     (if (fs/exists? (str md "/vmid"))
                       (str/trim (slurp (str md "/vmid")))
                       (do (println)
                           (println "Allocating VMID from Proxmox...")
                           (let [default-vmid (pve-ssh cfg "pvesh get /cluster/nextid")
                                 qcmd (if lxc? "pct config" "qm config")]
                             (loop []
                               (let [in (prompt/ask "Enter Proxmox VMID:" default-vmid)
                                     v (if (str/blank? in) default-vmid in)
                                     existing (-> (pve-ssh cfg (format "%s %s 2>/dev/null | grep '^hostname:\\|^name:'" qcmd v))
                                                  (str/replace #"^(hostname|name): " "") str/trim)]
                                 (if (and (not (str/blank? existing)) (not= existing name))
                                   (do (println (format "VMID %s is already in use by '%s'. Choose a different ID." v existing))
                                       (recur))
                                   (do (println (format "VMID: %s" v)) v))))))))]
      ;; ── summary ──
      (println)
      (println "Configuration summary:")
      (cond
        (= backend "proxmox") (println (format "  Backend: proxmox (%s)" (or (not-empty (:pve-host cfg)) "unknown")))
        (= backend "proxmox-lxc") (println (format "  Backend: proxmox-lxc (%s)" (or (not-empty (:pve-host cfg)) "unknown")))
        :else (println (format "  Backend: libvirt (%s)" (:libvirt-uri cfg))))
      (println (format "  Name:    %s" name))
      (when pve-vmid (println (format "  VMID:    %s" pve-vmid)))
      (println (format "  Mode:    %s" (cond lxc? "mutable (lxc container)"
                                            (str/blank? mutable-profile) "immutable"
                                            :else mutable-profile)))
      (println (format "  Profile: %s" profile))
      (when lxc?
        (println (format "  Privileged: %s" (if (= privileged "1") "yes" "no")))
        (when-not (str/blank? mounts)
          (println (format "  Mounts:  %s" (str/replace mounts "\n" ", ")))))
      (println (format "  Memory:  %sM" memory))
      (println (format "  vCPUs:   %s" vcpus))
      (println (format "  Disk:    %s" var-size))
      (println (format "  Network: %s" network))
      (when (seq pci-selected)
        (println (format "  PCI:     %s" (str/join ", " pci-selected))))
      (if-not (str/blank? sip-addr)
        (do (println (format "  IP:      %s (gateway: %s)" sip-addr (if (str/blank? sip-gw) "none" sip-gw)))
            (println (format "  DNS:     %s, %s" sip-dns1 sip-dns2)))
        (println "  IP:      DHCP"))
      (println (format "  SSH:     %s" ssh-mode))
      (println)
      (when-not (prompt/confirm "Create this configuration?" :yes)
        (println "Aborted.")
        (System/exit 0))
      (when pve-vmid
        (fs/create-dirs md)
        (spit (str md "/vmid") (str pve-vmid "\n")))
      (cond
        (= ssh-mode "keep") (machine/init-machine cfg name {:profile profile :network network :ssh-key-mode "skip"})
        (= ssh-mode "manual") (machine/init-machine cfg name {:profile profile :network network
                                                              :admin-keys admin-keys :user-keys user-keys})
        :else (machine/init-machine cfg name {:profile profile :network network :ssh-key-mode ssh-mode}))
      (spit (str md "/memory") (str memory "\n"))
      (println (format "Created: %s/memory (%sM)" md memory))
      (spit (str md "/vcpus") (str vcpus "\n"))
      (println (format "Created: %s/vcpus (%s)" md vcpus))
      (when lxc?
        (spit (str md "/privileged") (str (or privileged "0") "\n"))
        (if (str/blank? mounts)
          (fs/delete-if-exists (str md "/mounts"))
          (do (spit (str md "/mounts") (str mounts "\n"))
              (println (format "Created: %s/mounts" md))))
        ;; nas: seed commented Samba users + ACL templates (all-commented = open).
        (when (and nas? (not (fs/exists? (str md "/nas_passwd"))))
          (spit (str md "/nas_passwd") nas-passwd-template)
          (fs/set-posix-file-permissions (str md "/nas_passwd") "rw-------")
          (println (format "Created: %s/nas_passwd (NAS users — edit to add credentials)" md)))
        (when (and nas? (not (fs/exists? (str md "/nas_acl"))))
          (spit (str md "/nas_acl") nas-acl-template)
          (println (format "Created: %s/nas_acl (NAS ACL — edit to grant access)" md)))
        (when (and nas? (not (fs/exists? (str md "/nfs_clients"))))
          (spit (str md "/nfs_clients") nfs-clients-template)
          (println (format "Created: %s/nfs_clients (NFS allowlist — add a CIDR to enable NFS)" md))))
      ;; PCI passthrough — overwrite the placeholder init-machine seeded when
      ;; the moonshine wizard picker actually chose devices.
      (when (and moonshine? (= backend "proxmox") (seq pci-selected))
        (spit (str md "/pci_devices")
              (str/join "\n" (concat
                              ["# Proxmox PCI passthrough — one --hostpciN entry per line."
                               "# Selected via wizard from PVE hardware/pci at create time."
                               "# Edit and `just upgrade` to change."]
                              pci-selected
                              [""])))
        (println (format "Created: %s/pci_devices (%d device(s))" md (count pci-selected))))
      (let [nvs (machine/normalize-size var-size)]
        (spit (str md "/var_size") (str nvs "\n"))
        (println (format "Created: %s/var_size (%s)" md nvs))
        (save-static-ip! cfg name sip-addr sip-gw sip-dns1 sip-dns2)
        (println)
        (println (format "VM '%s' configured (profile: %s, mode: %s, memory: %sM, vcpus: %s, var: %s)"
                         name (machine/read-field cfg name "profile")
                         (if (str/blank? mutable-profile) "immutable" mutable-profile) memory vcpus nvs))
        (when-not from-create?
          (println (format "To create the VM, run: just create %s" name)))))))
