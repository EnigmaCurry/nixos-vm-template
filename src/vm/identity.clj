(ns vm.identity
  "Single source of truth for the per-VM identity files copied onto the /var disk.
  The same data table drives the libvirt guestfish command chain
  (backend_create_disks) and the proxmox rsync-staging + remote-chmod plan
  (backend_sync_identity)."
  (:require [babashka.fs :as fs]
            [clojure.string :as str]
            [vm.machine :as machine]))

(def identity-files
  "Identity files in the order the libvirt guestfish chain writes them.
  :mode  - octal chmod applied on the /var disk.
  :ensure :touch  - copy when non-empty, else create an empty placeholder
                    (admin/user authorized_keys are always present).
  :ensure :always - always copy, even when empty (root_password_hash).
  (default)       - copy + chmod only when the source file is non-empty.
  :filter :strip-comments - read the source, drop `#`-prefixed and blank lines,
                            and inline the remainder via `guestfish write` so
                            template files can carry `#` header commentary."
  [{:file "admin_authorized_keys" :mode "0644" :ensure :touch}
   {:file "user_authorized_keys"  :mode "0644" :ensure :touch}
   {:file "tcp_ports"   :mode "0644"}
   {:file "udp_ports"   :mode "0644"}
   {:file "resolv.conf" :mode "0644"}
   {:file "hosts"       :mode "0644"}
   {:file "static_ip"   :mode "0644"}
   {:file "ca-cert.pem" :mode "0644"}
   {:file "root_password_hash" :mode "0600" :ensure :always}
   {:file "woodpecker.env" :mode "0600"}
   {:file "samba_credentials"    :mode "0600"}
   {:file "samba_client_shares"  :mode "0644"}
   {:file "wireguard.conf"       :mode "0600"}
   {:file "wireguard.nft"        :mode "0644"}
   {:file "wg_users"             :mode "0644"}
   {:file "acme-dns.env"  :mode "0600"}
   {:file "acme-dns.json" :mode "0600"}
   {:file "ssh_host_ed25519_key"     :mode "0600" :filter :strip-comments}
   {:file "ssh_host_ed25519_key.pub" :mode "0644" :filter :strip-comments}])

(defn- non-empty-file? [path]
  (and (fs/regular-file? path) (pos? (fs/size path))))

(defn filter-key-content
  "Read `path` and return its content with `#`-prefixed and blank lines removed.
  Returns nil when nothing meaningful remains. Lets SSH host key template files
  carry `#` header commentary without confusing openssh."
  [path]
  (when (fs/regular-file? path)
    (let [body (->> (str/split-lines (slurp path))
                    (remove #(or (str/starts-with? % "#") (str/blank? %)))
                    (str/join "\n"))]
      (when-not (str/blank? body) (str body "\n")))))

(defn warn-host-key-not-synced!
  "Print a WARNING when `machines/<name>/ssh_host_ed25519_key` has real (non-
  comment) content but the caller is a sync/upgrade/clone path that won't
  apply it. SSH host keys are populated only at create/recreate time by design."
  [cfg name]
  (let [priv (str (machine/machine-dir cfg name) "/ssh_host_ed25519_key")]
    (when (filter-key-content priv)
      (println (format "WARNING: %s exists but will NOT be applied here." priv))
      (println "         SSH host keys are populated only at create/recreate time.")
      (println (format "         Run 'just recreate %s' to rotate the host key." name)))))

(defn- deploy-keys
  "Sorted seq of deploy-key files in machine-dir/deploy_keys, or nil if empty."
  [machine-dir]
  (let [d (str machine-dir "/deploy_keys")]
    (when (fs/directory? d)
      (let [files (->> (fs/list-dir d) (filter fs/regular-file?) sort)]
        (seq files)))))

;; ─── libvirt: guestfish command chain ────────────────────────────────────────

(defn- cmd
  "A single guestfish sub-command, prefixed by the ':' separator token."
  [& toks]
  (cons ":" (map str toks)))

(defn traefik-guestfish-cmds
  "Guestfish tokens to stage machines/<name>/traefik/ (if present) as a
  subdirectory of `dest-parent` on the guest. Used both for immutable
  (dest-parent=/identity) and mutable (dest-parent=/etc) paths. Idempotent:
  removes any prior tree at dest-parent/traefik first, then re-copies. Files
  get 0644, dirs 0755, all root:root."
  [machine-dir dest-parent]
  (let [src (str machine-dir "/traefik")]
    (when (fs/directory? src)
      (let [dst (str dest-parent "/traefik")
            entries (->> (fs/glob src "**") sort)]
        (concat (cmd "rm-rf" dst)
                (cmd "copy-in" src dest-parent)
                (cmd "chmod" "0755" dst)
                (cmd "chown" "0" "0" dst)
                (mapcat (fn [p]
                          (let [rel (str (fs/relativize src p))
                                d (str dst "/" rel)
                                mode (if (fs/directory? p) "0755" "0644")]
                            (concat (cmd "chmod" mode d)
                                    (cmd "chown" "0" "0" d))))
                        entries))))))

(def ^:private syncthing-files
  "Per-machine file -> {dst-name, mode} for the syncthing profile. Staged as a
  syncthing/ subdirectory of the identity dir; the profile expects them there."
  [{:src "syncthing_cert.pem" :dst "cert.pem" :mode "0600"}
   {:src "syncthing_key.pem" :dst "key.pem" :mode "0600"}
   {:src "syncthing_devices" :dst "syncthing_devices" :mode "0644"}
   {:src "syncthing_folders" :dst "syncthing_folders" :mode "0644"}])

(defn syncthing-guestfish-cmds
  "Guestfish tokens to stage the syncthing_* files (if any are present) into
  `dest-parent`/syncthing/ on the guest. Skipped entirely when no source file
  exists. Directory made 0700 (contains the private key)."
  [machine-dir dest-parent]
  (let [present (filter (fn [{:keys [src]}] (non-empty-file? (str machine-dir "/" src)))
                        syncthing-files)]
    (when (seq present)
      (let [dst-dir (str dest-parent "/syncthing")]
        (concat (cmd "mkdir-p" dst-dir)
                ;; 0755 so the (non-root) syncthing user can traverse in and
                ;; read the manifests. cert.pem / key.pem inside remain 0600.
                (cmd "chmod" "0755" dst-dir)
                (cmd "chown" "0" "0" dst-dir)
                (mapcat (fn [{:keys [src dst mode]}]
                          (let [s (str machine-dir "/" src)
                                d (str dst-dir "/" dst)]
                            (when (non-empty-file? s)
                              (concat (cmd "upload" s d)
                                      (cmd "chmod" mode d)
                                      (cmd "chown" "0" "0" d)))))
                        present))))))

(defn- identity-file-cmds
  "Guestfish tokens for one identity-table entry (copy/touch + chmod + chown).
  With `:filter :strip-comments`, the source is read on the workstation, `#`
  comment and blank lines are dropped, and the remainder is inlined via
  guestfish `write` — so template files with header commentary work."
  [machine-dir {:keys [file mode ensure filter]}]
  (let [src (str machine-dir "/" file)
        dst (str "/identity/" file)
        filtered (when (= filter :strip-comments) (filter-key-content src))
        present (if (= filter :strip-comments)
                  (some? filtered)
                  (non-empty-file? src))
        write-cmds (if (= filter :strip-comments)
                     (cmd "write" dst filtered)
                     (cmd "copy-in" src "/identity/"))]
    (case ensure
      :touch (concat (if present write-cmds (cmd "touch" dst))
                     (cmd "chmod" mode dst)
                     (cmd "chown" "0" "0" dst))
      :always (concat write-cmds
                      (cmd "chmod" mode dst)
                      (cmd "chown" "0" "0" dst))
      (when present
        (concat write-cmds
                (cmd "chmod" mode dst)
                (cmd "chown" "0" "0" dst))))))

(defn guestfish-init-cmds
  "Build the guestfish token vector (beginning at `run`) that partitions and
  formats a fresh /var disk and writes the machine identity into /identity.
  The caller prepends `-a <var-disk>` and runs guestfish on it."
  [cfg name]
  (let [machine-dir (machine/machine-dir cfg name)
        hostname (or (machine/read-field cfg name "hostname") "")
        machine-id (or (machine/read-field cfg name "machine-id") "")]
    (vec
     (concat
      ["run"]
      (cmd "part-disk" "/dev/sda" "gpt")
      (cmd "mkfs" "ext4" "/dev/sda1")
      (cmd "mount" "/dev/sda1" "/")
      (cmd "mkdir-p" "/identity")
      (cmd "write" "/identity/hostname" hostname)
      (cmd "write" "/identity/machine-id" machine-id)
      (mapcat #(identity-file-cmds machine-dir %) identity-files)
      (when-let [keys (deploy-keys machine-dir)]
        (concat (cmd "mkdir-p" "/identity/deploy_keys")
                (mapcat (fn [k]
                          (let [base (fs/file-name k)
                                dst (str "/identity/deploy_keys/" base)]
                            (concat (cmd "copy-in" (str k) "/identity/deploy_keys/")
                                    (cmd "chmod" "0600" dst)
                                    (cmd "chown" "0" "0" dst))))
                        keys)))
      (traefik-guestfish-cmds machine-dir "/identity")
      (syncthing-guestfish-cmds machine-dir "/identity")))))

(defn guestfish-sync-cmds
  "Build the guestfish token vector (beginning at `run`) that mounts an existing
  /var partition and re-writes the machine identity into /identity. Unlike the
  init chain this only copies files that are present (no touch placeholders),
  removes static_ip when absent (DHCP), and copies root_password_hash whenever
  the file exists. The caller prepends `-a <var-disk>`."
  [cfg name]
  (let [machine-dir (machine/machine-dir cfg name)
        hostname (or (machine/read-field cfg name "hostname") "")
        machine-id (or (machine/read-field cfg name "machine-id") "")
        present (fn [file mode]
                  (let [src (str machine-dir "/" file)
                        dst (str "/identity/" file)]
                    (when (non-empty-file? src)
                      (concat (cmd "copy-in" src "/identity/")
                              (cmd "chmod" mode dst)
                              (cmd "chown" "0" "0" dst)))))]
    (vec
     (concat
      ["run"]
      (cmd "mount" "/dev/sda1" "/")
      (cmd "write" "/identity/hostname" hostname)
      (cmd "write" "/identity/machine-id" machine-id)
      (present "admin_authorized_keys" "0644")
      (present "user_authorized_keys" "0644")
      (present "tcp_ports" "0644")
      (present "udp_ports" "0644")
      (present "resolv.conf" "0644")
      (present "hosts" "0644")
      (if (non-empty-file? (str machine-dir "/static_ip"))
        (concat (cmd "copy-in" (str machine-dir "/static_ip") "/identity/")
                (cmd "chmod" "0644" "/identity/static_ip")
                (cmd "chown" "0" "0" "/identity/static_ip"))
        (cmd "rm-f" "/identity/static_ip"))
      (when (fs/exists? (str machine-dir "/root_password_hash"))
        (concat (cmd "copy-in" (str machine-dir "/root_password_hash") "/identity/")
                (cmd "chmod" "0600" "/identity/root_password_hash")
                (cmd "chown" "0" "0" "/identity/root_password_hash")))
      (present "allowed_cidrs" "0644")
      (present "woodpecker.env" "0600")
      (present "samba_credentials" "0600")
      (present "samba_client_shares" "0644")
      (present "wireguard.conf" "0600")
      (present "wireguard.nft" "0644")
      (present "wg_users" "0644")
      (present "acme-dns.env" "0600")
      (present "acme-dns.json" "0600")
      (when-let [keys (deploy-keys machine-dir)]
        (concat (cmd "mkdir-p" "/identity/deploy_keys")
                (mapcat (fn [k]
                          (let [base (fs/file-name k)
                                dst (str "/identity/deploy_keys/" base)]
                            (concat (cmd "copy-in" (str k) "/identity/deploy_keys/")
                                    (cmd "chmod" "0600" dst)
                                    (cmd "chown" "0" "0" dst))))
                        keys)))
      (traefik-guestfish-cmds machine-dir "/identity")
      (syncthing-guestfish-cmds machine-dir "/identity")))))

;; ─── proxmox: rsync staging + remote chmod plan ──────────────────────────────

(def proxmox-staging-files
  "Identity files copied into the proxmox rsync staging dir. `allowed_cidrs` is
  included here. SSH host keys are excluded on purpose: they are populated only
  at create/recreate time from the identity-files table; sync-identity leaves
  the running VM's key intact."
  ["admin_authorized_keys" "user_authorized_keys" "tcp_ports" "udp_ports"
   "resolv.conf" "hosts" "root_password_hash" "static_ip" "allowed_cidrs"
   "ca-cert.pem" "woodpecker.env" "samba_credentials" "samba_client_shares"
   "wireguard.conf" "wireguard.nft" "wg_users" "acme-dns.env" "acme-dns.json"])

(defn stage-identity!
  "Populate a fresh temp dir with hostname/machine-id (no trailing newline) plus
  every present identity file and deploy_keys/. Returns the staging dir path.
  The caller rsyncs `<dir>/` to the node and removes it afterward."
  [cfg name]
  (let [machine-dir (machine/machine-dir cfg name)
        tmp (str (fs/create-temp-dir))]
    (spit (str tmp "/hostname") (or (machine/read-field cfg name "hostname") ""))
    (spit (str tmp "/machine-id") (or (machine/read-field cfg name "machine-id") ""))
    (doseq [f proxmox-staging-files]
      (let [src (str machine-dir "/" f)]
        (when (fs/exists? src) (fs/copy src (str tmp "/" f) {:replace-existing true}))))
    (when-let [keys (deploy-keys machine-dir)]
      (fs/create-dirs (str tmp "/deploy_keys"))
      (doseq [k keys]
        (fs/copy k (str tmp "/deploy_keys/" (fs/file-name k)) {:replace-existing true})))
    (let [tsrc (str machine-dir "/traefik")]
      (when (fs/directory? tsrc)
        (fs/copy-tree tsrc (str tmp "/traefik") {:replace-existing true})))
    ;; syncthing: rename cert/key + keep devices/folders under syncthing/
    (let [present (filter (fn [{:keys [src]}] (non-empty-file? (str machine-dir "/" src)))
                          syncthing-files)]
      (when (seq present)
        (fs/create-dirs (str tmp "/syncthing"))
        (doseq [{:keys [src dst]} present]
          (fs/copy (str machine-dir "/" src)
                   (str tmp "/syncthing/" dst)
                   {:replace-existing true}))))
    tmp))

(defn proxmox-perm-cmds
  "Ordered shell commands (run via pve-ssh) to fix identity perms/ownership on
  the mounted /var disk at `mount-point`."
  [mount-point]
  (let [id (str mount-point "/identity")
        chmod (fn [mode file]
                (format "chmod %s %s/%s 2>/dev/null || true" mode id file))]
    [(chmod "0644" "admin_authorized_keys")
     (chmod "0644" "user_authorized_keys")
     (chmod "0644" "hostname")
     (chmod "0644" "machine-id")
     (chmod "0644" "tcp_ports")
     (chmod "0644" "udp_ports")
     (chmod "0644" "resolv.conf")
     (chmod "0644" "hosts")
     (chmod "0644" "static_ip")
     (chmod "0600" "root_password_hash")
     (chmod "0600" "woodpecker.env")
     (chmod "0600" "samba_credentials")
     (chmod "0644" "samba_client_shares")
     (chmod "0600" "wireguard.conf")
     (chmod "0644" "wireguard.nft")
     (chmod "0644" "wg_users")
     (chmod "0600" "acme-dns.env")
     (chmod "0600" "acme-dns.json")
     (format "chmod 0700 %s/deploy_keys 2>/dev/null || true" id)
     (format "find %s/deploy_keys -type f -exec chmod 0600 {} + 2>/dev/null || true" id)
     (format "if [ -d %s/traefik ]; then find %s/traefik -type d -exec chmod 0755 {} + && find %s/traefik -type f -exec chmod 0644 {} +; fi" id id id)
     (format "if [ -d %s/syncthing ]; then chmod 0755 %s/syncthing && chmod 0600 %s/syncthing/cert.pem %s/syncthing/key.pem 2>/dev/null && chmod 0644 %s/syncthing/syncthing_devices %s/syncthing/syncthing_folders 2>/dev/null; fi || true" id id id id id id)
     (format "chown -R 0:0 %s/" id)]))
