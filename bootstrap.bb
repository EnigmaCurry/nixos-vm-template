#!/usr/bin/env bb
;; nixos-vm-template bootstrap
;; Create and manage NixOS VMs from pre-built images.
;;
;; One-liner:
;;   bb -e '(load-string (slurp "https://github.com/EnigmaCurry/nixos-vm-template/raw/refs/heads/dev/bootstrap.bb"))'
;;
;; Or from a cloned repo:
;;   bb bootstrap.bb
;;   just bootstrap

(require '[babashka.process :as proc]
         '[babashka.http-client :as http]
         '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[cheshire.core :as json])

;; ─── Constants ──────────────────────────────────────────────────────────────

(def repo-url "https://github.com/EnigmaCurry/nixos-vm-template.git")
(def default-branch "dev")
(def default-repo-dir (str (System/getenv "HOME") "/.cache/nixos-vm-template"))

(def manifest-url
  (or (System/getenv "NIXOS_MANIFEST_URL")
      "https://nixos-vm-template.nyc3.digitaloceanspaces.com/manifest.json"))

;; ─── Repo bootstrap ────────────────────────────────────────────────────────
;; When loaded from a URL, this section clones/updates the repo and re-execs
;; the local copy so the user always runs the latest version.

(defn in-repo?
  "Check if a directory has the files needed to create VMs."
  [dir]
  (and dir
       (.exists (io/file dir "Justfile"))
       (.exists (io/file dir "backends" "common.sh"))
       (.exists (io/file dir "bootstrap.bb"))))

(let [file-dir (try
                 (let [f (io/file *file*)]
                   (-> (if (.isAbsolute f) f (.getCanonicalFile f))
                       .getParentFile .getPath))
                 (catch Exception _ nil))]
  (when-not (in-repo? file-dir)
    ;; Not running from a repo checkout — clone/update, then hand off
    (let [dir default-repo-dir
          branch (or (System/getenv "NIXOS_VM_BRANCH") default-branch)]
      (if (in-repo? dir)
        (do
          (proc/shell {:dir dir :out :string :err :string}
                      "git" "fetch" "origin" branch)
          (proc/shell {:dir dir :out :string :err :string}
                      "git" "checkout" branch)
          (proc/shell {:dir dir :out :string :err :string}
                      "git" "reset" "--hard" (str "origin/" branch)))
        (do
          (.mkdirs (.getParentFile (io/file dir)))
          (proc/shell {:out :string :err :string}
                      "git" "clone" "--branch" branch repo-url dir)))
      (let [sha (str/trim (:out (proc/shell {:dir dir :out :string :err :string}
                                            "git" "rev-parse" "--short" "HEAD")))]
        (println (format "Using %s (branch: %s, commit: %s)" dir branch sha)))
      ;; Re-exec the repo's local copy (guarantees we run the latest code)
      (load-file (str dir "/bootstrap.bb"))
      (System/exit 0))))

;; ─── From here on, we are always running from within a repo checkout ───────

(require '[babashka.pods :as pods])
(pods/load-pod 'enigmacurry/script-wizard "0.3.0")
(require '[pod.enigmacurry.script-wizard :as wiz])

(def repo-dir
  (-> (io/file *file*) .getCanonicalFile .getParentFile .getPath))

;; ─── Utilities ──────────────────────────────────────────────────────────────

(defn sh
  "Run a shell command in repo dir. Throws on non-zero exit."
  [& args]
  (let [cmd (str/join " " args)]
    (proc/shell {:out :string :err :string :dir repo-dir} "bash" "-c" cmd)))

(defn sh-ok
  "Run a shell command, return stdout trimmed."
  [& args]
  (str/trim (:out (apply sh args))))

(defn sh-ok?
  "Run a shell command, return true if exit 0."
  [& args]
  (try (apply sh args) true
       (catch Exception _ false)))

(defn sh-inherit!
  "Run a shell command with inherited stdout/stderr (visible to user)."
  [& args]
  (let [cmd (str/join " " args)]
    (proc/shell {:dir repo-dir} "bash" "-c" cmd)))

(defn clear-below!
  "Clear any leftover wizard output below the cursor."
  []
  (print "\033[J")
  (flush))

(defn- env-vars
  "Strip non-string keys from an env map (keeps only real env vars)."
  [env]
  (into {} (filter (fn [[k _]] (string? k)) env)))

(defn backend-sh!
  "Run a bash command with the backend sourced. Returns process result."
  [backend env cmd]
  (let [backend-script (str "backends/" backend ".sh")
        full-cmd (format "source %s && %s" backend-script cmd)]
    (proc/shell {:dir repo-dir :extra-env (merge {"SKIP_BUILD" "true"} (env-vars env))}
                "bash" "-euo" "pipefail" "-c" full-cmd)))

(defn backend-sh-ok
  "Run a backend command, return stdout trimmed."
  [backend env cmd]
  (let [backend-script (str "backends/" backend ".sh")
        full-cmd (format "source %s && %s" backend-script cmd)]
    (str/trim (:out (proc/shell {:dir repo-dir :out :string :err :string
                                 :extra-env (merge {"SKIP_BUILD" "true"} (env-vars env))}
                                "bash" "-euo" "pipefail" "-c" full-cmd)))))

(defn fetch-json
  "Fetch and parse JSON from a URL."
  [url]
  (let [resp (http/get url {:headers {"Accept" "application/json"}})]
    (json/parse-string (:body resp) true)))

(defn format-size
  "Format byte count as human-readable size."
  [bytes]
  (cond
    (>= bytes (* 1024 1024 1024)) (format "%.1f GB" (/ bytes (* 1024.0 1024 1024)))
    (>= bytes (* 1024 1024))      (format "%.0f MB" (/ bytes (* 1024.0 1024)))
    :else                          (format "%d bytes" bytes)))

(defn debian?
  "Check if running on Debian/Ubuntu."
  []
  (sh-ok? "test -f /etc/debian_version"))

(defn command-exists?
  "Check if a command exists on PATH."
  [cmd]
  (sh-ok? (format "command -v %s" cmd)))

;; ─── Dependency checking ────────────────────────────────────────────────────

(def libvirt-deps
  {"curl"      {:debian "curl"}
   "qemu-img"  {:debian "qemu-utils"}
   "guestfish" {:debian "libguestfs-tools"}
   "virsh"     {:debian "libvirt-clients"}
   "readlink"  {:debian "coreutils"}})

(def proxmox-deps
  {"curl"      {:debian "curl"}
   "qemu-img"  {:debian "qemu-utils"}
   "guestfish" {:debian "libguestfs-tools"}
   "ssh"       {:debian "openssh-client"}
   "rsync"     {:debian "rsync"}
   "readlink"  {:debian "coreutils"}})

(defn check-deps!
  "Check that all required commands exist. Exit with install instructions if not."
  [backend]
  (let [deps (if (= backend "proxmox") proxmox-deps libvirt-deps)
        missing (vec (filter (fn [[cmd _]] (not (command-exists? cmd))) deps))]
    (when (seq missing)
      (println)
      (println "Missing required commands:")
      (doseq [[cmd _] missing]
        (println (format "  - %s" cmd)))
      (when (debian?)
        (let [pkgs (str/join " " (distinct (map (fn [[_ info]] (:debian info)) missing)))]
          (println)
          (println "Install on Debian/Ubuntu:")
          (println (format "  sudo apt-get install %s" pkgs))))
      (println)
      (System/exit 1))))

;; ─── Machine listing ────────────────────────────────────────────────────────

(defn list-machines
  "Return a vector of {:name :profile} maps for existing machine configs."
  []
  (let [machines-dir (io/file repo-dir "machines")]
    (if (.isDirectory machines-dir)
      (->> (.listFiles machines-dir)
           (filter #(.isDirectory %))
           (mapv (fn [dir]
                   (let [name (.getName dir)
                         profile (try (str/trim (slurp (str dir "/profile")))
                                      (catch Exception _ "unknown"))]
                     {:name name :profile profile})))
           (sort-by :name))
      [])))

;; ─── Image download ─────────────────────────────────────────────────────────

(defn download-profile!
  "Download a profile image if needed. Returns the local image path."
  [profile-key profile-info]
  (let [image-url (:url profile-info)
        image-sha256 (:sha256 profile-info)
        profile-dir (str repo-dir "/output/profiles/" profile-key)
        image-path (str profile-dir "/nixos.qcow2")
        needs-download? (atom true)]

    (when (.exists (io/file image-path))
      (print "  Checking existing image... ")
      (flush)
      (let [actual (first (str/split (sh-ok (format "sha256sum '%s'" image-path)) #"\s+"))]
        (if (= actual image-sha256)
          (do (println "OK (checksum matches)")
              (reset! needs-download? false))
          (println "stale (re-downloading)"))))

    (when @needs-download?
      (.mkdirs (io/file profile-dir))
      (println (format "Downloading %s (%s)..."
                       (:filename profile-info)
                       (format-size (:size profile-info))))
      (sh-inherit! (format "curl -fL --progress-bar -o '%s' '%s'" image-path image-url))
      (print "  Verifying checksum... ")
      (flush)
      (let [actual (first (str/split (sh-ok (format "sha256sum '%s'" image-path)) #"\s+"))]
        (if (= actual image-sha256)
          (println "OK")
          (do (println "FAILED")
              (println (format "  Expected: %s" image-sha256))
              (println (format "  Actual:   %s" actual))
              (io/delete-file image-path true)
              (System/exit 1)))))
    image-path))

;; ─── PVE per-VM config ───────────────────────────────────────────────────────

(defn pve-prompt-storage-bridge
  "Prompt for PVE storage and bridge, returns env map with PVE_STORAGE, PVE_BRIDGE, PVE_DISK_FORMAT."
  [pve-env]
  (let [storage-info (:pve-storage-info pve-env)
        bridges (:pve-bridges pve-env)
        ;; Storage selection
        pve-storage (if (= 1 (count storage-info))
                      (do (println (format "  Storage: %s (%s)"
                                           (:name (first storage-info))
                                           (:type (first storage-info))))
                          (:name (first storage-info)))
                      (if (seq storage-info)
                        (let [choices (mapv #(format "%s (%s)" (:name %) (:type %)) storage-info)
                              choice (wiz/choose "PVE storage:" choices)]
                          (:name (nth storage-info (.indexOf choices choice))))
                        (wiz/ask "PVE storage:" :default "local")))
        ;; Detect disk format from storage type
        storage-type (:type (first (filter #(= (:name %) pve-storage) storage-info)))
        pve-disk-format (if (or (= storage-type "lvmthin") (= storage-type "lvm"))
                          "raw" "qcow2")
        ;; Bridge selection
        pve-bridge (if (= 1 (count bridges))
                     (do (println (format "  Bridge: %s" (first bridges)))
                         (first bridges))
                     (if (seq bridges)
                       (wiz/choose "PVE bridge:" bridges)
                       (wiz/ask "PVE bridge:" :default "vmbr0")))]
    (merge pve-env
           {"PVE_STORAGE" pve-storage
            "PVE_BRIDGE" pve-bridge
            "PVE_DISK_FORMAT" pve-disk-format})))

;; ─── Actions ────────────────────────────────────────────────────────────────

(defn action-create-vm!
  "Create a new VM from a pre-built image."
  [backend pve-env]
  ;; Fetch manifest
  (print "Fetching image manifest... ")
  (flush)
  (let [manifest (try (fetch-json manifest-url)
                      (catch Exception e
                        (println "FAILED")
                        (println (format "  %s" (.getMessage e)))
                        (System/exit 1)))
        _ (println "OK")
        profiles (:profiles manifest)
        profile-keys (vec (sort (map name (keys profiles))))]

    (when (empty? profile-keys)
      (println "No profiles available in manifest.")
      (System/exit 1))

    ;; Display available profiles
    (println)
    (doseq [k profile-keys]
      (let [p (get profiles (keyword k))]
        (println (format "  %-35s %s  commit %s  %s"
                         k (:date p) (:commit p) (format-size (:size p))))))
    (println)

    ;; Choose profile
    (let [profile-key (wiz/choose "Create VM from profile combination:" profile-keys)
          profile-info (get profiles (keyword profile-key))]

      ;; VM name
      (let [vm-name (wiz/ask "VM name:" :default "nixos")]

        ;; VM specs
        (println)
        (let [memory (wiz/ask "Memory (MB):" :default "2048")
              vcpus (wiz/ask "vCPUs:" :default "2")
              var-size (wiz/ask "/var disk size:" :default "30G")
              network (if (= backend "libvirt")
                        (let [net-choice (wiz/choose "Network:"
                                                     ["NAT (default libvirt network)"
                                                      "Bridge (specify name)"])]
                          (if (str/starts-with? net-choice "NAT")
                            "nat"
                            (str "bridge:" (wiz/ask "Bridge name:" :default "virbr0"))))
                        "nat")]

          ;; PVE per-VM config (storage, bridge, VMID)
          (let [vm-env (if (= backend "proxmox")
                         (let [env (pve-prompt-storage-bridge pve-env)
                               pve-ssh (:pve-ssh pve-env)
                               machine-dir (str repo-dir "/machines/" vm-name)]
                           ;; Pre-allocate VMID
                           (when (and pve-ssh (not (.exists (io/file machine-dir "vmid"))))
                             (let [next-id (try (pve-ssh "pvesh get /cluster/nextid")
                                                (catch Exception _ "100"))
                                   vmid (loop []
                                          (let [id (wiz/ask "VMID:" :default next-id)
                                                existing (try
                                                           (pve-ssh (format "qm config %s --current 2>/dev/null | grep '^name:' | sed 's/^name: //'" id))
                                                           (catch Exception _ ""))]
                                            (if (and (not (str/blank? existing))
                                                     (not= existing vm-name))
                                              (do (println (format "  VMID %s is already in use by VM '%s'." id existing))
                                                  (recur))
                                              id)))]
                               (.mkdirs (io/file machine-dir))
                               (spit (str machine-dir "/vmid") vmid)))
                           env)
                         pve-env)]

            ;; Download image
            (println)
            (download-profile! profile-key profile-info)

            ;; Create VM
            (println)
            (println (format "Creating VM '%s' with profile '%s' on %s..." vm-name profile-key backend))
            (println)
            (let [cmd (format "create_vm_batch '%s' '%s' '%s' '%s' '%s' '%s'"
                              vm-name profile-key memory vcpus var-size network)
                  result (backend-sh! backend vm-env cmd)]
              (when (not= 0 (:exit result))
                (System/exit (:exit result)))))))))

(defn action-manage-vms!
  "Manage existing VMs — upgrade or destroy."
  [backend pve-env]
  (let [machines (list-machines)]
    (if (empty? machines)
      (do (println "No existing VMs found.")
          (println "Use 'Create VM' to create one."))

      ;; Show machines and pick one
      (let [choices (mapv (fn [m] (format "%s (profile: %s)" (:name m) (:profile m))) machines)
            choice (wiz/choose "Select VM:" choices)
            vm-name (:name (nth machines (.indexOf choices choice)))]

        ;; Action submenu
        (clear-below!)
    (println)
        (let [action (wiz/choose (format "Action for '%s':" vm-name)
                                 ["Upgrade (new image, preserve /var data)"
                                  "Destroy (delete VM and disks, keep config)"
                                  "Purge (delete VM, disks, and config)"])]

          (cond
            ;; ── Upgrade ──
            (str/starts-with? action "Upgrade")
            (do
              ;; Fetch manifest for the latest image
              (print "\nFetching image manifest... ")
              (flush)
              (let [manifest (try (fetch-json manifest-url)
                                  (catch Exception e
                                    (println "FAILED")
                                    (println (format "  %s" (.getMessage e)))
                                    (System/exit 1)))
                    _ (println "OK")
                    ;; Read the VM's current profile
                    profile (str/trim (slurp (str repo-dir "/machines/" vm-name "/profile")))
                    profile-info (get (:profiles manifest) (keyword profile))]
                (if (nil? profile-info)
                  (do (println (format "No pre-built image available for profile '%s'." profile))
                      (println "Available profiles in manifest:")
                      (doseq [k (sort (map name (keys (:profiles manifest))))]
                        (println (format "  %s" k))))

                  (do
                    (let [vm-env (if (= backend "proxmox")
                                  (pve-prompt-storage-bridge pve-env)
                                  pve-env)]
                      (println (format "\nUpgrading '%s' to latest '%s' image..." vm-name profile))
                      (download-profile! profile profile-info)
                      (println)
                      (let [cmd (format "upgrade_vm '%s'" vm-name)
                            result (backend-sh! backend vm-env cmd)]
                        (when (not= 0 (:exit result))
                          (System/exit (:exit result))))))))))

            ;; ── Destroy ──
            (str/starts-with? action "Destroy")
            (when (wiz/confirm (format "Destroy VM '%s'? All disk data will be lost." vm-name)
                               :default :no)
              (println)
              (let [cmd (format "echo y | destroy_vm '%s'" vm-name)
                    result (backend-sh! backend pve-env cmd)]
                (when (not= 0 (:exit result))
                  (System/exit (:exit result)))))

            ;; ── Purge ──
            (str/starts-with? action "Purge")
            (when (wiz/confirm (format "Purge VM '%s'? All data AND config will be permanently deleted." vm-name)
                               :default :no)
              (println)
              (let [cmd (format "echo y | purge_vm '%s'" vm-name)
                    result (backend-sh! backend pve-env cmd)]
                (when (not= 0 (:exit result))
                  (System/exit (:exit result)))))))))))

;; ─── Main ───────────────────────────────────────────────────────────────────

(defn -main []
  (println)
  (println "  nixos-vm-template")
  (println "  ~~~~~~~~~~~~~~~~~~")
  (println)

  ;; Backend selection (first, since deps depend on it)
  (let [backend (wiz/choose "Backend:" ["libvirt" "proxmox"])
        pve-env (when (= backend "proxmox")
                  (let [ssh-hosts (try
                                   (->> (slurp (str (System/getenv "HOME") "/.ssh/config"))
                                        str/split-lines
                                        (keep #(second (re-find #"(?i)^\s*Host\s+(.+)" %)))
                                        (mapcat #(str/split % #"\s+"))
                                        (remove #(str/includes? % "*"))
                                        vec)
                                   (catch Exception _ []))
                        pve-host (wiz/ask "PVE host (SSH alias or IP):"
                                          :suggestions ssh-hosts)
                        _ (do (print (format "  Connecting to %s ... " pve-host))
                              (flush))
                        pve-ssh (fn [cmd]
                                  (str/trim (:out (proc/shell
                                                   {:out :string :err :string}
                                                   "ssh" "-o" "BatchMode=yes"
                                                   "-o" "ConnectTimeout=10"
                                                   pve-host cmd))))
                        ;; Test connection and detect node name
                        pve-node-detected (try
                                           (let [n (pve-ssh "hostname")]
                                             (println "OK")
                                             n)
                                           (catch Exception _
                                             (println "FAILED")
                                             (println (format "  Could not SSH to %s." pve-host))
                                             (println "  Ensure SSH is configured: ssh-copy-id root@<host>")
                                             (System/exit 1)))
                        _ (println (format "  Node: %s" pve-node-detected))
                        pve-node pve-node-detected
                        ;; Pre-discover storage and bridge options (prompted per VM later)
                        pve-storage-info (try
                                          (let [out (pve-ssh "pvesm status --content images 2>/dev/null | awk 'NR>1 && $3==\"active\" {print $1, $2}'")]
                                            (->> (str/split-lines out)
                                                 (remove str/blank?)
                                                 (mapv (fn [line]
                                                         (let [[name type] (str/split (str/trim line) #"\s+")]
                                                           {:name name :type type})))))
                                          (catch Exception _ []))
                        pve-bridges (try
                                     (let [out (pve-ssh "ip -br link show type bridge | awk '{print $1}'")]
                                       (vec (remove str/blank? (str/split-lines out))))
                                     (catch Exception _ []))]
                    {"PVE_HOST" pve-host
                     "PVE_NODE" pve-node
                     :pve-ssh pve-ssh
                     :pve-storage-info pve-storage-info
                     :pve-bridges pve-bridges}))]

    ;; Check dependencies
    (check-deps! backend)

    ;; Main menu
    (clear-below!)
    (println)
    (let [action (wiz/choose "What would you like to do?"
                             ["Create VM" "Manage VMs"])]
      (clear-below!)
    (println)
      (case action
        "Create VM"  (action-create-vm! backend pve-env)
        "Manage VMs" (action-manage-vms! backend pve-env)))))

(-main)
