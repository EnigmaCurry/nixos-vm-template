(ns vm.backend.libvirt
  "libvirt/QEMU backend: virsh / qemu-img / guestfish / OVMF / XML templates.
  Implements the Backend protocol and the libvirt-specific composites."
  (:require [clojure.string :as str]
            [babashka.fs :as fs]
            [cheshire.core :as json]
            [vm.proc :as proc]
            [vm.machine :as machine]
            [vm.profile :as profile]
            [vm.identity :as identity]
            [vm.mutable :as mutable]
            [vm.wizard :as wizard]
            [vm.backend :as b]))

;; ─── helpers ─────────────────────────────────────────────────────────────────

(defn- vm-dir [cfg name] (str (:output-dir cfg) "/vms/" name))
(defn- virsh [cfg args] (concat (:virsh cfg) ["-c" (:libvirt-uri cfg)] args))
(defn- gf-env [cfg] {:extra-env {"LIBGUESTFS_BACKEND" (:libguestfs-backend cfg)}})

(defn- profile-image
  "Resolved nixos.qcow2 path for a (normalized) profile."
  [cfg prof]
  (str (proc/capture (concat (:readlink cfg) ["-f" (str (:output-dir cfg) "/profiles/" prof)]))
       "/nixos.qcow2"))

(defn- undefine!
  "Tolerant undefine fallback chain (silent), matching the inline form used by
  the destroy/purge/recreate/upgrade composites."
  [cfg name]
  (or (proc/run-ok? (virsh cfg ["undefine" name "--nvram" "--snapshots-metadata"]))
      (proc/run-ok? (virsh cfg ["undefine" name "--snapshots-metadata"]))
      (proc/run-ok? (virsh cfg ["undefine" name]))
      nil))

(defn- raw-define [cfg name]
  (proc/run! (virsh cfg ["define" (str (:libvirt-dir cfg) "/" name ".xml")])))

(def ^:private default-net-xml
  "<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
")

(defn- generate-config!
  "Generate the libvirt XML for a VM from the template, converting NVRAM and
  resolving disk/network/sound. memory/vcpus may be nil (read from config)."
  [cfg name memory vcpus]
  (let [md (machine/machine-dir cfg name)
        memory (or memory (machine/read-field cfg name "memory") "2048")
        vcpus (or vcpus (machine/read-field cfg name "vcpus") "2")]
    (spit (str md "/memory") (str memory "\n"))
    (spit (str md "/vcpus") (str vcpus "\n"))
    (println (format "Generating libvirt XML for: %s" name))
    (fs/create-dirs (:libvirt-dir cfg))
    (let [ovmf-vars-dest (str (proc/capture (concat (:readlink cfg) ["-f" (vm-dir cfg name)])) "/OVMF_VARS.qcow2")
          mac (machine/read-field cfg name "mac-address")]
      (when-not (fs/exists? (str md "/uuid"))
        (spit (str md "/uuid") (str (random-uuid) "\n"))
        (println (format "Generated: %s/uuid" md)))
      (let [vm-uuid (machine/read-field cfg name "uuid")
            netcfg (or (machine/read-field cfg name "network") "nat")
            [net-type net-source]
            (cond
              (= netcfg "nat") ["network" "network='default'"]
              (str/starts-with? netcfg "bridge:") ["bridge" (str "bridge='" (subs netcfg 7) "'")]
              :else (do (println (format "Error: Invalid network config '%s'" netcfg))
                        (System/exit 1)))]
        (when-not (proc/run-ok? (concat (:qemu-img cfg) ["convert" "-f" "raw" "-O" "qcow2" (:ovmf-vars cfg) ovmf-vars-dest]))
          (println (format "Warning: Could not convert OVMF_VARS to QCOW2 from %s" (:ovmf-vars cfg))))
        (let [uid (proc/capture ["id" "-u"])
              gid (proc/capture ["id" "-g"])
              sound (if (machine/pipewire? cfg name)
                      (format "    <sound model='ich9'><audio id='1'/></sound><audio id='1' type='pulseaudio' serverName='/run/user/%s/pulse/native'/>" uid)
                      "")
              repl (fn [tpl pairs] (reduce (fn [s [k v]] (str/replace s k v)) tpl pairs))
              common [["@@VM_NAME@@" name] ["@@UUID@@" vm-uuid] ["@@MEMORY@@" memory] ["@@VCPUS@@" vcpus]
                      ["@@OVMF_CODE@@" (:ovmf-code cfg)] ["@@OVMF_VARS@@" ovmf-vars-dest]
                      ["@@MAC_ADDRESS@@" mac] ["@@NETWORK_TYPE@@" net-type] ["@@NETWORK_SOURCE@@" net-source]
                      ["@@OWNER_UID@@" uid] ["@@OWNER_GID@@" gid] ["@@SOUND_DEVICES@@" sound]]]
          (if (machine/mutable? cfg name)
            (let [disk (proc/capture (concat (:readlink cfg) ["-f" (str (vm-dir cfg name) "/disk.qcow2")]))
                  tpl (slurp (str (:libvirt-dir cfg) "/template-mutable.xml"))]
              (spit (str (:libvirt-dir cfg) "/" name ".xml")
                    (repl tpl (conj common ["@@DISK@@" disk]))))
            (let [boot (proc/capture (concat (:readlink cfg) ["-f" (str (vm-dir cfg name) "/boot.qcow2")]))
                  var (proc/capture (concat (:readlink cfg) ["-f" (str (vm-dir cfg name) "/var.qcow2")]))
                  tpl (slurp (str (:libvirt-dir cfg) "/template.xml"))]
              (spit (str (:libvirt-dir cfg) "/" name ".xml")
                    (repl tpl (conj common ["@@BOOT_DISK@@" boot] ["@@VAR_DISK@@" var])))))
          (println (format "Generated: %s/%s.xml" (:libvirt-dir cfg) name)))))))

;; ─── the record ──────────────────────────────────────────────────────────────

(defrecord Libvirt []
  b/Backend
  (create-disks [this cfg name var-size]
    (let [var-size (machine/normalize-size (or var-size "30G"))
          md (machine/machine-dir cfg name)]
      (when-not (fs/directory? md)
        (println (format "Error: Machine config not found: %s" md))
        (println (format "Run 'just create %s' first" name))
        (System/exit 1))
      (let [prof (profile/normalize-profiles (machine/read-field cfg name "profile"))]
        (if (machine/mutable? cfg name)
          (b/create-disks-mutable this cfg name var-size)
          (let [img (profile-image cfg prof)]
            (println (format "Creating VM disks: %s (profile: %s)" name prof))
            (fs/create-dirs (vm-dir cfg name))
            (when-not (fs/regular-file? img)
              (println (format "Error: Profile image not found: %s" img))
              (println (format "Run 'just build %s' first" prof))
              (System/exit 1))
            (proc/run! (concat (:qemu-img cfg) ["create" "-f" "qcow2" "-b" img "-F" "qcow2" (str (vm-dir cfg name) "/boot.qcow2")]))
            (proc/run! (concat (:qemu-img cfg) ["create" "-f" "qcow2" (str (vm-dir cfg name) "/var.qcow2") var-size]))
            (println (format "Initializing /var disk with identity from %s/" md))
            (proc/run! (concat (:guestfish cfg) ["-a" (str (vm-dir cfg name) "/var.qcow2")]
                               (identity/guestfish-init-cmds cfg name))
                       (gf-env cfg))
            (let [hostname (machine/read-field cfg name "hostname")]
              (println (format "Created VM disks in %s/" (vm-dir cfg name)))
              (println (format "  boot.qcow2 (backing: %s)" img))
              (println (format "  var.qcow2 (%s, ext4)" var-size))
              (println (format "  Identity: hostname=%s" hostname))))))))

  (create-disks-mutable [_ cfg name disk-size]
    (let [disk-size (machine/normalize-size (or disk-size "30G"))
          disk (str (vm-dir cfg name) "/disk.qcow2")]
      (mutable/prepare-disk! cfg name disk-size disk)
      (let [hostname (machine/read-field cfg name "hostname")]
        (println (format "Created VM disk in %s/" (vm-dir cfg name)))
        (println (format "  disk.qcow2 (%s, standalone mutable)" disk-size))
        (println (format "  Hostname: %s" hostname))
        (println)
        (println "NOTE: This is a mutable VM. To rebuild/upgrade from inside the VM:")
        (println "  sudo nixos-rebuild switch"))))

  (sync-identity [_ cfg name]
    (let [var-disk (str (vm-dir cfg name) "/var.qcow2")]
      (when-not (fs/regular-file? var-disk)
        (println (format "Error: /var disk not found: %s" var-disk))
        (System/exit 1))
      (println (format "Syncing identity files from %s/ to /var disk" (machine/machine-dir cfg name)))
      (proc/run! (concat (:guestfish cfg) ["-a" var-disk] (identity/guestfish-sync-cmds cfg name)) (gf-env cfg))
      (println "Identity files synced.")))

  (generate-config [_ cfg name memory vcpus] (generate-config! cfg name memory vcpus))

  (define [_ cfg name]
    (println (format "Defining VM in libvirt: %s" name))
    (proc/run! (virsh cfg ["define" (str (:libvirt-dir cfg) "/" name ".xml")]))
    (println (format "VM defined. Start with: just start %s" name)))

  (undefine [_ cfg name] (undefine! cfg name))

  (start [_ cfg name]
    (let [netcfg (or (machine/read-field cfg name "network") "nat")]
      (when (= netcfg "nat")
        (when-not (proc/run-ok? (virsh cfg ["net-info" "default"]))
          (println "Defining default NAT network...")
          (let [tmp (str (fs/create-temp-file {:prefix "libvirt-default-net" :suffix ".xml"}))]
            (spit tmp default-net-xml)
            (proc/run! (virsh cfg ["net-define" tmp]))
            (fs/delete-if-exists tmp)))
        (proc/run-ok? (virsh cfg ["net-start" "default"]))
        (proc/run-ok? (virsh cfg ["net-autostart" "default"]))))
    (println (format "Starting VM: %s" name))
    (proc/run! (virsh cfg ["start" name])))

  (stop [_ cfg name]
    (println (format "Stopping VM: %s" name))
    (proc/run! (virsh cfg ["shutdown" name])))

  (reboot [_ cfg name]
    (println (format "Rebooting VM: %s" name))
    (proc/run! (virsh cfg ["reboot" name])))

  (force-stop [_ cfg name]
    (println (format "Force stopping VM: %s" name))
    (proc/run-ok? (virsh cfg ["destroy" name])))

  (status [_ cfg name]
    (proc/run! (virsh cfg ["dominfo" name]))
    (println)
    (println "IP Address(es):")
    (let [r (proc/capture-result (virsh cfg ["domifaddr" name]))]
      (if (zero? (:exit r))
        (print (:out r))
        (println "  (not available - VM may not be running or guest agent not installed)"))))

  (list-vms [_ cfg] (proc/run! (virsh cfg ["list" "--all"])))

  (console [_ cfg name] (proc/run! (virsh cfg ["console" name])))

  (get-ip [_ cfg name]
    (let [out (:out (proc/capture-result (virsh cfg ["domifaddr" name])))]
      (some (fn [line]
              (when (str/includes? line "ipv4")
                (let [cols (str/split (str/trim line) #"\s+")]
                  (when (>= (count cols) 4)
                    (first (str/split (nth cols 3) #"/"))))))
            (str/split-lines out))))

  (snapshot [_ cfg name snap]
    (println (format "Creating snapshot '%s' for VM '%s'..." snap name))
    (proc/run! (virsh cfg ["snapshot-create-as" name snap]))
    (println (format "Snapshot '%s' created." snap)))

  (restore-snapshot [_ cfg name snap]
    (println (format "Restoring VM '%s' to snapshot '%s'..." name snap))
    (proc/run! (virsh cfg ["snapshot-revert" name snap]))
    (println (format "VM '%s' restored to '%s'." name snap)))

  (list-snapshots [_ cfg name] (proc/run! (virsh cfg ["snapshot-list" name])))

  (snapshot-count [_ cfg name]
    (->> (str/split-lines (:out (proc/capture-result (virsh cfg ["snapshot-list" name "--name"]))))
         (remove str/blank?)
         count))

  (suspend [_ cfg name]
    (println (format "Suspending VM '%s'..." name))
    (proc/run! (virsh cfg ["suspend" name])))

  (resume [_ cfg name]
    (println (format "Resuming VM '%s'..." name))
    (proc/run-ok? (virsh cfg ["resume" name])))

  (running? [_ cfg name]
    (let [r (proc/capture-result (virsh cfg ["domstate" name]))]
      (and (zero? (:exit r)) (str/includes? (:out r) "running"))))

  (vm-state [_ cfg name]
    (let [r (proc/capture-result (virsh cfg ["domstate" name]))]
      (if-not (zero? (:exit r))
        "undefined"
        (let [s (:out r)]
          (cond (str/includes? s "running") "running"
                (str/includes? s "paused") "paused"
                :else "stopped")))))

  (vm-version [_ cfg name]
    (try
      (let [r1 (proc/capture (virsh cfg ["qemu-agent-command" name
                                         "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"cat\",\"arg\":[\"/etc/nixos-image-version\"],\"capture-output\":true}}"]))
            pid (get-in (json/parse-string r1 true) [:return :pid])]
        (when pid
          (Thread/sleep 100)
          (let [r2 (proc/capture (virsh cfg ["qemu-agent-command" name
                                             (format "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":%d}}" pid)]))
                out-data (get-in (json/parse-string r2 true) [:return :out-data])]
            (when out-data
              (str/trim (String. (.decode (java.util.Base64/getDecoder) ^String out-data)))))))
      (catch Exception _ nil)))

  (cleanup [_ cfg name] (fs/delete-if-exists (str (:libvirt-dir cfg) "/" name ".xml")))

  (provision! [this cfg name var-size]
    (b/create-disks this cfg name var-size)
    (generate-config! cfg name nil nil)
    (raw-define cfg name))

  (provisioned? [_ _cfg _name] true))

;; ─── composites ──────────────────────────────────────────────────────────────

(defn- create-summary! [cfg name profile ip]
  (let [mode (cond (machine/mutable? cfg name) "mutable"
                   (machine/semi-mutable? cfg name) "semi-mutable"
                   :else nil)
        suffix (case mode "mutable" ", mutable" "semi-mutable" ", semi-mutable" "")]
    (b/print-create-summary cfg name mode ip
                            (format "VM '%s' created and started (profile: %s%s)." name profile suffix))))

(defn- finish-create! [this cfg name]
  (let [profile (or (machine/read-field cfg name "profile") "core")
        memory (or (machine/read-field cfg name "memory") "2048")
        vcpus (or (machine/read-field cfg name "vcpus") "2")
        var-size (or (machine/read-field cfg name "var_size") "30G")]
    (profile/build-profile cfg profile)
    (b/create-disks this cfg name var-size)
    (b/generate-config this cfg name memory vcpus)
    (b/define this cfg name)
    (b/start this cfg name)
    (create-summary! cfg name profile (b/wait-for-vm-ip this cfg name))))

(defn create-vm [this cfg name]
  (when (b/running? this cfg name)
    (println (format "Error: VM '%s' is currently running. Destroy it first:" name))
    (println (format "  just destroy %s" name))
    (System/exit 1))
  (wizard/config-vm-interactive cfg name "" true)
  (finish-create! this cfg name))

(defn create-vm-batch [this cfg name profile memory vcpus var-size network static-ip]
  (machine/config-vm cfg name {:profile profile :memory memory :vcpus vcpus
                               :var-size var-size :network network :static-ip static-ip})
  (finish-create! this cfg name))

(defn- grow-cmds
  "guestfish stdin script to grow partition `part` and its ext filesystem."
  [part]
  (format "run\npart-resize /dev/sda %s -1\ne2fsck-f /dev/sda%s\nresize2fs /dev/sda%s\n" part part part))

(defn clone-vm [this cfg source dest memory vcpus network]
  (let [src-md (machine/machine-dir cfg source)
        dst-md (machine/machine-dir cfg dest)
        src-vd (vm-dir cfg source)
        dst-vd (vm-dir cfg dest)]
    (when-not (fs/directory? src-md)
      (println (format "Error: Source machine config not found: %s" src-md))
      (System/exit 1))
    (let [memory (if (str/blank? memory) (or (machine/read-field cfg source "memory") "2048") memory)
          vcpus (if (str/blank? vcpus) (or (machine/read-field cfg source "vcpus") "2") vcpus)
          mutable? (machine/mutable? cfg source)]
      (if mutable?
        (when-not (fs/regular-file? (str src-vd "/disk.qcow2"))
          (println (format "Error: Source disk not found: %s/disk.qcow2" src-vd))
          (System/exit 1))
        (when-not (fs/regular-file? (str src-vd "/var.qcow2"))
          (println (format "Error: Source /var disk not found: %s/var.qcow2" src-vd))
          (System/exit 1)))
      (let [state (or (:out (proc/capture-result (virsh cfg ["domstate" source]))) "")
            state (str/trim state)]
        (when (and (not= state "shut off") (not (str/blank? state)) (not= state "unknown"))
          (println (format "Error: Source VM '%s' must be shut off (current state: %s)" source state))
          (println (format "Run 'just stop %s' first." source))
          (System/exit 1)))
      (when (fs/directory? dst-md)
        (println (format "Error: Destination machine config already exists: %s" dst-md))
        (System/exit 1))
      (when (fs/directory? dst-vd)
        (println (format "Error: Destination VM disks already exist: %s" dst-vd))
        (System/exit 1))
      (println (format "Cloning VM '%s' -> '%s'" source dest))
      (machine/init-machine-clone cfg source dest network)
      (fs/create-dirs dst-vd)
      (if mutable?
        (do
          (println "Copying disk...")
          (proc/run! (concat (:cp cfg) [(str src-vd "/disk.qcow2") (str dst-vd "/disk.qcow2")]))
          (let [hostname (machine/read-field cfg dest "hostname")
                machine-id (machine/read-field cfg dest "machine-id")
                nixos-dev (proc/capture (concat (:guestfish cfg) ["--ro" "-a" (str dst-vd "/disk.qcow2")])
                                        (merge {:in "run\nfindfs-label nixos\n"} (gf-env cfg)))]
            (when (str/blank? nixos-dev)
              (println "Error: Could not find nixos partition in cloned disk")
              (System/exit 1))
            (println "Updating identity in cloned disk...")
            (proc/run! (concat (:guestfish cfg) ["-a" (str dst-vd "/disk.qcow2")])
                       (merge {:in (format "run\nmount %s /\nwrite /etc/hostname \"%s\"\nwrite /etc/machine-id \"%s\"\n"
                                           nixos-dev hostname machine-id)}
                              (gf-env cfg)))))
        (do
          (println "Copying /var disk...")
          (proc/run! (concat (:cp cfg) [(str src-vd "/var.qcow2") (str dst-vd "/var.qcow2")]))
          (b/sync-identity this cfg dest)
          (println "Removing SSH host keys (will be regenerated on first boot)...")
          (proc/run! (concat (:guestfish cfg) ["-a" (str dst-vd "/var.qcow2")
                                               "run" ":" "mount" "/dev/sda1" "/"
                                               ":" "rm-f" "/identity/ssh_host_ed25519_key"
                                               ":" "rm-f" "/identity/ssh_host_ed25519_key.pub"])
                     (gf-env cfg))
          (let [prof (machine/read-field cfg dest "profile")
                img (profile-image cfg prof)]
            (when-not (fs/regular-file? img)
              (println (format "Error: Profile image not found: %s" img))
              (println (format "Run 'just build %s' first" prof))
              (System/exit 1))
            (proc/run! (concat (:qemu-img cfg) ["create" "-f" "qcow2" "-b" img "-F" "qcow2" (str dst-vd "/boot.qcow2")])))))
      (b/generate-config this cfg dest memory vcpus)
      (b/define this cfg dest)
      (println)
      (println (format "VM '%s' cloned from '%s'. Start with: just start %s" dest source dest)))))

(defn upgrade-vm [this cfg name]
  (b/validate-machine! cfg name (format "Use 'just create %s' for new VMs" name))
  (when (machine/mutable? cfg name) (b/mutable-upgrade-error!))
  (let [profile (machine/read-field cfg name "profile")
        snaps (b/snapshot-count this cfg name)]
    (when (pos? snaps)
      (println (format "WARNING: VM '%s' has %d snapshot(s) that will be DELETED:" name snaps))
      (doseq [s (->> (str/split-lines (:out (proc/capture-result (virsh cfg ["snapshot-list" name "--name"]))))
                     (remove str/blank?))]
        (println (str "  " s)))
      (println)
      (b/confirm-or-abort "Continue with upgrade and delete snapshots? [y/N] "))
    (println (format "Upgrading VM '%s' to latest %s image (preserving /var data)" name profile))
    (b/stop-graceful this cfg name)
    (undefine! cfg name)
    (profile/build-profile cfg profile {:flake-update? true})
    (b/sync-identity this cfg name)
    (when (machine/semi-mutable? cfg name)
      (println "Wiping /nix overlay (user-installed packages will need reinstalling)...")
      (proc/run! (concat (:guestfish cfg) ["-a" (str (vm-dir cfg name) "/var.qcow2")
                                           "run" ":" "mount" "/dev/sda1" "/"
                                           ":" "rm-rf" "/nix-overlay/upper" ":" "rm-rf" "/nix-overlay/work"
                                           ":" "mkdir-p" "/nix-overlay/upper" ":" "mkdir-p" "/nix-overlay/work"])
                 (gf-env cfg)))
    (let [profile-key (profile/normalize-profiles profile)
          img (profile-image cfg profile-key)]
      (fs/delete-if-exists (str (vm-dir cfg name) "/boot.qcow2"))
      (fs/delete-if-exists (str (vm-dir cfg name) "/OVMF_VARS.qcow2"))
      (proc/run! (concat (:qemu-img cfg) ["create" "-f" "qcow2" "-b" img "-F" "qcow2" (str (vm-dir cfg name) "/boot.qcow2")])))
    (generate-config! cfg name nil nil)
    (raw-define cfg name)
    (b/start this cfg name)
    (let [ip (b/wait-for-vm-ip this cfg name)]
      (println)
      (println (format "VM '%s' upgraded and started. /var data preserved." name))
      (when (machine/semi-mutable? cfg name)
        (println "NOTE: /nix overlay was wiped. Reinstall any user-added packages."))
      (println (format "SSH as admin (sudo): ssh admin@%s" ip))
      (println (format "SSH as user (no sudo): ssh user@%s" ip)))))

(defn- disk-virtual-size [cfg disk]
  (-> (proc/capture (concat (:qemu-img cfg) ["info" "--output=json" disk]))
      (json/parse-string true) :virtual-size))

(defn- numfmt-to-iec [bytes]
  (try (proc/capture ["numfmt" "--to=iec" (str bytes)]) (catch Exception _ (str bytes " bytes"))))
(defn- numfmt-from-iec [s]
  (try (parse-long (proc/capture ["numfmt" "--from=iec" s])) (catch Exception _ 0)))

(defn resize-var [this cfg name size]
  (let [new-size (machine/normalize-size size)
        mutable? (machine/mutable? cfg name)
        [disk-path disk-label part] (if mutable?
                                      [(str (vm-dir cfg name) "/disk.qcow2") "disk" "2"]
                                      [(str (vm-dir cfg name) "/var.qcow2") "/var disk" "1"])]
    (when-not (fs/regular-file? disk-path)
      (println (format "Error: %s not found: %s" disk-label disk-path))
      (System/exit 1))
    (when (b/running? this cfg name)
      (println (format "Error: VM '%s' must be stopped before resizing." name))
      (println (format "Run 'just stop %s' first." name))
      (System/exit 1))
    (let [cur-bytes (disk-virtual-size cfg disk-path)
          cur-human (numfmt-to-iec cur-bytes)
          new-bytes (numfmt-from-iec new-size)]
      (when (<= new-bytes cur-bytes)
        (println (format "Error: New size (%s) must be larger than current size (%s)" new-size cur-human))
        (println "Shrinking disks is not supported.")
        (System/exit 1))
      (println (format "Current %s size: %s" disk-label cur-human))
      (println (format "New size: %s" new-size))
      (println)
      (println "NOTE: This will resize the QCOW2 disk image.")
      (println "The filesystem inside will be grown automatically.")
      (b/confirm-or-abort "Continue? [y/N] ")
      (println (format "Resizing %s..." disk-label))
      (proc/run! (concat (:qemu-img cfg) ["resize" disk-path new-size]))
      (println "Growing partition and filesystem...")
      (proc/run! (concat (:guestfish cfg) ["-a" disk-path]) (merge {:in (grow-cmds part)} (gf-env cfg)))
      (println)
      (println (format "Resize complete. Start VM with: just start %s" name)))))

(defn resize-vm [this cfg name]
  (b/validate-machine! cfg name)
  (when (b/running? this cfg name)
    (println (format "Error: VM '%s' must be stopped before resizing." name))
    (println (format "Run 'just stop %s' first." name))
    (System/exit 1))
  (let [md (machine/machine-dir cfg name)
        cur-mem (or (machine/read-field cfg name "memory") "2048")
        cur-vcpus (or (machine/read-field cfg name "vcpus") "2")
        mutable? (machine/mutable? cfg name)
        [disk-path disk-label part] (if mutable?
                                      [(str (vm-dir cfg name) "/disk.qcow2") "Disk" "2"]
                                      [(str (vm-dir cfg name) "/var.qcow2") "/var" "1"])
        [cur-bytes cur-human] (if (fs/regular-file? disk-path)
                                (let [b (disk-virtual-size cfg disk-path)] [b (numfmt-to-iec b)])
                                [0 "unknown"])]
    (println (format "Current VM configuration for '%s':" name))
    (println (format "  Memory: %s MB" cur-mem))
    (println (format "  vCPUs:  %s" cur-vcpus))
    (println (format "  %s:   %s" disk-label cur-human))
    (println)
    (let [new-mem (let [v (b/prompt-line (format "New memory in MB [%s]: " cur-mem))] (if (str/blank? v) cur-mem v))
          new-vcpus (let [v (b/prompt-line (format "New vCPUs [%s]: " cur-vcpus))] (if (str/blank? v) cur-vcpus v))
          new-disk-raw (let [v (b/prompt-line (format "New %s disk size [%s]: " disk-label cur-human))]
                         (if (str/blank? v) cur-human v))
          new-disk (machine/normalize-size new-disk-raw)
          new-bytes (numfmt-from-iec new-disk)]
      (when (< new-bytes cur-bytes)
        (println (format "Error: New disk size (%s) must be >= current size (%s)" new-disk cur-human))
        (println "Shrinking disks is not supported.")
        (System/exit 1))
      (println)
      (println "New configuration:")
      (println (format "  Memory: %s MB" new-mem))
      (println (format "  vCPUs:  %s" new-vcpus))
      (println (format "  /var:   %s" new-disk))
      (b/confirm-or-abort "Apply changes? [y/N] ")
      (spit (str md "/memory") (str new-mem "\n"))
      (spit (str md "/vcpus") (str new-vcpus "\n"))
      (when (and (> new-bytes cur-bytes) (fs/regular-file? disk-path))
        (println (format "Resizing %s disk..." disk-label))
        (proc/run! (concat (:qemu-img cfg) ["resize" disk-path new-disk]))
        (println "Growing partition and filesystem...")
        (proc/run! (concat (:guestfish cfg) ["-a" disk-path]) (merge {:in (grow-cmds part)} (gf-env cfg))))
      (println "Updating VM definition...")
      (generate-config! cfg name new-mem new-vcpus)
      (raw-define cfg name)
      (println)
      (println (format "Resize complete. Start VM with: just start %s" name)))))

(defn backup-vm [this cfg name]
  (let [vd (vm-dir cfg name)
        backup-dir (str (:output-dir cfg) "/backups")
        timestamp (proc/capture ["date" "+%Y%m%d-%H%M%S"])]
    (when-not (fs/directory? vd)
      (println (format "Error: VM disks not found: %s" vd))
      (System/exit 1))
    (fs/create-dirs backup-dir)
    (let [was-running (b/running? this cfg name)]
      (when was-running (b/suspend this cfg name))
      (try
        (let [zstd? (proc/run-ok? ["bash" "-c" "command -v zstd"])
              backup-file (if zstd?
                            (str backup-dir "/" name "-" timestamp ".tar.zst")
                            (str backup-dir "/" name "-" timestamp ".tar.gz"))]
          (println (format "Creating backup: %s" backup-file))
          (println "This may take a while...")
          (if zstd?
            (proc/run! ["bash" "-c" (format "tar -C %s -cf - . | zstd -T0 -o %s" (pr-str vd) (pr-str backup-file))])
            (proc/run! ["tar" "-C" vd "-czf" backup-file "."]))
          (let [size (-> (proc/capture ["bash" "-c" (format "ls -lh %s" (pr-str backup-file))])
                         (str/split #"\s+") (nth 4))]
            (println)
            (println (format "Backup complete: %s (%s)" backup-file size))))
        (finally
          (when was-running (b/resume this cfg name)))))))

(defn restore-backup-vm [this cfg name backup-file]
  (let [vd (vm-dir cfg name)
        backup-dir (str (:output-dir cfg) "/backups")]
    (b/validate-machine! cfg name (format "The VM must be created first with 'just create %s'" name))
    (let [backup-file
          (if-not (str/blank? backup-file)
            backup-file
            (let [backups (->> (when (fs/directory? backup-dir) (fs/glob backup-dir (str name "-*.tar.*")))
                               (map str) sort vec)]
              (when (empty? backups)
                (println (format "No backups found for VM '%s' in %s/" name backup-dir))
                (System/exit 1))
              (println (format "Available backups for '%s':" name))
              (doseq [[i f] (map-indexed vector backups)]
                (let [size (-> (proc/capture ["bash" "-c" (format "ls -lh %s" (pr-str f))]) (str/split #"\s+") (nth 4))]
                  (println (format "  %d) %s (%s)" (inc i) (fs/file-name f) size))))
              (println)
              (let [sel (b/prompt-line (format "Select backup to restore [1-%d]: " (count backups)))]
                (if (and (re-matches #"[0-9]+" sel) (<= 1 (parse-long sel) (count backups)))
                  (nth backups (dec (parse-long sel)))
                  (do (println "Invalid selection.") (System/exit 1))))))]
      (when-not (fs/regular-file? backup-file)
        (println (format "Error: Backup file not found: %s" backup-file))
        (System/exit 1))
      (println (format "WARNING: This will replace all disks for VM '%s'." name))
      (println "All current data will be LOST and replaced with backup contents.")
      (println (format "Backup file: %s" backup-file))
      (b/confirm-or-abort "Are you sure? [y/N] ")
      (println (format "Stopping VM '%s'..." name))
      (b/force-stop this cfg name)
      (println "Removing existing disks...")
      (fs/delete-tree vd)
      (fs/create-dirs vd)
      (println (format "Extracting backup: %s" backup-file))
      (println "This may take a while...")
      (cond
        (str/ends-with? backup-file ".tar.zst")
        (proc/run! ["bash" "-c" (format "zstd -d -c %s | tar -C %s -xf -" (pr-str backup-file) (pr-str vd))])
        (or (str/ends-with? backup-file ".tar.gz") (str/ends-with? backup-file ".tgz"))
        (proc/run! ["tar" "-C" vd "-xzf" backup-file])
        (str/ends-with? backup-file ".tar")
        (proc/run! ["tar" "-C" vd "-xf" backup-file])
        :else
        (do (println "Error: Unknown backup format. Expected .tar.zst, .tar.gz, or .tar")
            (System/exit 1)))
      (println "Defining VM in libvirt...")
      (generate-config! cfg name nil nil)
      (proc/run-ok? (virsh cfg ["define" (str (:libvirt-dir cfg) "/" name ".xml")]))
      (println)
      (println (format "Restore complete. Start VM with: just start %s" name)))))

(defn ssh-vm [cfg input]
  (let [[ssh-user name] (if (str/includes? input "@")
                          (str/split input #"@" 2)
                          ["user" input])
        ip (b/get-ip (->Libvirt) cfg name)]
    (when (str/blank? ip)
      (println (format "Error: Could not determine IP address for VM '%s'" name))
      (println (format "Is the VM running? Check with: just status %s" name))
      (System/exit 1))
    (println (format "Connecting to %s at %s as %s..." name ip ssh-user))
    (proc/run! (concat (:ssh cfg) ["-o" "StrictHostKeyChecking=accept-new" (str ssh-user "@" ip)]))))

(defn list-backups [cfg]
  (let [backup-dir (str (:output-dir cfg) "/backups")
        files (when (fs/directory? backup-dir) (->> (fs/glob backup-dir "*.tar.*") (map str) sort))]
    (if (empty? files)
      (println (format "No backups found in %s/" backup-dir))
      (do (println (format "Available backups in %s/:" backup-dir))
          (doseq [f files]
            (let [size (-> (proc/capture ["bash" "-c" (format "ls -lh %s" (pr-str f))]) (str/split #"\s+") (nth 4))]
              (println (format "  %s (%s)" f size))))))))
