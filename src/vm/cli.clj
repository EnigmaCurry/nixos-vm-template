(ns vm.cli
  "Entry point: parse [command & args], build config from the BACKEND env var,
  and dispatch. Invoked by the Justfile as `bb -m vm.cli <command> [args...]`."
  (:require [clojure.string :as str]
            [vm.config :as config]
            [vm.machine :as machine]
            [vm.proc :as proc]))

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
      (if (and (not (str/blank? ovmf)) (.exists (clojure.java.io/file ovmf)))
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

(defn -main [& args]
  (let [[command & rest] args
        backend (or (System/getenv "BACKEND") "libvirt")
        cfg (config/load-config backend)]
    (case command
      "list-machines" (cmd-list-machines cfg)
      "test-connection" (cmd-test-connection cfg)
      (do (println (format "Error: unknown command '%s'" command))
          (System/exit 1)))))
