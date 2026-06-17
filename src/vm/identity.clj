(ns vm.identity
  "Single source of truth for the per-VM identity files copied onto the /var disk.
  The same data table drives the libvirt guestfish command chain
  (backend_create_disks) and the proxmox rsync-staging + remote-chmod plan
  (backend_sync_identity)."
  (:require [babashka.fs :as fs]
            [vm.machine :as machine]))

(def identity-files
  "Identity files in the order the libvirt guestfish chain writes them.
  :mode  - octal chmod applied on the /var disk.
  :ensure :touch  - copy when non-empty, else create an empty placeholder
                    (admin/user authorized_keys are always present).
  :ensure :always - always copy, even when empty (root_password_hash).
  (default)       - copy + chmod only when the source file is non-empty."
  [{:file "admin_authorized_keys" :mode "0644" :ensure :touch}
   {:file "user_authorized_keys"  :mode "0644" :ensure :touch}
   {:file "tcp_ports"   :mode "0644"}
   {:file "udp_ports"   :mode "0644"}
   {:file "resolv.conf" :mode "0644"}
   {:file "hosts"       :mode "0644"}
   {:file "static_ip"   :mode "0644"}
   {:file "ca-cert.pem" :mode "0644"}
   {:file "root_password_hash" :mode "0600" :ensure :always}
   {:file "woodpecker.env" :mode "0600"}])

(defn- non-empty-file? [path]
  (and (fs/regular-file? path) (pos? (fs/size path))))

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

(defn- identity-file-cmds
  "Guestfish tokens for one identity-table entry (copy/touch + chmod + chown)."
  [machine-dir {:keys [file mode ensure]}]
  (let [src (str machine-dir "/" file)
        dst (str "/identity/" file)
        present (non-empty-file? src)]
    (case ensure
      :touch (concat (if present (cmd "copy-in" src "/identity/") (cmd "touch" dst))
                     (cmd "chmod" mode dst)
                     (cmd "chown" "0" "0" dst))
      :always (concat (cmd "copy-in" src "/identity/")
                      (cmd "chmod" mode dst)
                      (cmd "chown" "0" "0" dst))
      (when present
        (concat (cmd "copy-in" src "/identity/")
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
                        keys)))))))

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
      (when-let [keys (deploy-keys machine-dir)]
        (concat (cmd "mkdir-p" "/identity/deploy_keys")
                (mapcat (fn [k]
                          (let [base (fs/file-name k)
                                dst (str "/identity/deploy_keys/" base)]
                            (concat (cmd "copy-in" (str k) "/identity/deploy_keys/")
                                    (cmd "chmod" "0600" dst)
                                    (cmd "chown" "0" "0" dst))))
                        keys)))))))

;; ─── proxmox: rsync staging + remote chmod plan ──────────────────────────────

(def proxmox-staging-files
  "Identity files copied into the proxmox rsync staging dir (SSH host keys are
  excluded — regenerated on first boot). Note `allowed_cidrs` is included here."
  ["admin_authorized_keys" "user_authorized_keys" "tcp_ports" "udp_ports"
   "resolv.conf" "hosts" "root_password_hash" "static_ip" "allowed_cidrs"
   "ca-cert.pem" "woodpecker.env"])

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
     (format "chmod 0700 %s/deploy_keys 2>/dev/null || true" id)
     (format "find %s/deploy_keys -type f -exec chmod 0600 {} + 2>/dev/null || true" id)
     (format "chown -R 0:0 %s/" id)]))
