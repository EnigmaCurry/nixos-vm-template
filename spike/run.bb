#!/usr/bin/env bb
;; Spike runbook: build the NixOS LXC tarball, ship it to a Proxmox node, and
;; `pct create` a privileged container with a host ZFS dataset bind-mounted at
;; /srv/nas. Disposable proof of concept — see spike/README.md.
;;
;; Usage (run from the repo root):
;;   PVE_HOST=pve ZFS_DATASET=tank/nas bb spike/run.bb up
;;   PVE_HOST=pve VMID=9000        bb spike/run.bb down     # tear the CT back down
;;
;; Env:
;;   PVE_HOST     (required) ssh host/alias of the Proxmox node (root@…)
;;   ZFS_DATASET  (required for `up`) host dataset to bind-mount, e.g. tank/nas
;;   VMID         (optional) container id; allocated via pvesh nextid if unset
;;   PVE_STORAGE  rootfs storage for the CT      (default: local-zfs)
;;   BRIDGE       network bridge                 (default: vmbr0)
;;   CORES        (default: 2)   MEMORY MB (default: 2048)   ROOTFS_SIZE GB (default: 8)
;;   CT_HOSTNAME  (default: nas-spike)
;;   APPARMOR_UNCONFINED  set to 0 to skip the unconfined apparmor workaround for nfsd
;;
;; The container is built with --impure so an SSH key can be baked in: this
;; script passes SSH_AUTHORIZED_KEY (from ssh-agent or ~/.ssh/*.pub) to the build.
;; A throwaway password ("nixos") is always set as a fallback.

(require '[babashka.process :as proc]
         '[babashka.fs :as fs]
         '[clojure.string :as str])

;; ─── env / config ────────────────────────────────────────────────────────────

(defn env [k d] (let [v (System/getenv k)] (if (str/blank? v) d v)))

(def pve-host     (env "PVE_HOST" nil))
(def zfs-dataset  (env "ZFS_DATASET" nil))
(def storage      (env "PVE_STORAGE" "local-zfs"))
(def bridge       (env "BRIDGE" "vmbr0"))
(def cores        (env "CORES" "2"))
(def memory       (env "MEMORY" "2048"))
(def rootfs-size  (env "ROOTFS_SIZE" "8"))
(def ct-hostname  (env "CT_HOSTNAME" "nas-spike"))
(def template     "/var/lib/vz/template/cache/nixos-lxc-spike.tar.xz")
(def apparmor?    (not= "0" (env "APPARMOR_UNCONFINED" "1")))

(defn die [msg] (binding [*out* *err*] (println (str "Error: " msg))) (System/exit 1))

;; ─── process helpers ─────────────────────────────────────────────────────────

(defn sh!
  "Run a local command, inheriting stdio. Throw on non-zero."
  [& args]
  (apply proc/shell args))

(defn sh-out
  "Run a local command, return trimmed stdout."
  [& args]
  (str/trim (:out (apply proc/shell {:out :string} args))))

(defn ssh-args [] ["ssh" "-o" "BatchMode=yes" "-o" "StrictHostKeyChecking=accept-new" pve-host])

(defn pve!
  "Run a remote command on the PVE node, inheriting stdio. Throw on non-zero."
  [cmd]
  (println (str "[pve] " cmd))
  (apply proc/shell (concat (ssh-args) [cmd])))

(defn pve-out [cmd] (str/trim (:out (apply proc/shell {:out :string} (concat (ssh-args) [cmd])))))

(defn pve-ok?
  "Run a remote command, return true on exit 0 (never throws)."
  [cmd]
  (zero? (:exit (apply proc/shell {:out :string :err :string :continue true} (concat (ssh-args) [cmd])))))

;; ─── ssh key discovery (baked into the image via --impure) ───────────────────

(defn discover-ssh-key []
  (or (let [r (proc/shell {:out :string :continue true} "ssh-add" "-L")]
        (when (zero? (:exit r))
          (first (remove str/blank? (str/split-lines (:out r))))))
      (some (fn [p] (when (fs/exists? p) (str/trim (slurp (str p)))))
            [(str (fs/home) "/.ssh/id_ed25519.pub") (str (fs/home) "/.ssh/id_rsa.pub")])))

;; ─── build / transfer ────────────────────────────────────────────────────────

(defn build-tarball []
  (println "Building .#lxc-nas-spike (--impure to allow baking an SSH key)...")
  (let [key (discover-ssh-key)
        _ (when key (println (str "  baking SSH key: " (subs key 0 (min 40 (count key))) "...")))
        env (cond-> (into {} (System/getenv)) key (assoc "SSH_AUTHORIZED_KEY" key))
        out (str/trim (:out (proc/shell {:out :string :extra-env env}
                                        "nix" "build" ".#lxc-nas-spike"
                                        "--impure" "--no-link" "--print-out-paths")))
        tarball (first (fs/glob (str out "/tarball") "*.tar.xz"))]
    (when-not tarball (die (str "No tar.xz produced under " out "/tarball")))
    (println (str "Built: " tarball))
    (str tarball)))

(defn transfer! [tarball]
  (println (str "Transferring tarball to " pve-host ":" template " ..."))
  (sh! "rsync" "-av" "--progress" "-e"
       "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
       tarball (str pve-host ":" template)))

;; ─── vmid ─────────────────────────────────────────────────────────────────────

(defn resolve-vmid []
  (or (env "VMID" nil)
      (let [v (pve-out "pvesh get /cluster/nextid")]
        (println (str "Allocated VMID: " v))
        v)))

;; ─── commands ─────────────────────────────────────────────────────────────────

(defn cmd-up []
  (when-not pve-host (die "PVE_HOST is required"))
  (when-not zfs-dataset (die "ZFS_DATASET is required (e.g. tank/nas)"))
  (let [tarball (build-tarball)
        vmid (resolve-vmid)]
    (transfer! tarball)
    ;; Ensure the host ZFS dataset exists and resolve its mountpoint.
    (when-not (pve-ok? (str "zfs list -H -o name " zfs-dataset))
      (println (str "Creating ZFS dataset " zfs-dataset " ..."))
      (pve! (str "zfs create " zfs-dataset)))
    (let [mountpoint (pve-out (str "zfs get -H -o value mountpoint " zfs-dataset))]
      (when (str/blank? mountpoint) (die (str "Could not resolve mountpoint for " zfs-dataset)))
      (println (str "ZFS dataset mountpoint: " mountpoint))
      ;; Create the privileged container from the NixOS template.
      (pve! (str "pct create " vmid " " template
                 " --ostype unmanaged --arch amd64 --unprivileged 0 --features nesting=1"
                 " --cores " cores " --memory " memory
                 " --rootfs " storage ":" rootfs-size
                 " --net0 name=eth0,bridge=" bridge ",ip=dhcp"
                 " --hostname " ct-hostname))
      ;; Bind-mount the host ZFS dataset at /srv/nas (the whole point).
      (pve! (str "pct set " vmid " -mp0 " mountpoint ",mp=/srv/nas"))
      ;; Privileged kernel nfsd is commonly blocked by the default apparmor
      ;; profile; the documented workaround is unconfined for this CT.
      (when apparmor?
        (pve! (str "grep -q 'lxc.apparmor.profile' /etc/pve/lxc/" vmid ".conf"
                   " || echo 'lxc.apparmor.profile: unconfined' >> /etc/pve/lxc/" vmid ".conf")))
      (pve! (str "pct start " vmid))
      (println)
      (println (str "Container " vmid " (" ct-hostname ") started. Verify with:"))
      ;; NixOS binaries live under /run/current-system/sw/bin and `pct exec` runs
      ;; with a minimal PATH, so reference them by full path (or use `pct enter`).
      (let [sw (str "/run/current-system/sw/bin")]
        (println (str "  ssh " pve-host " pct exec " vmid " -- " sw "/systemctl is-system-running"))
        (println (str "  ssh " pve-host " pct exec " vmid " -- " sw "/ip -4 addr show eth0"))
        (println (str "  ssh " pve-host " pct exec " vmid " -- " sw "/exportfs -v"))
        (println (str "  ssh -t " pve-host " pct enter " vmid "   # interactive shell, full PATH (run via '! ...')")))
      (println (str "Tear down with: PVE_HOST=" pve-host " VMID=" vmid " bb spike/run.bb down")))))

(defn cmd-down []
  (when-not pve-host (die "PVE_HOST is required"))
  (let [vmid (or (env "VMID" nil) (die "VMID is required for down"))]
    (pve! (str "pct stop " vmid " || true"))
    (pve! (str "pct destroy " vmid " --purge 1 || true"))
    (println (str "Container " vmid " destroyed (the ZFS dataset " zfs-dataset " is left intact)."))))

(defn -main [& args]
  (case (first args)
    (nil "up") (cmd-up)
    "down"     (cmd-down)
    (die (str "unknown command '" (first args) "' (expected: up | down)"))))

(apply -main *command-line-args*)
