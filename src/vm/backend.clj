(ns vm.backend
  "The backend abstraction: a protocol of the primitives each backend implements,
  plus the genuinely-shared composites (destroy/purge/recreate) and helpers
  (confirm prompts, wait-for-ip, graceful stop, the mutable-upgrade block, the
  post-create summary). Backend-divergent composites (create/clone/upgrade/
  resize/backup) live in each backend namespace and call these helpers."
  (:require [clojure.string :as str]
            [babashka.fs :as fs]
            [vm.machine :as machine]
            [vm.profile :as profile]
            [vm.net :as net]))

(defprotocol Backend
  "The 24 primitives each backend implements, plus provision!/provisioned? used
  by the shared composites. cfg is the resolved config map; name is the VM name."
  (create-disks [this cfg name var-size])
  (create-disks-mutable [this cfg name disk-size])
  (sync-identity [this cfg name])
  (generate-config [this cfg name memory vcpus])
  (define [this cfg name])
  (undefine [this cfg name])
  (start [this cfg name])
  (stop [this cfg name])
  (reboot [this cfg name])
  (force-stop [this cfg name])
  (status [this cfg name])
  (list-vms [this cfg])
  (console [this cfg name])
  (get-ip [this cfg name])
  (snapshot [this cfg name snap])
  (restore-snapshot [this cfg name snap])
  (list-snapshots [this cfg name])
  (snapshot-count [this cfg name])
  (suspend [this cfg name])
  (resume [this cfg name])
  (running? [this cfg name])
  (vm-state [this cfg name])
  (vm-version [this cfg name])
  (cleanup [this cfg name])
  ;; Composition seams used by the shared composites:
  (provision! [this cfg name var-size]
    "Create disks and bring the VM to a defined/startable state. libvirt:
    create-disks + generate-config + define; proxmox: create-disks (the qm
    shell is created inside create-disks).")
  (provisioned? [this cfg name]
    "Whether a backend object exists to stop/undefine (proxmox: a vmid file;
    libvirt: always true — its force-stop/undefine are no-ops when absent)."))

;; ─── small shared helpers ────────────────────────────────────────────────────

(defn prompt-line
  "Print a prompt (no newline) and read a line from stdin (bash `read -p`)."
  [msg]
  (print msg)
  (flush)
  (or (read-line) ""))

(defn confirm-or-abort
  "bash `read -p \"...[y/N]\"`: continue on y/yes (case-insensitive), else print
  \"Aborted.\" and exit 1."
  [prompt]
  (when-not (re-matches #"(?i)(y|yes)" (prompt-line prompt))
    (println "Aborted.")
    (System/exit 1)))

(defn just-cmd
  "The `just` invocation string for messages: BACKEND-prefixed on proxmox."
  [cfg]
  (if (= (:backend cfg) "proxmox") "BACKEND=proxmox just" "just"))

(defn validate-machine!
  "Exit with an error if the machine config dir does not exist."
  ([cfg name] (validate-machine! cfg name nil))
  ([cfg name hint]
   (when-not (machine/exists? cfg name)
     (println (format "Error: Machine config not found: %s" (machine/machine-dir cfg name)))
     (when hint (println hint))
     (System/exit 1))))

(defn remove-disks
  "rm -rf $OUTPUT_DIR/vms/<name> (the per-VM local disk directory)."
  [cfg name]
  (fs/delete-tree (str (:output-dir cfg) "/vms/" name)))

(defn wait-for-vm-ip
  "Static IP (immediately) or poll get-ip until an address appears or timeout."
  ([b cfg name] (wait-for-vm-ip b cfg name 60))
  ([b cfg name timeout]
   (let [ip (machine/vm-ip cfg name)]
     (if (not= ip "<ip>")
       ip
       (do (binding [*out* *err*] (println "Waiting for VM to obtain IP address..."))
           (loop [elapsed 0]
             (let [ip (try (get-ip b cfg name) (catch Exception _ nil))]
               (cond
                 (not (str/blank? ip)) ip
                 (>= elapsed timeout) "<ip>"
                 :else (do (Thread/sleep 2000) (recur (+ elapsed 2)))))))))))

(defn stop-graceful
  "Graceful shutdown with timeout; exit 1 if the VM is still running after."
  ([b cfg name] (stop-graceful b cfg name 60))
  ([b cfg name timeout]
   (when (running? b cfg name)
     (println (format "Attempting graceful shutdown (%ds timeout)..." timeout))
     (try (stop b cfg name) (catch Exception _ nil))
     (loop [waited 0]
       (when (and (running? b cfg name) (< waited timeout))
         (Thread/sleep 1000)
         (recur (inc waited))))
     (if (running? b cfg name)
       (do (println (format "Error: Graceful shutdown timed out after %ds." timeout))
           (println (format "VM is still running. Use 'just force-stop %s' to force stop, then retry." name))
           (System/exit 1))
       (println "VM stopped gracefully.")))))

(defn mutable-upgrade-error!
  "Print the 'cannot upgrade mutable VMs from the host' block and exit 1."
  []
  (println "Error: Cannot upgrade mutable VMs from the host.")
  (println)
  (println "Mutable VMs have a standard read-write NixOS filesystem and must be")
  (println "upgraded from inside the VM:")
  (println)
  (println "  ssh admin@<vm-ip>")
  (println "  sudo nixos-rebuild switch")
  (println)
  (println "Or to upgrade packages:")
  (println "  nix-env -u '*'")
  (println)
  (System/exit 1))

(defn print-create-summary
  "Print the post-create block: a backend-specific `headline`, then the shared
  Machine-config / SSH / mode-NOTE lines."
  [cfg name mode ip headline]
  (println)
  (println headline)
  (println (format "Machine config: %s/" (machine/machine-dir cfg name)))
  (println (format "SSH as admin (sudo): ssh admin@%s" ip))
  (println (format "SSH as user (no sudo): ssh user@%s" ip))
  (case mode
    "mutable"
    (do (println)
        (println "NOTE: This is a mutable VM with full nix toolchain.")
        (println "To rebuild/upgrade from inside the VM: sudo nixos-rebuild switch"))
    "semi-mutable"
    (do (println)
        (println "NOTE: Root is read-only. /nix is writable via overlay.")
        (println "Install packages: nix profile install nixpkgs#<package>")
        (println "Overlay is wiped on upgrade (packages must be reinstalled)."))
    nil))

(defn- maybe-deprovision!
  "Force-stop + undefine the VM. On proxmox this is gated on a vmid file (its
  primitives error without one); on libvirt it runs unconditionally."
  [b cfg name]
  (if (= (:backend cfg) "proxmox")
    (when (provisioned? b cfg name)
      (force-stop b cfg name)
      (undefine b cfg name))
    (do (force-stop b cfg name)
        (undefine b cfg name))))

;; ─── shared composites ───────────────────────────────────────────────────────

(defn destroy-vm
  "Force stop, undefine, remove disks (keeps machine config)."
  [b cfg name]
  (when-not (machine/exists? cfg name)
    (println (format "Error: No machine config found for '%s'" name))
    (System/exit 1))
  (let [suffix (if (= (:backend cfg) "proxmox") " on Proxmox" "")
        removed (if (= (:backend cfg) "proxmox") " from Proxmox" "")]
    (println (format "WARNING: This will destroy VM '%s' and delete all its disks%s." name suffix))
    (println "All data in /var and home directories will be PERMANENTLY LOST.")
    (println (format "(Machine config in %s/ will be preserved)" (machine/machine-dir cfg name)))
    (confirm-or-abort "Are you sure? [y/N] ")
    (println (format "Destroying VM: %s" name))
    (maybe-deprovision! b cfg name)
    (remove-disks cfg name)
    (cleanup b cfg name)
    (println (format "VM '%s' has been removed%s." name removed))
    (println (format "Machine config preserved: %s/" (machine/machine-dir cfg name)))
    (println (format "To also remove config: just purge %s" name))))

(defn purge-vm
  "Force stop, undefine, remove disks AND machine config."
  [b cfg name]
  (when-not (machine/exists? cfg name)
    (println (format "Error: No machine config found for '%s'" name))
    (System/exit 1))
  (println (format "WARNING: This will COMPLETELY remove VM '%s'." name))
  (println "All data in /var and home directories will be PERMANENTLY LOST.")
  (println "Machine config (SSH keys, identity) will also be deleted.")
  (confirm-or-abort "Are you sure? [y/N] ")
  (println (format "Purging VM: %s" name))
  (maybe-deprovision! b cfg name)
  (remove-disks cfg name)
  (cleanup b cfg name)
  (fs/delete-tree (machine/machine-dir cfg name))
  (println (format "VM '%s' completely removed." name)))

(defn recreate-vm
  "Recreate a VM from its existing machine config (fresh disks, preserved config)."
  [b cfg name var-size network]
  (validate-machine! cfg name (format "Use '%s create %s' for new VMs" (just-cmd cfg) name))
  (let [var-size (machine/normalize-size var-size)
        profile (machine/read-field cfg name "profile")]
    (when-not (str/blank? network)
      (net/network-config cfg name network))
    (let [current-network (or (machine/read-field cfg name "network") "nat")]
      (println (format "WARNING: This will recreate VM '%s' with a fresh start." name))
      (println "All data in /var and home directories will be PERMANENTLY LOST.")
      (println (format "(Machine config in %s/ will be preserved)" (machine/machine-dir cfg name)))
      (println (format "Profile: %s" profile))
      (println (format "Network: %s" current-network))
      (confirm-or-abort "Are you sure? [y/N] ")
      (println (format "Recreating VM '%s' with profile: %s" name profile))
      (maybe-deprovision! b cfg name)
      (profile/build-profile cfg profile)
      (remove-disks cfg name)
      (provision! b cfg name var-size)
      (start b cfg name)
      (let [ip (wait-for-vm-ip b cfg name)]
        (println)
        (println (format "VM '%s' recreated and started." name))
        (println (format "SSH as admin (sudo): ssh admin@%s" ip))
        (println (format "SSH as user (no sudo): ssh user@%s" ip))))))
