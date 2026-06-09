#!/usr/bin/env bb
;; nixos-vm-template bootstrap
;; Create NixOS VMs from pre-built images — no local image build required.
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

;; ─── Main ───────────────────────────────────────────────────────────────────

(defn -main []
  (println)
  (println "  nixos-vm-template bootstrap")
  (println "  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
  (println)

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
          profile-info (get profiles (keyword profile-key))
          image-url (:url profile-info)
          image-sha256 (:sha256 profile-info)]

      ;; Ask for VM name
      (let [vm-name (wiz/ask "VM name:" :default "nixos")]

        ;; Backend selection
        (println)
        (let [backend (wiz/choose "Backend:" ["libvirt" "proxmox"])
              ;; Proxmox-specific settings
              pve-env (when (= backend "proxmox")
                        (let [pve-host (wiz/ask "PVE host (SSH alias or IP):")
                              pve-node (wiz/ask "PVE node name:" :default pve-host)
                              pve-storage (wiz/ask "PVE storage:" :default "local")
                              pve-bridge (wiz/ask "PVE bridge:" :default "vmbr0")]
                          {"PVE_HOST" pve-host
                           "PVE_NODE" pve-node
                           "PVE_STORAGE" pve-storage
                           "PVE_BRIDGE" pve-bridge}))]

          ;; Check dependencies before proceeding further
          (check-deps! backend)

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

            ;; Download image
            (println)
            (let [profile-dir (str repo-dir "/output/profiles/" profile-key)
                  image-path (str profile-dir "/nixos.qcow2")
                  needs-download? (atom true)]

              ;; Check if image already exists with correct checksum
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
                        (System/exit 1))))))

            ;; Create VM by sourcing the backend scripts directly (no just dependency)
            (println)
            (println (format "Creating VM '%s' with profile '%s' on %s..." vm-name profile-key backend))
            (println)
            (let [backend-script (str "backends/" backend ".sh")
                  env (merge {"SKIP_BUILD" "true"} pve-env)
                  cmd (format "source %s && create_vm_batch '%s' '%s' '%s' '%s' '%s' '%s'"
                              backend-script vm-name profile-key
                              memory vcpus var-size network)
                  result (proc/shell {:dir repo-dir :extra-env env}
                                     "bash" "-euo" "pipefail" "-c" cmd)]
              (when (not= 0 (:exit result))
                (System/exit (:exit result))))))))))

(-main)
