(ns vm.backend.pve-common
  "Shared Proxmox-over-SSH helpers used by both PVE backends. These mirror the
  private helpers in vm.backend.proxmox (which predates this ns and keeps its own
  copies to stay byte-stable); the LXC backend uses these. The only behavioural
  difference from the proxmox originals is that sync-firewall! takes the guest
  type (\"qemu\" or \"lxc\") since the pvesh path differs."
  (:require [clojure.string :as str]
            [babashka.fs :as fs]
            [cheshire.core :as json]
            [vm.proc :as proc]
            [vm.machine :as machine]))

;; ─── ssh / rsync ─────────────────────────────────────────────────────────────

(defn validate! [cfg]
  (when (str/blank? (:pve-host cfg))
    (println "Error: PVE_HOST is not set.")
    (println "Set it via environment variable or .env file:")
    (println "  export PVE_HOST=pve")
    (println "  BACKEND=proxmox-lxc PVE_HOST=pve just create myct")
    (println)
    (println "Configure SSH connection in ~/.ssh/config:")
    (println "  Host pve")
    (println "      HostName 192.168.1.100")
    (println "      User root")
    (System/exit 1)))

(defn- ssh-base [cfg]
  (concat (:ssh cfg) ["-o" "BatchMode=yes" "-o" "StrictHostKeyChecking=accept-new"]))

(defn pve-ssh
  "Run a remote command, return trimmed stdout. Throws on non-zero."
  [cfg cmd]
  (validate! cfg)
  (proc/capture (concat (ssh-base cfg) [(:pve-host cfg) cmd])))

(defn pve-ssh!
  "Run a remote command inheriting stdout/stderr (visible progress)."
  [cfg cmd]
  (validate! cfg)
  (proc/run! (concat (ssh-base cfg) [(:pve-host cfg) cmd])))

(defn pve-ssh-soft
  "Run a remote command, ignoring failure (bash `|| true`)."
  [cfg cmd]
  (validate! cfg)
  (proc/run-ok? (concat (ssh-base cfg) [(:pve-host cfg) cmd])))

(defn pve-ssh-ok?
  "Run a remote command quietly, return true on exit 0."
  [cfg cmd]
  (validate! cfg)
  (zero? (:exit (proc/capture-result (concat (ssh-base cfg) [(:pve-host cfg) cmd])))))

(defn pve-rsync! [cfg src dst]
  (validate! cfg)
  (proc/run! ["rsync" "-avz" "--progress" "-e"
              "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
              src dst]))

(defn pve-rsync-noown!
  "Like pve-rsync! but does NOT preserve source owner/group — the remote (root)
  owns everything written. Use when staging files built locally as a non-root
  user into a root-owned target (e.g. an LXC rootfs /etc), where preserving the
  local uid would break sshd StrictModes and similar."
  [cfg src dst]
  (validate! cfg)
  (proc/run! ["rsync" "-avz" "--no-owner" "--no-group" "--progress" "-e"
              "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
              src dst]))

(defn ssh-host [cfg] (:pve-host cfg))
(defn ssh-prefix [cfg] (ssh-base cfg))

;; ─── vmid ────────────────────────────────────────────────────────────────────

(defn vmid-file [cfg name] (str (machine/machine-dir cfg name) "/vmid"))

(defn get-vmid [cfg name]
  (let [f (vmid-file cfg name)]
    (if (fs/exists? f)
      (str/trim (slurp f))
      (do (println (format "Error: VMID not found for machine '%s'" name))
          (println (format "Expected file: %s" f))
          (System/exit 1)))))

(defn next-vmid [cfg] (pve-ssh cfg "pvesh get /cluster/nextid"))

(defn determine-vmid!
  "Read the VMID file, or prompt interactively (auto-allocated default), then
  persist and return it. guest-type is \"qemu\" or \"lxc\" (used to detect a
  conflicting existing guest with the same id)."
  [cfg name guest-type]
  (let [md (machine/machine-dir cfg name)
        f (vmid-file cfg name)
        cmd (if (= guest-type "lxc") "pct config" "qm config")
        vmid
        (if (fs/exists? f)
          (let [v (str/trim (slurp f))]
            (binding [*out* *err*] (println (format "Using existing VMID: %s" v)))
            v)
          (do (binding [*out* *err*] (println "Allocating VMID from Proxmox..."))
              (let [default-vmid (next-vmid cfg)]
                (loop []
                  (let [in (do (print (format "Enter VMID [%s]: " default-vmid)) (flush) (or (read-line) ""))
                        v (if (str/blank? in) default-vmid in)
                        existing (try (-> (pve-ssh cfg (format "%s %s 2>/dev/null | grep '^hostname:\\|^name:'" cmd v))
                                          (str/replace #"^(hostname|name): " "")
                                          str/trim)
                                      (catch Exception _ ""))]
                    (if (and (not (str/blank? existing)) (not= existing name))
                      (do (binding [*out* *err*]
                            (println (format "VMID %s is already in use by '%s'. Choose a different ID." v existing)))
                          (recur))
                      v))))))]
    (fs/create-dirs md)
    (spit f (str vmid "\n"))
    vmid))

;; ─── config parsing ──────────────────────────────────────────────────────────

(defn config-line [config prefix]
  (some #(when (str/starts-with? % (str prefix ": ")) (subs % (count (str prefix ": "))))
        (str/split-lines config)))

(defn bridge-for [cfg name]
  (let [netcfg (or (machine/read-field cfg name "network") "nat")]
    (if (str/starts-with? netcfg "bridge:") (subs netcfg 7) (:pve-bridge cfg))))

;; ─── firewall ────────────────────────────────────────────────────────────────

(defn port-lines [path]
  (when (fs/exists? path)
    (->> (str/split-lines (slurp path))
         (map #(str/trim (str/replace % #"#.*" "")))
         (remove str/blank?))))

(defn sync-firewall!
  "Sync per-machine tcp_ports/udp_ports into the Proxmox firewall. guest-type is
  \"qemu\" or \"lxc\" (the pvesh resource path differs)."
  [cfg name guest-type]
  (let [vmid (get-vmid cfg name)
        node (:pve-node cfg)
        md (machine/machine-dir cfg name)
        base (format "/nodes/%s/%s/%s/firewall" node guest-type vmid)]
    (println (format "Configuring Proxmox firewall for '%s' (VMID: %s)..." name vmid))
    (pve-ssh! cfg (format "pvesh set %s/options --enable 1 --policy_in DROP --policy_out ACCEPT" base))
    (let [existing (try (pve-ssh cfg (format "pvesh get %s/rules --output-format json" base))
                        (catch Exception _ "[]"))
          n (count (try (json/parse-string existing) (catch Exception _ [])))]
      (when (pos? n)
        (doseq [i (reverse (range n))]
          (pve-ssh-soft cfg (format "pvesh delete %s/rules/%s" base i)))))
    (doseq [[proto file] [["tcp" "tcp_ports"] ["udp" "udp_ports"]]]
      (doseq [port (port-lines (str md "/" file))]
        (pve-ssh! cfg (format "pvesh create %s/rules --type in --action ACCEPT --proto %s --dport %s --enable 1"
                              base proto port))))
    (pve-ssh! cfg (format "pvesh create %s/rules --type in --action ACCEPT --proto icmp --enable 1" base))
    (println "Proxmox firewall configured.")))
