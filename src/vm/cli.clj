(ns vm.cli
  "Entry point: parse [command & args], build config from the BACKEND env var,
  resolve the backend record, and dispatch. Invoked by the Justfile as
  `bb -m vm.cli <command> [args...]`."
  (:require [clojure.string :as str]
            [vm.config :as config]
            [vm.machine :as machine]
            [vm.profile :as profile]
            [vm.net :as net]
            [vm.wizard :as wizard]
            [vm.proc :as proc]
            [vm.backend :as b]
            [vm.backend.libvirt :as lv]
            [vm.backend.proxmox :as px]))

(defn- mk-backend [cfg]
  (case (:backend cfg)
    "libvirt" (lv/->Libvirt)
    "proxmox" (px/->Proxmox)
    (do (println (format "Error: unknown backend '%s'" (:backend cfg)))
        (System/exit 1))))

;; Per-backend composites (same names/arities in both backend namespaces).
(def ^:private composite-fns
  {"libvirt" {:create-vm lv/create-vm :create-vm-batch lv/create-vm-batch :clone-vm lv/clone-vm
              :upgrade-vm lv/upgrade-vm :resize-var lv/resize-var :resize-vm lv/resize-vm
              :backup-vm lv/backup-vm :restore-backup-vm lv/restore-backup-vm
              :ssh-vm lv/ssh-vm :list-backups lv/list-backups}
   "proxmox" {:create-vm px/create-vm :create-vm-batch px/create-vm-batch :clone-vm px/clone-vm
              :upgrade-vm px/upgrade-vm :resize-var px/resize-var :resize-vm px/resize-vm
              :backup-vm px/backup-vm :restore-backup-vm px/restore-backup-vm
              :ssh-vm px/ssh-vm :list-backups px/list-backups}})

(defn- cf [cfg k] (get-in composite-fns [(:backend cfg) k]))

(defn- arg
  "nth arg with a blank-or-missing -> default fallback."
  [args i default]
  (let [v (nth (vec args) i nil)]
    (if (str/blank? v) default v)))

;; ─── list-machines ───────────────────────────────────────────────────────────

(defn- cmd-list-machines [cfg]
  (println (format "Machine configs in %s/:" (:machines-dir cfg)))
  (let [ms (machine/list-machines cfg)]
    (if (seq ms)
      (doseq [m ms]
        (println (format "  %s (profile: %s, %s)"
                         (:name m) (:profile m) (machine/mode-of cfg (:name m)))))
      (println "  (none)"))))

;; ─── test-connection ─────────────────────────────────────────────────────────

(defn- test-connection-libvirt [cfg]
  (let [uri (:libvirt-uri cfg)
        virsh (:virsh cfg)]
    (println (format "Testing libvirt connection (%s)..." uri))
    (println)
    (when-not (proc/run-ok? (concat virsh ["-c" uri "version"]))
      (println "Libvirt connection FAILED.")
      (println)
      (println "Troubleshooting:")
      (println "  1. Ensure libvirtd is running: sudo systemctl start libvirtd")
      (println "  2. Check your user is in the libvirt group: groups $USER")
      (println (format "  3. Try: virsh -c %s version" uri))
      (System/exit 1))
    (println "Libvirt connection: OK")
    (proc/run! (concat virsh ["-c" uri "version"]))
    (println)
    (let [ovmf (:ovmf-code cfg)]
      (if (and (not (str/blank? ovmf)) (.exists (java.io.File. ^String ovmf)))
        (println (format "OVMF firmware: OK (%s)" ovmf))
        (do (println "Warning: OVMF firmware not found.")
            (println "UEFI VMs may not work. Install edk2-ovmf (Fedora) or ovmf (Debian/Ubuntu)."))))
    (if (proc/run-ok? (concat (:qemu-img cfg) ["--version"]))
      (println "qemu-img: OK")
      (println "Warning: qemu-img not found."))
    (let [gf-env {:extra-env {"LIBGUESTFS_BACKEND" (:libguestfs-backend cfg)}}]
      (if (proc/run-ok? (concat (:guestfish cfg) ["--version"]) gf-env)
        (println "guestfish: OK")
        (println "Warning: guestfish not found. Install guestfs-tools.")))
    (println)
    (println "Connection test passed.")))

(defn- test-connection-proxmox [cfg]
  (let [host (:pve-host cfg)
        ssh (:ssh cfg)]
    (when (str/blank? host)
      (println "Error: PVE_HOST is not set.")
      (println)
      (println "Set it via environment variable or .env file:")
      (println "  export PVE_HOST=pve")
      (println)
      (println "Configure SSH connection in ~/.ssh/config:")
      (println "  Host pve")
      (println "      HostName 192.168.1.100")
      (println "      User root")
      (System/exit 1))
    (println (format "Testing SSH connection to Proxmox (%s)..." host))
    (println)
    (when-not (proc/run-ok?
               (concat ssh ["-o" "BatchMode=yes" "-o" "ConnectTimeout=10"
                            "-o" "StrictHostKeyChecking=accept-new"
                            host "echo 'SSH connection: OK'"]))
      (println)
      (println "SSH connection FAILED.")
      (println)
      (println "Troubleshooting:")
      (println (format "  1. Verify SSH config in ~/.ssh/config for host '%s'" host))
      (println "  2. Ensure ssh-agent is running: eval $(ssh-agent) && ssh-add")
      (println (format "  3. Test manually: ssh %s" host))
      (System/exit 1))
    (println "SSH connection: OK")
    (println)
    (if (proc/run-ok? (concat ssh ["-o" "BatchMode=yes" host
                                   "command -v pvesh >/dev/null && echo 'Proxmox tools: OK'"]))
      (let [ver (try (proc/capture
                      (concat ssh ["-o" "BatchMode=yes" host "pveversion 2>/dev/null"]))
                     (catch Exception _ "unknown"))]
        (println (format "PVE version: %s" (if (str/blank? ver) "unknown" ver))))
      (do (println "Warning: Proxmox tools (pvesh) not found on remote host.")
          (println "This may not be a Proxmox VE node.")))
    (println)
    (println "Connection test passed.")))

(defn- cmd-test-connection [cfg]
  (case (:backend cfg)
    "libvirt" (test-connection-libvirt cfg)
    "proxmox" (test-connection-proxmox cfg)
    (do (println (format "Error: unknown backend '%s'" (:backend cfg)))
        (System/exit 1))))

;; ─── dispatch ────────────────────────────────────────────────────────────────

(defn- run [args]
  (let [[command & rest] args
        a (vec rest)
        backend (or (System/getenv "BACKEND") "libvirt")
        cfg (config/load-config backend)
        B (delay (mk-backend cfg))]
    (case command
      ;; image building
      "build"         (profile/build-profile cfg (arg a 0 "core"))
      "build-all"     (profile/build-all cfg)
      "export"        (profile/export-profile cfg (arg a 0 "core"))
      "list-profiles" (profile/list-profiles cfg)
      "clean"         (profile/clean cfg)
      "shell"         (profile/dev-shell cfg)
      ;; configuration
      "config"        (wizard/config-vm-interactive cfg (arg a 0 "") (arg a 1 "") false)
      "config-batch"  (machine/config-vm cfg (arg a 0 nil)
                                         {:profile (arg a 1 "core") :memory (arg a 2 "2048")
                                          :vcpus (arg a 3 "2") :var-size (arg a 4 "30G")
                                          :network (arg a 5 "nat") :static-ip (arg a 6 "")})
      "network-config" (net/network-config-interactive cfg (arg a 0 nil) (arg a 1 ""))
      "passwd"        (machine/set-password cfg (arg a 0 nil))
      "set-profile"   (machine/set-profile cfg (arg a 0 nil) (str/join "," (rest a)))
      "list-machines" (cmd-list-machines cfg)
      ;; lifecycle (per-backend composites)
      "create"        ((cf cfg :create-vm) @B cfg (arg a 0 nil))
      "create-batch"  ((cf cfg :create-vm-batch) @B cfg (arg a 0 nil) (arg a 1 "core")
                       (arg a 2 "2048") (arg a 3 "2") (arg a 4 "30G") (arg a 5 "nat") (arg a 6 ""))
      "clone"         ((cf cfg :clone-vm) @B cfg (arg a 0 nil) (arg a 1 nil)
                       (arg a 2 "") (arg a 3 "") (arg a 4 ""))
      "upgrade"       ((cf cfg :upgrade-vm) @B cfg (arg a 0 nil))
      "resize"        ((cf cfg :resize-vm) @B cfg (arg a 0 nil))
      "resize-var"    ((cf cfg :resize-var) @B cfg (arg a 0 nil) (arg a 1 nil))
      "backup"        ((cf cfg :backup-vm) @B cfg (arg a 0 nil))
      "restore-backup" ((cf cfg :restore-backup-vm) @B cfg (arg a 0 nil) (arg a 1 ""))
      "backups"       ((cf cfg :list-backups) cfg)
      "ssh"           ((cf cfg :ssh-vm) cfg (arg a 0 nil))
      ;; shared composites
      "destroy"       (b/destroy-vm @B cfg (arg a 0 nil))
      "purge"         (b/purge-vm @B cfg (arg a 0 nil))
      "recreate"      (b/recreate-vm @B cfg (arg a 0 nil) (arg a 1 "30G") (arg a 2 ""))
      ;; primitives
      "start"         (b/start @B cfg (arg a 0 nil))
      "stop"          (b/stop @B cfg (arg a 0 nil))
      "reboot"        (b/reboot @B cfg (arg a 0 nil))
      "force-stop"    (b/force-stop @B cfg (arg a 0 nil))
      "status"        (b/status @B cfg (arg a 0 nil))
      "list"          (b/list-vms @B cfg)
      "console"       (b/console @B cfg (arg a 0 nil))
      "snapshot"      (b/snapshot @B cfg (arg a 0 nil) (arg a 1 nil))
      "restore-snapshot" (b/restore-snapshot @B cfg (arg a 0 nil) (arg a 1 nil))
      "snapshots"     (b/list-snapshots @B cfg (arg a 0 nil))
      ;; machine-readable status queries (used by bootstrap.bb)
      "vm-states"     (doseq [n a] (println (format "%s:%s" n (b/vm-state @B cfg n))))
      "vm-versions"   (doseq [n a]
                        (let [v (b/vm-version @B cfg n)
                              commit (some->> (str/split-lines (or v ""))
                                              (keep #(second (re-find #"^commit=(.*)" %))) first)]
                          (println (format "%s:%s" n (if (str/blank? commit) "unknown" commit)))))
      "test-connection" (cmd-test-connection cfg)
      (do (println (format "Error: unknown command '%s'" command))
          (System/exit 1)))))

(defn -main [& args]
  (try
    (run args)
    (catch clojure.lang.ExceptionInfo e
      ;; A backend tool exited non-zero: its stderr already printed, so exit
      ;; cleanly with its code instead of dumping a Clojure stack trace. Other
      ;; exceptions (genuine logic bugs) still propagate with a trace.
      (if (= :babashka.process/error (:type (ex-data e)))
        (System/exit (or (:exit (ex-data e)) 1))
        (throw e)))))
