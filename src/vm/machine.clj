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

(defn init-machine
  "Initialize a machine config directory, creating identity files if absent.
  opts: :profile :network :ssh-key-mode (\"agent\"|\"skip\"|nil) :admin-keys :user-keys."
  [cfg name {:keys [profile network ssh-key-mode admin-keys user-keys]
             :or {profile "core" network "nat"}}]
  (let [md (machine-dir cfg name)
        normalized (profile/normalize-profiles profile)]
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
    ;; tcp_ports
    (when-not (fs/exists? (str md "/tcp_ports"))
      (spit (str md "/tcp_ports")
            (str/join "\n" ["# TCP ports to open in firewall (one per line)"
                            (format "# Run 'just upgrade %s' to apply changes." name)
                            "22" "80" "443" ""]))
      (println (format "Created: %s/tcp_ports (22, 80, 443)" md)))
    ;; udp_ports
    (when-not (fs/exists? (str md "/udp_ports"))
      (spit (str md "/udp_ports")
            (str/join "\n" ["# UDP ports to open in firewall (one per line)"
                            (format "# Run 'just upgrade %s' to apply changes." name) ""]))
      (println (format "Created: %s/udp_ports (empty)" md)))
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
    (let [md (machine-dir cfg name)
          memory (save-resource! cfg name "memory" memory "2048" #(str % "M"))
          vcpus (save-resource! cfg name "vcpus" vcpus "2" str)
          var-size (save-resource! cfg name "var_size" var-size "30G" str)]
      (when-not (str/blank? static-ip)
        (write-static-ip! cfg name static-ip))
      (println)
      (println (format "VM '%s' configured (profile: %s, memory: %sM, vcpus: %s, var: %s)"
                       name (read-field cfg name "profile") memory vcpus var-size))
      (println (format "To create the VM, run: just create %s" name)))))

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
