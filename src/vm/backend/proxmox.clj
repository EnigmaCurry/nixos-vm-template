(ns vm.backend.proxmox
  "Proxmox VE backend: all operations go over SSH to the PVE node (pvesh, qm,
  rsync, qemu-nbd). Implements the Backend protocol and proxmox-specific
  composites. NBD mount/unmount is wrapped in try/finally (replacing the Bash
  `trap … EXIT`)."
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

;; ─── ssh / rsync helpers ─────────────────────────────────────────────────────

(defn- validate! [cfg]
  (when (str/blank? (:pve-host cfg))
    (println "Error: PVE_HOST is not set.")
    (println "Set it via environment variable or .env file:")
    (println "  export PVE_HOST=pve")
    (println "  BACKEND=proxmox PVE_HOST=pve just create myvm")
    (println)
    (println "Configure SSH connection in ~/.ssh/config:")
    (println "  Host pve")
    (println "      HostName 192.168.1.100")
    (println "      User root")
    (System/exit 1)))

(defn- ssh-base [cfg]
  (concat (:ssh cfg) ["-o" "BatchMode=yes" "-o" "StrictHostKeyChecking=accept-new"]))

(defn- pve-ssh
  "Run a remote command, return trimmed stdout. Throws on non-zero."
  [cfg cmd]
  (validate! cfg)
  (proc/capture (concat (ssh-base cfg) [(:pve-host cfg) cmd])))

(defn- pve-ssh!
  "Run a remote command inheriting stdout/stderr (visible progress)."
  [cfg cmd]
  (validate! cfg)
  (proc/run! (concat (ssh-base cfg) [(:pve-host cfg) cmd])))

(defn- pve-ssh-soft
  "Run a remote command, ignoring failure (bash `|| true`)."
  [cfg cmd]
  (validate! cfg)
  (proc/run-ok? (concat (ssh-base cfg) [(:pve-host cfg) cmd])))

(defn- pve-rsync! [cfg src dst]
  (validate! cfg)
  (proc/run! ["rsync" "-avz" "--progress" "-e"
              "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
              src dst]))

(defn- pid-suffix [] (.pid (java.lang.ProcessHandle/current)))

(def ^:private find-nbd-cmd
  "Remote shell to print the first free /dev/nbd* device (kept literal — it runs
  on the PVE node)."
  "for dev in /sys/block/nbd*; do\n  if [ -f \"$dev/size\" ] && [ \"$(cat \"$dev/size\")\" = \"0\" ]; then\n    echo \"/dev/$(basename \"$dev\")\"\n    break\n  fi\ndone")

(defn- vmid-file [cfg name] (str (machine/machine-dir cfg name) "/vmid"))

(defn- get-vmid [cfg name]
  (let [f (vmid-file cfg name)]
    (if (fs/exists? f)
      (str/trim (slurp f))
      (do (println (format "Error: VMID not found for machine '%s'" name))
          (println (format "Expected file: %s" f))
          (println (format "Create the VM first with: BACKEND=proxmox just create %s" name))
          (System/exit 1)))))

(defn- next-vmid [cfg] (pve-ssh cfg "pvesh get /cluster/nextid"))

(defn- determine-vmid!
  "Read the VMID file, or prompt interactively (auto-allocated default), then
  persist and return it."
  [cfg name]
  (let [md (machine/machine-dir cfg name)
        f (vmid-file cfg name)
        vmid
        (if (fs/exists? f)
          (let [v (str/trim (slurp f))]
            (binding [*out* *err*] (println (format "Using existing VMID: %s" v)))
            v)
          (do (binding [*out* *err*] (println "Allocating VMID from Proxmox..."))
              (let [default-vmid (next-vmid cfg)]
                (loop []
                  (let [in (b/prompt-line (format "Enter VMID [%s]: " default-vmid))
                        v (if (str/blank? in) default-vmid in)
                        existing (try (-> (pve-ssh cfg (format "qm config %s --current 2>/dev/null | grep '^name:'" v))
                                          (str/replace #"^name: " "")
                                          str/trim)
                                      (catch Exception _ ""))]
                    (if (and (not (str/blank? existing)) (not= existing name))
                      (do (binding [*out* *err*]
                            (println (format "VMID %s is already in use by VM '%s'. Choose a different ID." v existing)))
                          (recur))
                      v))))))]
    (fs/create-dirs md)
    (spit f (str vmid "\n"))
    vmid))

;; ─── config-line parsing ─────────────────────────────────────────────────────

(defn- config-line [config prefix]
  (some #(when (str/starts-with? % (str prefix ": ")) (subs % (count (str prefix ": "))))
        (str/split-lines config)))

(defn- disk-ref [config virtio]
  (some-> (config-line config virtio) (str/split #",") first))

(defn- bridge-for [cfg name]
  (let [netcfg (or (machine/read-field cfg name "network") "nat")]
    (if (str/starts-with? netcfg "bridge:") (subs netcfg 7) (:pve-bridge cfg))))

;; ─── firewall ────────────────────────────────────────────────────────────────

(defn- port-lines [path]
  (when (fs/exists? path)
    (->> (str/split-lines (slurp path))
         (map #(str/trim (str/replace % #"#.*" "")))
         (remove str/blank?))))

(defn- sync-firewall! [cfg name]
  (let [vmid (get-vmid cfg name)
        node (:pve-node cfg)
        md (machine/machine-dir cfg name)]
    (println (format "Configuring Proxmox firewall for VM '%s' (VMID: %s)..." name vmid))
    (pve-ssh! cfg (format "pvesh set /nodes/%s/qemu/%s/firewall/options --enable 1 --policy_in DROP --policy_out ACCEPT" node vmid))
    (let [existing (try (pve-ssh cfg (format "pvesh get /nodes/%s/qemu/%s/firewall/rules --output-format json" node vmid))
                        (catch Exception _ "[]"))
          n (count (try (json/parse-string existing) (catch Exception _ [])))]
      (when (pos? n)
        (doseq [i (reverse (range n))]
          (pve-ssh-soft cfg (format "pvesh delete /nodes/%s/qemu/%s/firewall/rules/%s" node vmid i)))))
    (doseq [[proto file] [["tcp" "tcp_ports"] ["udp" "udp_ports"]]]
      (doseq [port (port-lines (str md "/" file))]
        (pve-ssh! cfg (format "pvesh create /nodes/%s/qemu/%s/firewall/rules --type in --action ACCEPT --proto %s --dport %s --enable 1"
                              node vmid proto port))))
    (pve-ssh! cfg (format "pvesh create /nodes/%s/qemu/%s/firewall/rules --type in --action ACCEPT --proto icmp --enable 1" node vmid))
    (println "Proxmox firewall configured.")))

;; ─── disk creation helpers ───────────────────────────────────────────────────

(defn- vm-dir [cfg name] (str (:vms-dir cfg) "/" name))
(defn- gf-env [cfg] {:extra-env {"LIBGUESTFS_BACKEND" (:libguestfs-backend cfg)}})

(defn- profile-image [cfg prof]
  (str (proc/capture (concat (:readlink cfg) ["-f" (str (:output-dir cfg) "/profiles/" prof)]))
       "/nixos.qcow2"))

(defn- qm-create! [cfg name vmid memory vcpus mac bridge]
  (println (format "Creating VM on Proxmox (VMID: %s, name: %s)..." vmid name))
  (pve-ssh! cfg (format (str "qm create %s --name %s --bios ovmf --machine q35 --cpu host --agent 1 "
                             "--cores %s --memory %s "
                             "--efidisk0 %s:1,efitype=4m,pre-enrolled-keys=0,format=%s "
                             "--serial0 socket --vga serial0 "
                             "--net0 virtio=%s,bridge=%s,firewall=%s")
                        vmid name vcpus memory (:pve-storage cfg) (:pve-disk-format cfg)
                        mac bridge (:pve-firewall cfg))))

;; ─── NBD mount helper ────────────────────────────────────────────────────────

(defn- with-nbd-mount
  "Connect `disk-path` via qemu-nbd, mount partition `part` (e.g. \"p1\") at a
  fresh mount point, run (f mount-point), and always unmount/disconnect after.
  Returns nil if no free nbd device (caller decides whether that is fatal)."
  [cfg disk-path part mount-prefix fatal? f]
  (let [mp (str mount-prefix "-" (pid-suffix))]
    (pve-ssh-soft cfg "modprobe nbd max_part=16 2>/dev/null || true")
    (pve-ssh cfg (format "mkdir -p %s" mp))
    (let [nbd (str/trim (pve-ssh cfg find-nbd-cmd))]
      (if (str/blank? nbd)
        (if fatal?
          (do (println "Error: No free nbd device found on PVE node") (System/exit 1))
          (do (println "Warning: No free nbd device found, skipping") nil))
        (do
          (when fatal? (println (format "Using nbd device: %s" nbd)))
          (pve-ssh cfg (format "qemu-nbd -f %s -c %s '%s'" (:pve-disk-format cfg) nbd disk-path))
          (Thread/sleep 2000)
          (pve-ssh-soft cfg (format "partprobe %s 2>/dev/null || true" nbd))
          (Thread/sleep 1000)
          (try
            (pve-ssh cfg (format "mount %s%s %s" nbd part mp))
            (f mp)
            (finally
              (pve-ssh-soft cfg (format "umount %s" mp))
              (pve-ssh-soft cfg (format "qemu-nbd -d %s" nbd))
              (pve-ssh-soft cfg (format "rmdir %s 2>/dev/null || true" mp)))))))))

;; ─── the record ──────────────────────────────────────────────────────────────

(defrecord Proxmox []
  b/Backend
  (create-disks [this cfg name var-size]
    (let [var-size (machine/normalize-size (or var-size "30G"))
          md (machine/machine-dir cfg name)]
      (when-not (fs/directory? md)
        (println (format "Error: Machine config not found: %s" md))
        (println (format "Run 'BACKEND=proxmox just create %s' first" name))
        (System/exit 1))
      (validate! cfg)
      (let [prof (profile/normalize-profiles (machine/read-field cfg name "profile"))]
        (if (machine/mutable? cfg name)
          (b/create-disks-mutable this cfg name var-size)
          (let [img (profile-image cfg prof)
                vd (vm-dir cfg name)]
            (println (format "Creating VM disks: %s (profile: %s)" name prof))
            (fs/create-dirs vd)
            (when-not (fs/regular-file? img)
              (println (format "Error: Profile image not found: %s" img))
              (println (format "Run 'just build %s' first" prof))
              (System/exit 1))
            (proc/run! (concat (:qemu-img cfg) ["create" "-f" "qcow2" "-b" img "-F" "qcow2" (str vd "/boot.qcow2")]))
            (proc/run! (concat (:qemu-img cfg) ["create" "-f" "qcow2" (str vd "/var.qcow2") var-size]))
            (println (format "Initializing /var disk with identity from %s/" md))
            (proc/run! (concat (:guestfish cfg) ["-a" (str vd "/var.qcow2")] (identity/guestfish-init-cmds cfg name)) (gf-env cfg))
            (let [vmid (determine-vmid! cfg name)
                  bridge (bridge-for cfg name)
                  mac (machine/read-field cfg name "mac-address")
                  memory (or (machine/read-field cfg name "memory") "2048")
                  vcpus (or (machine/read-field cfg name "vcpus") "2")
                  stg (:pve-staging-dir cfg)]
              (qm-create! cfg name vmid memory vcpus mac bridge)
              (println "Flattening boot disk for transfer...")
              (proc/run! (concat (:qemu-img cfg) ["convert" "-f" "qcow2" "-O" "qcow2" (str vd "/boot.qcow2") (str vd "/boot-flat.qcow2")]))
              (pve-ssh cfg (format "mkdir -p %s/%s" stg name))
              (println "Transferring boot disk to Proxmox...")
              (pve-rsync! cfg (str vd "/boot-flat.qcow2") (format "%s:%s/%s/boot.qcow2" (:pve-host cfg) stg name))
              (println "Transferring var disk to Proxmox...")
              (pve-rsync! cfg (str vd "/var.qcow2") (format "%s:%s/%s/var.qcow2" (:pve-host cfg) stg name))
              (println "Importing boot disk...")
              (pve-ssh! cfg (format "qm importdisk %s %s/%s/boot.qcow2 %s --format %s" vmid stg name (:pve-storage cfg) (:pve-disk-format cfg)))
              (println "Importing var disk...")
              (pve-ssh! cfg (format "qm importdisk %s %s/%s/var.qcow2 %s --format %s" vmid stg name (:pve-storage cfg) (:pve-disk-format cfg)))
              (println "Attaching disks and configuring boot...")
              (let [cfg-str (pve-ssh cfg (format "qm config %s" vmid))
                    boot-vol (config-line cfg-str "unused0")
                    var-vol (config-line cfg-str "unused1")]
                (when (or (str/blank? boot-vol) (str/blank? var-vol))
                  (println "Error: Could not find imported disks in VM config")
                  (println (format "Check 'qm config %s' on the Proxmox node" vmid))
                  (System/exit 1))
                (pve-ssh! cfg (format "qm set %s --virtio0 %s --virtio1 %s --boot order=virtio0" vmid boot-vol var-vol)))
              (println "Cleaning up staging files...")
              (pve-ssh cfg (format "rm -rf %s/%s" stg name))
              (fs/delete-if-exists (str vd "/boot-flat.qcow2"))
              (sync-firewall! cfg name)
              (println (format "Created VM '%s' on Proxmox (VMID: %s)" name vmid))
              (println (format "  Boot disk imported to %s" (:pve-storage cfg)))
              (println (format "  Var disk imported to %s (%s)" (:pve-storage cfg) var-size))
              (println (format "  Identity: hostname=%s" (machine/read-field cfg name "hostname")))))))))

  (create-disks-mutable [_ cfg name disk-size]
    (let [disk-size (machine/normalize-size (or disk-size "30G"))
          vd (vm-dir cfg name)
          disk (str vd "/disk.qcow2")]
      (mutable/prepare-disk! cfg name disk-size disk)
      (let [vmid (determine-vmid! cfg name)
            bridge (bridge-for cfg name)
            mac (machine/read-field cfg name "mac-address")
            memory (or (machine/read-field cfg name "memory") "2048")
            vcpus (or (machine/read-field cfg name "vcpus") "2")
            stg (:pve-staging-dir cfg)]
        (qm-create! cfg name vmid memory vcpus mac bridge)
        (pve-ssh cfg (format "mkdir -p %s/%s" stg name))
        (println "Transferring disk to Proxmox...")
        (pve-rsync! cfg disk (format "%s:%s/%s/disk.qcow2" (:pve-host cfg) stg name))
        (println "Importing disk...")
        (pve-ssh! cfg (format "qm importdisk %s %s/%s/disk.qcow2 %s --format %s" vmid stg name (:pve-storage cfg) (:pve-disk-format cfg)))
        (println "Attaching disk and configuring boot...")
        (let [disk-vol (config-line (pve-ssh cfg (format "qm config %s" vmid)) "unused0")]
          (when (str/blank? disk-vol)
            (println "Error: Could not find imported disk in VM config")
            (println (format "Check 'qm config %s' on the Proxmox node" vmid))
            (System/exit 1))
          (pve-ssh! cfg (format "qm set %s --virtio0 %s --boot order=virtio0" vmid disk-vol)))
        (println "Cleaning up staging files...")
        (pve-ssh cfg (format "rm -rf %s/%s" stg name))
        (sync-firewall! cfg name)
        (println (format "Created mutable VM '%s' on Proxmox (VMID: %s)" name vmid))
        (println (format "  Disk imported to %s (%s)" (:pve-storage cfg) disk-size))
        (println (format "  Hostname: %s" (machine/read-field cfg name "hostname")))
        (println)
        (println "NOTE: This is a mutable VM. To rebuild/upgrade from inside the VM:")
        (println "  sudo nixos-rebuild switch"))))

  (sync-identity [this cfg name]
    (let [md (machine/machine-dir cfg name)]
      (when-not (fs/directory? md)
        (println (format "Error: Machine config not found: %s" md))
        (System/exit 1))
      (validate! cfg)
      (let [vmid (get-vmid cfg name)
            was-running (b/running? this cfg name)]
        (when was-running
          (println "Stopping VM for identity sync...")
          (b/force-stop this cfg name)
          (loop [n 0] (when (and (b/running? this cfg name) (< n 30)) (Thread/sleep 1000) (recur (inc n)))))
        (println (format "Syncing identity files from %s/ to VM '%s' (VMID: %s)" md name vmid))
        (let [vm-config (pve-ssh cfg (format "qm config %s" vmid))
              var-ref (disk-ref vm-config "virtio1")]
          (when (str/blank? var-ref)
            (println (format "Error: Could not find var disk (virtio1) for VM %s" vmid))
            (System/exit 1))
          (let [var-path (pve-ssh cfg (format "pvesm path '%s'" var-ref))]
            (when (str/blank? var-path)
              (println (format "Error: Could not resolve path for volume '%s'" var-ref))
              (System/exit 1))
            (println (format "Var disk path: %s" var-path))
            (let [tmp (identity/stage-identity! cfg name)]
              (try
                (with-nbd-mount cfg var-path "p1" "/mnt/nixos-var-sync" true
                                (fn [mp]
                                  (pve-ssh cfg (format "mkdir -p %s/identity" mp))
                                  (pve-rsync! cfg (str tmp "/") (format "%s:%s/identity/" (:pve-host cfg) mp))
                                  (doseq [c (identity/proxmox-perm-cmds mp)] (pve-ssh-soft cfg c))
                                  (when-not (fs/exists? (str md "/static_ip"))
                                    (pve-ssh-soft cfg (format "rm -f %s/identity/static_ip" mp)))))
                (finally (fs/delete-tree tmp))))))
        (println "Identity files synced.")
        (sync-firewall! cfg name)
        (when was-running
          (println "Restarting VM...")
          (b/start this cfg name)))))

  (generate-config [_ cfg name memory vcpus]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)
          memory (or memory "2048")
          vcpus (or vcpus "2")]
      (spit (str (machine/machine-dir cfg name) "/memory") (str memory "\n"))
      (spit (str (machine/machine-dir cfg name) "/vcpus") (str vcpus "\n"))
      (println (format "Updating VM config on Proxmox (VMID: %s)..." vmid))
      (pve-ssh! cfg (format "qm set %s --memory %s --cores %s" vmid memory vcpus))
      (println (format "VM config updated: memory=%sMB, vcpus=%s" memory vcpus))))

  (define [_ cfg name]
    (println (format "VM '%s' is already defined on Proxmox (VMID: %s)" name (get-vmid cfg name))))

  (undefine [_ cfg name]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)]
      (println (format "Destroying VM on Proxmox (VMID: %s)..." vmid))
      (pve-ssh-soft cfg (format "qm destroy %s --destroy-unreferenced-disks 1 --purge 1" vmid))
      (fs/delete-if-exists (vmid-file cfg name))
      (println "VM removed from Proxmox.")))

  (start [_ cfg name]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)]
      (println (format "Starting VM: %s (VMID: %s)" name vmid))
      (pve-ssh! cfg (format "qm start %s" vmid))))

  (stop [_ cfg name]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)]
      (println (format "Stopping VM: %s (VMID: %s)" name vmid))
      (pve-ssh! cfg (format "qm shutdown %s" vmid))))

  (reboot [_ cfg name]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)]
      (println (format "Rebooting VM: %s (VMID: %s)" name vmid))
      (pve-ssh! cfg (format "qm reboot %s" vmid))))

  (force-stop [_ cfg name]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)]
      (println (format "Force stopping VM: %s (VMID: %s)" name vmid))
      (pve-ssh-soft cfg (format "qm stop %s" vmid))))

  (status [this cfg name]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)]
      (pve-ssh! cfg (format "qm status %s --verbose" vmid))
      (println)
      (println "IP Address(es):")
      (let [ip (b/get-ip this cfg name)]
        (if (str/blank? ip)
          (println "  (not available - VM may not be running or guest agent not responding)")
          (println ip)))))

  (list-vms [_ cfg]
    (validate! cfg)
    (let [vmids (->> (fs/glob (:machines-dir cfg) "*/vmid")
                     (map #(str/trim (slurp (str %)))) (remove str/blank?) vec)]
      (if (empty? vmids)
        (println "No managed VMs found.")
        (do
          (println (format "%-8s %-20s %-10s %s" "VMID" "NAME" "STATUS" "MEM(MB)"))
          (doseq [vmid vmids]
            (let [config (try (pve-ssh cfg (format "qm status %s --verbose" vmid)) (catch Exception _ ""))]
              (if (str/blank? config)
                (println (format "%-8s %-20s %-10s %s" vmid "(unknown)" "not found" "-"))
                (let [status (config-line config "status")
                      nm (config-line config "name")
                      maxmem (config-line config "maxmem")
                      mem (if maxmem (str (quot (parse-long (re-find #"\d+" maxmem)) 1048576)) "-")]
                  (println (format "%-8s %-20s %-10s %s" vmid (or nm "?") (or status "?") mem))))))))))

  (get-ip [_ cfg name]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)
          out (try (pve-ssh cfg (format "qm guest cmd %s network-get-interfaces" vmid)) (catch Exception _ ""))]
      (when-not (str/blank? out)
        (try
          (->> (json/parse-string out true)
               (remove #(= (:name %) "lo"))
               (mapcat :ip-addresses)
               (filter #(= (:ip-address-type %) "ipv4"))
               first :ip-address)
          (catch Exception _ nil)))))

  (console [_ cfg name]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)]
      (println (format "Connecting to console for VM '%s' (VMID: %s)..." name vmid))
      (println "(Use Ctrl+O to exit)")
      (proc/run! (concat (ssh-base cfg) [(:pve-host cfg) "-t" (format "qm terminal %s" vmid)]))))

  (snapshot [_ cfg name snap]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)]
      (println (format "Creating snapshot '%s' for VM '%s' (VMID: %s)..." snap name vmid))
      (pve-ssh! cfg (format "qm snapshot %s %s" vmid snap))
      (println (format "Snapshot '%s' created." snap))))

  (restore-snapshot [_ cfg name snap]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)]
      (println (format "Restoring VM '%s' to snapshot '%s'..." name snap))
      (pve-ssh! cfg (format "qm rollback %s %s" vmid snap))
      (println (format "VM '%s' restored to '%s'." name snap))))

  (list-snapshots [_ cfg name]
    (validate! cfg)
    (pve-ssh! cfg (format "qm listsnapshot %s" (get-vmid cfg name))))

  (snapshot-count [_ cfg name]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)
          out (try (pve-ssh cfg (format "qm listsnapshot %s" vmid)) (catch Exception _ ""))
          lines (remove str/blank? (str/split-lines out))
          current (count (filter #(str/includes? % "current") lines))]
      (- (count (remove #(re-find #"`->.*current" %) lines)) current)))

  (suspend [_ cfg name]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)]
      (println (format "Suspending VM '%s' (VMID: %s)..." name vmid))
      (pve-ssh! cfg (format "qm suspend %s" vmid))))

  (resume [_ cfg name]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)]
      (println (format "Resuming VM '%s' (VMID: %s)..." name vmid))
      (pve-ssh-soft cfg (format "qm resume %s" vmid))))

  (running? [_ cfg name]
    (validate! cfg)
    ;; Speculative check (e.g. at the top of create): a VM with no vmid file
    ;; simply isn't running — never hard-exit here.
    (let [f (vmid-file cfg name)]
      (if-not (fs/exists? f)
        false
        (let [status (try (pve-ssh cfg (format "qm status %s" (str/trim (slurp f)))) (catch Exception _ ""))]
          (str/includes? status "running")))))

  (vm-state [_ cfg name]
    (validate! cfg)
    (let [f (vmid-file cfg name)]
      (if-not (fs/exists? f)
        "undefined"
        (let [vmid (str/trim (slurp f))
              status (try (pve-ssh cfg (format "qm status %s" vmid)) (catch Exception _ ""))]
          (cond (str/includes? status "running") "running"
                (str/includes? status "paused") "paused"
                (str/includes? status "stopped") "stopped"
                :else "undefined")))))

  (vm-version [_ cfg name]
    (validate! cfg)
    (let [f (vmid-file cfg name)]
      (when (fs/exists? f)
        (let [vmid (str/trim (slurp f))]
          (try
            (let [out (pve-ssh cfg (format "qm guest exec %s -- cat /etc/nixos-image-version 2>/dev/null" vmid))]
              (:out-data (json/parse-string out true)))
            (catch Exception _ nil))))))

  (cleanup [_ cfg name]
    (fs/delete-if-exists (str (vm-dir cfg name) "/boot-flat.qcow2")))

  (provision! [this cfg name var-size]
    (b/create-disks this cfg name var-size))

  (provisioned? [_ cfg name] (fs/exists? (vmid-file cfg name))))

;; ─── proxmox-only: nix overlay wipe ──────────────────────────────────────────

(defn- wipe-nix-overlay! [cfg name]
  (let [vmid (get-vmid cfg name)
        vm-config (pve-ssh cfg (format "qm config %s" vmid))
        var-ref (disk-ref vm-config "virtio1")]
    (if (str/blank? var-ref)
      (println (format "Warning: Could not find var disk (virtio1) for VM %s, skipping overlay wipe" vmid))
      (let [var-path (pve-ssh cfg (format "pvesm path '%s'" var-ref))]
        (if (str/blank? var-path)
          (println (format "Warning: Could not resolve path for volume '%s', skipping overlay wipe" var-ref))
          (with-nbd-mount cfg var-path "p1" "/mnt/nixos-overlay-wipe" false
                          (fn [mp]
                            (pve-ssh cfg (format "rm -rf %s/nix-overlay/upper %s/nix-overlay/work" mp mp))
                            (pve-ssh cfg (format "mkdir -p %s/nix-overlay/upper %s/nix-overlay/work" mp mp))
                            (pve-ssh cfg (format "chmod 0755 %s/nix-overlay %s/nix-overlay/upper %s/nix-overlay/work" mp mp mp))
                            (println "/nix overlay wiped."))))))))

;; ─── composites ──────────────────────────────────────────────────────────────

(defn- create-summary! [cfg name profile ip]
  (let [mode (cond (machine/mutable? cfg name) "mutable"
                   (machine/semi-mutable? cfg name) "semi-mutable"
                   :else nil)
        suffix (case mode "mutable" ", mutable" "semi-mutable" ", semi-mutable" "")
        vmid (get-vmid cfg name)]
    (b/print-create-summary cfg name mode ip
                            (format "VM '%s' created and started on Proxmox (VMID: %s, profile: %s%s)."
                                    name vmid profile suffix))))

(defn- finish-create! [this cfg name]
  (let [profile (or (machine/read-field cfg name "profile") "core")
        var-size (or (machine/read-field cfg name "var_size") "30G")]
    (profile/build-profile cfg profile)
    (b/create-disks this cfg name var-size)
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

(defn clone-vm [this cfg source dest memory vcpus network]
  (let [src-md (machine/machine-dir cfg source)
        dst-md (machine/machine-dir cfg dest)]
    (validate! cfg)
    (when-not (fs/directory? src-md)
      (println (format "Error: Source machine config not found: %s" src-md))
      (System/exit 1))
    (let [memory (if (str/blank? memory) (or (machine/read-field cfg source "memory") "2048") memory)
          vcpus (if (str/blank? vcpus) (or (machine/read-field cfg source "vcpus") "2") vcpus)
          source-vmid (get-vmid cfg source)]
      (when (b/running? this cfg source)
        (println (format "Error: Source VM '%s' must be stopped before cloning." source))
        (println (format "Run 'BACKEND=proxmox just stop %s' first." source))
        (System/exit 1))
      (when (fs/directory? dst-md)
        (println (format "Error: Destination machine config already exists: %s" dst-md))
        (System/exit 1))
      (println (format "Cloning VM '%s' -> '%s'" source dest))
      (machine/init-machine-clone cfg source dest network)
      (spit (str dst-md "/memory") (str memory "\n"))
      (spit (str dst-md "/vcpus") (str vcpus "\n"))
      (let [dest-vmid (determine-vmid! cfg dest)
            bridge (bridge-for cfg dest)
            mac (machine/read-field cfg dest "mac-address")]
        (println (format "Cloning VM on Proxmox (%s -> %s)..." source-vmid dest-vmid))
        (pve-ssh! cfg (format "qm clone %s %s --full 1 --name %s --storage %s" source-vmid dest-vmid dest (:pve-storage cfg)))
        (pve-ssh! cfg (format "qm set %s --net0 virtio=%s,bridge=%s,firewall=%s" dest-vmid mac bridge (:pve-firewall cfg)))
        (pve-ssh! cfg (format "qm set %s --memory %s --cores %s" dest-vmid memory vcpus))
        (if (machine/mutable? cfg source)
          (do
            (println "Updating identity on cloned mutable disk...")
            (let [disk-ref* (disk-ref (pve-ssh cfg (format "qm config %s" dest-vmid)) "virtio0")
                  disk-path (pve-ssh cfg (format "pvesm path '%s'" disk-ref*))
                  hostname (machine/read-field cfg dest "hostname")
                  machine-id (machine/read-field cfg dest "machine-id")]
              (with-nbd-mount cfg disk-path "p2" "/mnt/nixos-clone-identity" false
                              (fn [mp]
                                (pve-ssh cfg (format "echo '%s' > %s/etc/hostname" hostname mp))
                                (pve-ssh cfg (format "echo '%s' > %s/etc/machine-id" machine-id mp))))))
          (do
            (b/sync-identity this cfg dest)
            (println "Removing SSH host keys (will be regenerated on first boot)...")
            (let [var-ref (disk-ref (pve-ssh cfg (format "qm config %s" dest-vmid)) "virtio1")
                  var-path (pve-ssh cfg (format "pvesm path '%s'" var-ref))]
              (with-nbd-mount cfg var-path "p1" "/mnt/nixos-ssh-cleanup" false
                              (fn [mp]
                                (pve-ssh-soft cfg (format "rm -f %s/identity/ssh_host_ed25519_key %s/identity/ssh_host_ed25519_key.pub" mp mp)))))))
        (println)
        (println (format "VM '%s' cloned from '%s' (VMID: %s)." dest source dest-vmid))
        (println (format "Start with: BACKEND=proxmox just start %s" dest))))))

(defn upgrade-vm [this cfg name]
  (b/validate-machine! cfg name (format "Use 'BACKEND=proxmox just create %s' for new VMs" name))
  (when (machine/mutable? cfg name) (b/mutable-upgrade-error!))
  (validate! cfg)
  (let [profile (machine/read-field cfg name "profile")
        vmid (get-vmid cfg name)
        snaps (b/snapshot-count this cfg name)]
    (when (pos? snaps)
      (println (format "WARNING: VM '%s' has %d snapshot(s) that will be DELETED:" name snaps))
      (b/list-snapshots this cfg name)
      (println)
      (b/confirm-or-abort "Continue with upgrade and delete snapshots? [y/N] ")
      (doseq [snap (->> (str/split-lines (try (pve-ssh cfg (format "qm listsnapshot %s" vmid)) (catch Exception _ "")))
                        (remove #(str/includes? % "current"))
                        (map #(second (re-find #"^\s*\S*\s*(\S+)" %)))
                        (remove str/blank?))]
        (println (format "Deleting snapshot: %s" snap))
        (pve-ssh-soft cfg (format "qm delsnapshot %s %s" vmid snap))))
    (println (format "Upgrading VM '%s' to latest %s image (preserving /var data)" name profile))
    (b/stop-graceful this cfg name)
    (profile/build-profile cfg profile {:flake-update? true})
    (b/sync-identity this cfg name)
    (when (machine/semi-mutable? cfg name)
      (println "Wiping /nix overlay (user-installed packages will need reinstalling)...")
      (wipe-nix-overlay! cfg name))
    (let [profile-key (profile/normalize-profiles profile)
          img (profile-image cfg profile-key)
          vd (vm-dir cfg name)
          stg (:pve-staging-dir cfg)]
      (fs/create-dirs vd)
      (println "Flattening new boot disk...")
      (proc/run! (concat (:qemu-img cfg) ["convert" "-f" "qcow2" "-O" "qcow2" img (str vd "/boot-flat.qcow2")]))
      (pve-ssh cfg (format "mkdir -p %s/%s" stg name))
      (println "Transferring new boot disk to Proxmox...")
      (pve-rsync! cfg (str vd "/boot-flat.qcow2") (format "%s:%s/%s/boot.qcow2" (:pve-host cfg) stg name))
      (pve-ssh-soft cfg (format "qm set %s --delete virtio0" vmid))
      (let [old-disk (some-> (->> (str/split-lines (try (pve-ssh cfg (format "qm config %s" vmid)) (catch Exception _ "")))
                                  (filter #(str/starts-with? % "unused")) first)
                             (str/replace #"^unused[0-9]*: " ""))]
        (when-not (str/blank? old-disk)
          (pve-ssh-soft cfg (format "pvesh delete /nodes/%s/storage/%s/content/%s" (:pve-node cfg) (:pve-storage cfg) old-disk))))
      (println "Importing new boot disk...")
      (pve-ssh! cfg (format "qm importdisk %s %s/%s/boot.qcow2 %s --format %s" vmid stg name (:pve-storage cfg) (:pve-disk-format cfg)))
      (let [new-disk (some-> (->> (str/split-lines (pve-ssh cfg (format "qm config %s" vmid)))
                                  (filter #(str/starts-with? % "unused")) last)
                             (str/replace #"^unused[0-9]*: " ""))]
        (when-not (str/blank? new-disk)
          (pve-ssh! cfg (format "qm set %s --virtio0 %s --boot order=virtio0" vmid new-disk))))
      (pve-ssh cfg (format "rm -rf %s/%s" stg name))
      (fs/delete-if-exists (str vd "/boot-flat.qcow2")))
    (b/start this cfg name)
    (let [ip (b/wait-for-vm-ip this cfg name)]
      (println)
      (println (format "VM '%s' upgraded and started. /var data preserved." name))
      (when (machine/semi-mutable? cfg name)
        (println "NOTE: /nix overlay was wiped. Reinstall any user-added packages."))
      (println (format "SSH as admin (sudo): ssh admin@%s" ip))
      (println (format "SSH as user (no sudo): ssh user@%s" ip)))))

(defn- numfmt-from-iec [s]
  (try (parse-long (proc/capture ["numfmt" "--from=iec" s])) (catch Exception _ 0)))

(defn resize-var [this cfg name size]
  (let [new-size (machine/normalize-size size)]
    (validate! cfg)
    (let [vmid (get-vmid cfg name)]
      (when (b/running? this cfg name)
        (println (format "Error: VM '%s' must be stopped before resizing." name))
        (println (format "Run 'BACKEND=proxmox just stop %s' first." name))
        (System/exit 1))
      (println "Fetching current disk configuration...")
      (let [config (pve-ssh cfg (format "qm config %s" vmid))
            disk-info (config-line config "virtio1")]
        (when (str/blank? disk-info)
          (println (format "Error: /var disk (virtio1) not found for VM '%s'" name))
          (System/exit 1))
        (let [cur-str (or (second (re-find #"size=([0-9]+[KMGT]?)" disk-info)) "unknown")
              cur-bytes (numfmt-from-iec cur-str)
              new-bytes (numfmt-from-iec new-size)]
          (when (<= new-bytes cur-bytes)
            (println (format "Error: New size (%s) must be larger than current size (%s)" new-size cur-str))
            (println "Shrinking disks is not supported.")
            (System/exit 1))
          (println (format "Current /var disk size: %s" cur-str))
          (println (format "New size: %s" new-size))
          (println)
          (println "NOTE: This will resize the disk on Proxmox.")
          (println "The filesystem inside will be grown automatically on next boot.")
          (b/confirm-or-abort "Continue? [y/N] ")
          (println "Resizing /var disk...")
          (pve-ssh! cfg (format "qm resize %s virtio1 %s" vmid new-size))
          (println)
          (println (format "Resize complete. Start VM with: BACKEND=proxmox just start %s" name)))))))

(defn resize-vm [this cfg name]
  (validate! cfg)
  (b/validate-machine! cfg name)
  (let [vmid (get-vmid cfg name)]
    (when (b/running? this cfg name)
      (println (format "Error: VM '%s' must be stopped before resizing." name))
      (println (format "Run 'BACKEND=proxmox just stop %s' first." name))
      (System/exit 1))
    (let [md (machine/machine-dir cfg name)
          cur-mem (or (machine/read-field cfg name "memory") "2048")
          cur-vcpus (or (machine/read-field cfg name "vcpus") "2")
          config (pve-ssh cfg (format "qm config %s" vmid))
          cur-str (or (some-> (config-line config "virtio1") (->> (re-find #"size=([0-9]+[KMGT]?)")) second) "unknown")
          cur-bytes (numfmt-from-iec cur-str)]
      (println (format "Current VM configuration for '%s' (VMID: %s):" name vmid))
      (println (format "  Memory: %s MB" cur-mem))
      (println (format "  vCPUs:  %s" cur-vcpus))
      (println (format "  /var:   %s" cur-str))
      (println)
      (let [new-mem (let [v (b/prompt-line (format "New memory in MB [%s]: " cur-mem))] (if (str/blank? v) cur-mem v))
            new-vcpus (let [v (b/prompt-line (format "New vCPUs [%s]: " cur-vcpus))] (if (str/blank? v) cur-vcpus v))
            new-disk (machine/normalize-size (let [v (b/prompt-line (format "New /var disk size [%s]: " cur-str))]
                                               (if (str/blank? v) cur-str v)))
            new-bytes (numfmt-from-iec new-disk)]
        (when (< new-bytes cur-bytes)
          (println (format "Error: New disk size (%s) must be >= current size (%s)" new-disk cur-str))
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
        (println "Updating VM configuration...")
        (pve-ssh! cfg (format "qm set %s --memory %s --cores %s" vmid new-mem new-vcpus))
        (when (> new-bytes cur-bytes)
          (println "Resizing /var disk...")
          (pve-ssh! cfg (format "qm resize %s virtio1 %s" vmid new-disk)))
        (println)
        (println (format "Resize complete. Start VM with: BACKEND=proxmox just start %s" name))))))

(defn backup-vm [_this cfg name]
  (validate! cfg)
  (let [vmid (get-vmid cfg name)]
    (println (format "Creating backup of VM '%s' (VMID: %s) via vzdump..." name vmid))
    (pve-ssh! cfg (format "vzdump %s --mode snapshot --compress zstd --storage %s" vmid (:pve-backup-storage cfg)))
    (println)
    (println "Backup complete. List backups with: BACKEND=proxmox just backups")))

(defn restore-backup-vm [this cfg name backup-file]
  (validate! cfg)
  (b/validate-machine! cfg name (format "The VM must be created first with 'BACKEND=proxmox just create %s'" name))
  (let [vmid (get-vmid cfg name)
        node (:pve-node cfg)]
    (if (str/blank? backup-file)
      (do
        (println (format "Available backups on Proxmox for VMID %s:" vmid))
        (let [backups (try (pve-ssh cfg (format "pvesh get /nodes/%s/storage/%s/content --content backup --vmid %s --output-format json"
                                                node (:pve-backup-storage cfg) vmid))
                           (catch Exception _ "[]"))
              parsed (try (json/parse-string backups true) (catch Exception _ []))]
          (if (empty? parsed)
            (do (println "  No backups found.") (System/exit 1))
            (do
              (doseq [b parsed]
                (println (format "  %s (%dMB)" (:volid b) (long (/ (or (:size b) 0) 1048576)))))
              (println)
              (println "Specify backup file to restore:")
              (println (format "  BACKEND=proxmox just restore-backup %s <volid>" name))
              (System/exit 0)))))
      (do
        (println (format "WARNING: This will replace VM '%s' with backup contents." name))
        (println "All current data will be LOST.")
        (println (format "Backup: %s" backup-file))
        (b/confirm-or-abort "Are you sure? [y/N] ")
        (b/force-stop this cfg name)
        (pve-ssh-soft cfg (format "qm destroy %s --destroy-unreferenced-disks 1 --purge 1" vmid))
        (println "Restoring VM from backup...")
        (pve-ssh! cfg (format "qmrestore %s %s --storage %s" backup-file vmid (:pve-storage cfg)))
        (println)
        (println (format "Restore complete. Start VM with: BACKEND=proxmox just start %s" name))))))

(defn ssh-vm [cfg input]
  (let [[ssh-user name] (if (str/includes? input "@") (str/split input #"@" 2) ["user" input])
        ip (b/get-ip (->Proxmox) cfg name)]
    (when (str/blank? ip)
      (println (format "Error: Could not determine IP address for VM '%s'" name))
      (println (format "Is the VM running? Check with: BACKEND=proxmox just status %s" name))
      (println "Is the QEMU guest agent responding? It may need a moment after boot.")
      (System/exit 1))
    (println (format "Connecting to %s at %s as %s..." name ip ssh-user))
    (proc/run! (concat (:ssh cfg) ["-o" "StrictHostKeyChecking=accept-new" (str ssh-user "@" ip)]))))

(defn list-backups [cfg]
  (validate! cfg)
  (let [vmids (->> (fs/glob (:machines-dir cfg) "*/vmid")
                   (map #(str/trim (slurp (str %)))) (remove str/blank?) vec)]
    (if (empty? vmids)
      (println "No managed VMs found.")
      (do
        (println (format "Backups on Proxmox storage '%s' (managed VMs only):" (:pve-backup-storage cfg)))
        (let [backups (try (pve-ssh cfg (format "pvesh get /nodes/%s/storage/%s/content --content backup --output-format json"
                                                (:pve-node cfg) (:pve-backup-storage cfg)))
                           (catch Exception _ "[]"))
              parsed (try (json/parse-string backups true) (catch Exception _ []))
              ids (set vmids)
              filtered (filter #(contains? ids (str (:vmid %))) parsed)]
          (if (empty? filtered)
            (println "  (none)")
            (doseq [b filtered]
              (println (format "  %s  VMID=%s  %dMB" (:volid b) (or (:vmid b) "?") (long (/ (or (:size b) 0) 1048576)))))))))))
