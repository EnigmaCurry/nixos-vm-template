(ns vm.backend.lxc
  "Proxmox LXC backend: NixOS in a Proxmox container. Mutable-only (an LXC rootfs
  is read-write; nixos-rebuild runs inside). The image is a rootfs tarball
  (flake.lib.mkLxcImage); create is `pct create` + `-mpN` host ZFS bind mounts;
  identity + the /etc/nixos flake are injected into the stopped rootfs via
  `pct mount`. Shares the PVE-over-SSH plumbing with the KVM proxmox backend via
  vm.backend.pve-common."
  (:require [clojure.string :as str]
            [babashka.fs :as fs]
            [cheshire.core :as json]
            [vm.proc :as proc]
            [vm.machine :as machine]
            [vm.profile :as profile]
            [vm.wizard :as wizard]
            [vm.backend :as b]
            [vm.backend.pve-common :as pc]))

;; ─── in-guest flake (nixos-rebuild from inside the container) ────────────────

(defn generate-lxc-flake
  "flake.nix for /etc/nixos inside an LXC container. Mirrors
  vm.mutable/generate-mutable-flake but imports nixpkgs' proxmox-lxc module and
  sets vm.container plus the container networking (systemd-networkd DHCP)."
  [hostname system profile-str privileged?]
  (let [imports (apply str (map #(str "          ./profiles/" % ".nix\n")
                                (str/split profile-str #",")))]
    (str "{\n"
         "  description = \"NixOS LXC configuration\";\n\n"
         "  inputs = {\n"
         "    nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";\n"
         "    home-manager = {\n"
         "      url = \"github:nix-community/home-manager\";\n"
         "      inputs.nixpkgs.follows = \"nixpkgs\";\n"
         "    };\n"
         "    sway-home = {\n"
         "      url = \"github:EnigmaCurry/sway-home?dir=home-manager\";\n"
         "      inputs.nixpkgs.follows = \"nixpkgs\";\n"
         "    };\n"
         "    nix-flatpak.url = \"github:gmodena/nix-flatpak\";\n"
         "  };\n\n"
         "  outputs = { self, nixpkgs, home-manager, sway-home, nix-flatpak, ... }:\n"
         "    {\n"
         "      nixosConfigurations.\"" hostname "\" = nixpkgs.lib.nixosSystem {\n"
         "        system = \"" system "\";\n"
         "        specialArgs = {\n"
         "          inherit sway-home nix-flatpak;\n"
         "          swayHomeInputs = sway-home.inputs;\n"
         "        };\n"
         "        modules = [\n"
         "          ./modules\n"
         "          \"${nixpkgs}/nixos/modules/virtualisation/proxmox-lxc.nix\"\n"
         "          home-manager.nixosModules.home-manager\n"
         imports
         "          {\n"
         "            vm.mutable = true;\n"
         "            vm.container = true;\n"
         "            networking.hostName = \"" hostname "\";\n"
         "            proxmoxLXC = { privileged = " (if privileged? "true" "false") "; manageNetwork = true; manageHostName = true; };\n"
         "            networking.useDHCP = false;\n"
         "            networking.useNetworkd = true;\n"
         "            networking.useHostResolvConf = false;\n"
         "            systemd.network.enable = true;\n"
         "            systemd.network.networks.\"10-eth0\" = { matchConfig.Name = \"eth0\"; networkConfig.DHCP = \"yes\"; };\n"
         "            systemd.network.wait-online.enable = false;\n"
         "            services.resolved.enable = true;\n"
         "          }\n"
         "        ];\n"
         "      };\n"
         "    };\n"
         "}\n")))

;; ─── helpers ─────────────────────────────────────────────────────────────────

(defn- vm-dir [cfg name] (str (:vms-dir cfg) "/" name))

(defn- nas-profile? [cfg name]
  (boolean (some #(= % "nas")
                 (str/split (or (machine/read-field cfg name "profile") "") #","))))

(defn- privileged? [cfg name]
  (or (= "1" (str/trim (or (machine/read-field cfg name "privileged") "")))
      (nas-profile? cfg name)))

(defn- rootfs-gb
  "pct --rootfs takes an integer GB size; strip any unit suffix."
  [size]
  (or (re-find #"\d+" (or size "8")) "8"))

(defn- detect-system []
  (case (proc/capture ["uname" "-m"])
    "x86_64" "x86_64-linux"
    "aarch64" "aarch64-linux"
    "x86_64-linux"))

(defn- profile-tarball
  "Resolve the built LXC template tarball for a profile key, or nil."
  [cfg prof-key]
  (let [real (str/trim (proc/capture (concat (:readlink cfg)
                                             ["-f" (str (:output-dir cfg) "/lxc-profiles/" prof-key)])))
        t (when-not (str/blank? real) (first (fs/glob (str real "/tarball") "*.tar.xz")))]
    (when t (str t))))

;; ─── identity + flake injection (via `pct mount`) ────────────────────────────

(defn- non-empty? [path] (and (fs/regular-file? path) (pos? (fs/size path))))

(defn- key-filter
  "Strip comment/blank lines (matches the mutable guestfish path)."
  [src dst]
  (when (non-empty? src)
    (let [body (->> (str/split-lines (slurp src))
                    (remove #(or (str/starts-with? % "#") (str/blank? %)))
                    (str/join "\n"))]
      (when-not (str/blank? body) (spit dst (str body "\n"))))))

(defn- stage-rootfs-etc!
  "Build a local temp dir holding the /etc tree to rsync into the container
  rootfs: hostname, machine-id, ssh keys, firewall-ports, network-config, root
  password hash, and the /etc/nixos flake (+ modules/profiles). Returns the dir."
  [cfg name]
  (let [tmp (str (fs/create-temp-dir))
        etc (str tmp "/etc")
        md (machine/machine-dir cfg name)
        repo (:repo-dir cfg)
        prof (profile/normalize-profiles (machine/read-field cfg name "profile"))
        hostname (or (machine/read-field cfg name "hostname") name)
        machine-id (machine/read-field cfg name "machine-id")
        cp (fn [src dst] (when (non-empty? src) (proc/run! ["cp" src dst])))]
    (fs/create-dirs (str etc "/ssh/authorized_keys.d"))
    (fs/create-dirs (str etc "/firewall-ports"))
    (fs/create-dirs (str etc "/network-config"))
    (fs/create-dirs (str etc "/nixos"))
    (spit (str etc "/hostname") (str hostname "\n"))
    (when machine-id (spit (str etc "/machine-id") (str machine-id "\n")))
    ;; SSH authorized keys -> /etc/ssh/authorized_keys.d/{admin,user}
    (key-filter (str md "/admin_authorized_keys") (str etc "/ssh/authorized_keys.d/admin"))
    (key-filter (str md "/user_authorized_keys") (str etc "/ssh/authorized_keys.d/user"))
    ;; firewall ports
    (cp (str md "/tcp_ports") (str etc "/firewall-ports/tcp_ports"))
    (cp (str md "/udp_ports") (str etc "/firewall-ports/udp_ports"))
    (cp (str md "/allowed_cidrs") (str etc "/firewall-ports/allowed_cidrs"))
    ;; network config
    (cp (str md "/static_ip") (str etc "/network-config/static_ip"))
    (cp (str md "/resolv.conf") (str etc "/network-config/resolv.conf"))
    ;; root password hash
    (cp (str md "/root_password_hash") (str etc "/root_password_hash"))
    ;; nas profile config (shared by Samba + copyparty): nas_passwd (plaintext
    ;; `user password`, 0600), nas_acl (`user share access`), nfs_clients (CIDRs).
    (when (some non-empty? [(str md "/nas_passwd") (str md "/nas_acl") (str md "/nfs_clients")])
      (fs/create-dirs (str etc "/nas"))
      (cp (str md "/nas_passwd") (str etc "/nas/nas_passwd"))
      (cp (str md "/nas_acl") (str etc "/nas/nas_acl"))
      (cp (str md "/nfs_clients") (str etc "/nas/nfs_clients")))
    ;; /etc/nixos flake for in-guest nixos-rebuild
    (spit (str etc "/nixos/flake.nix")
          (generate-lxc-flake hostname (detect-system) prof (privileged? cfg name)))
    (proc/run! ["cp" (str repo "/flake.lock") (str etc "/nixos/flake.lock")])
    (proc/run! ["cp" "-r" "--no-preserve=mode" (str repo "/modules") (str etc "/nixos/modules")])
    (proc/run! ["cp" "-r" "--no-preserve=mode" (str repo "/profiles") (str etc "/nixos/profiles")])
    tmp))

(defn- rootfs-perm-cmds [root]
  [(format "chmod 0644 %s/etc/hostname 2>/dev/null || true" root)
   (format "chmod 0444 %s/etc/machine-id 2>/dev/null || true" root)
   (format "chmod 0755 %s/etc/ssh/authorized_keys.d 2>/dev/null || true" root)
   (format "chmod 0644 %s/etc/ssh/authorized_keys.d/* 2>/dev/null || true" root)
   (format "chmod 0755 %s/etc/firewall-ports %s/etc/network-config 2>/dev/null || true" root root)
   (format "chmod 0644 %s/etc/firewall-ports/* %s/etc/network-config/* 2>/dev/null || true" root root)
   (format "chmod 0600 %s/etc/root_password_hash 2>/dev/null || true" root)
   (format "chmod 0700 %s/etc/nas 2>/dev/null || true" root)
   (format "chmod 0600 %s/etc/nas/nas_passwd 2>/dev/null || true" root)
   (format "chmod 0644 %s/etc/nas/nas_acl %s/etc/nas/nfs_clients 2>/dev/null || true" root root)
   (format "chmod 0644 %s/etc/nixos/flake.nix %s/etc/nixos/flake.lock 2>/dev/null || true" root root)
   ;; chown the whole /etc/ssh dir (not just authorized_keys.d): sshd StrictModes
   ;; checks every parent directory of the authorized_keys file.
   (format "chown -R 0:0 %s/etc/hostname %s/etc/machine-id %s/etc/ssh %s/etc/firewall-ports %s/etc/network-config %s/etc/nas %s/etc/nixos 2>/dev/null || true"
           root root root root root root root)])

(defn- inject-rootfs!
  "Inject identity + /etc/nixos flake into a STOPPED container's rootfs."
  [cfg name vmid]
  (let [staged (stage-rootfs-etc! cfg name)
        root (format "/var/lib/lxc/%s/rootfs" vmid)]
    (try
      (println "Injecting identity into container rootfs...")
      (pc/pve-ssh-soft cfg (format "pct unmount %s 2>/dev/null || true" vmid))
      (pc/pve-ssh cfg (format "pct mount %s" vmid))
      (pc/pve-ssh cfg (format "mkdir -p %s/etc/ssh/authorized_keys.d %s/etc/firewall-ports %s/etc/network-config %s/etc/nixos"
                              root root root root))
      ;; --no-owner/--no-group: the staging dir is built locally as the calling
      ;; (non-root) user; preserving that uid would leave /etc/ssh owned non-root
      ;; and sshd StrictModes would reject every key. Let remote root own it.
      (pc/pve-rsync-noown! cfg (str staged "/etc/") (format "%s:%s/etc/" (:pve-host cfg) root))
      (doseq [c (rootfs-perm-cmds root)] (pc/pve-ssh-soft cfg c))
      (finally
        (pc/pve-ssh-soft cfg (format "pct unmount %s" vmid))
        (fs/delete-tree staged)))))

;; ─── ZFS host bind mounts (`pct set -mpN`) ───────────────────────────────────

(defn- apply-mounts!
  "Bind-mount host ZFS datasets/paths into the container. Each `mounts` line is
  `<host-dataset-or-path>:<container-path>`. A bare dataset (no leading /) is
  `zfs create`d if missing, then its mountpoint is bind-mounted."
  [cfg name vmid]
  (let [lines (pc/port-lines (str (machine/machine-dir cfg name) "/mounts"))]
    (doseq [[i spec] (map-indexed vector lines)]
      (let [[host-spec ctpath] (str/split spec #":" 2)]
        (if (or (str/blank? host-spec) (str/blank? ctpath))
          (println (format "Skipping malformed mount line: %s" spec))
          (let [hostpath
                (if (str/starts-with? host-spec "/")
                  host-spec
                  (do (when-not (pc/pve-ssh-ok? cfg (format "zfs list -H -o name %s" host-spec))
                        (println (format "Creating ZFS dataset %s..." host-spec))
                        (pc/pve-ssh! cfg (format "zfs create %s" host-spec)))
                      (str/trim (pc/pve-ssh cfg (format "zfs get -H -o value mountpoint %s" host-spec)))))]
            (println (format "Bind mount: %s -> %s (mp%d)" hostpath ctpath i))
            (pc/pve-ssh! cfg (format "pct set %s -mp%d %s,mp=%s" vmid i hostpath ctpath))))))))

;; ─── the create flow ─────────────────────────────────────────────────────────

(defn- create-ct!
  [cfg name size]
  (let [md (machine/machine-dir cfg name)]
    (when-not (fs/directory? md)
      (println (format "Error: Machine config not found: %s" md))
      (System/exit 1))
    (pc/validate! cfg)
    (let [prof (profile/normalize-profiles (machine/read-field cfg name "profile"))
          tarball (profile-tarball cfg prof)]
      (when-not tarball
        (println (format "Error: LXC template not found for profile '%s'" prof))
        (println (format "Run 'BACKEND=proxmox-lxc just build %s' first" prof))
        (System/exit 1))
      (let [vmid (pc/determine-vmid! cfg name "lxc")
            bridge (pc/bridge-for cfg name)
            mac (machine/read-field cfg name "mac-address")
            memory (or (machine/read-field cfg name "memory") "2048")
            vcpus (or (machine/read-field cfg name "vcpus") "2")
            priv? (privileged? cfg name)
            hostname (or (machine/read-field cfg name "hostname") name)
            tmpl (format "%s/nixos-lxc-%s.tar.xz" (:pve-template-dir cfg) name)]
        (println (format "Creating LXC '%s' (VMID: %s, profile: %s, %s)"
                         name vmid prof (if priv? "privileged" "unprivileged")))
        (println "Transferring LXC template to Proxmox...")
        (pc/pve-rsync! cfg tarball (format "%s:%s" (:pve-host cfg) tmpl))
        (pc/pve-ssh! cfg (format (str "pct create %s %s --ostype unmanaged --arch amd64 "
                                      "--unprivileged %s --features %s --cores %s --memory %s "
                                      "--rootfs %s:%s --net0 name=eth0,bridge=%s,hwaddr=%s,ip=dhcp,firewall=%s "
                                      "--hostname %s")
                                 vmid tmpl (if priv? "0" "1") (:lxc-features cfg) vcpus memory
                                 (:pve-storage cfg) (rootfs-gb size) bridge mac (:pve-firewall cfg) hostname))
        (apply-mounts! cfg name vmid)
        (when priv?
          ;; kernel nfsd in a privileged CT needs the apparmor profile relaxed.
          (pc/pve-ssh-soft cfg (format (str "grep -q 'lxc.apparmor.profile' /etc/pve/lxc/%s.conf "
                                            "|| echo 'lxc.apparmor.profile: unconfined' >> /etc/pve/lxc/%s.conf")
                                       vmid vmid)))
        (inject-rootfs! cfg name vmid)
        (pc/sync-firewall! cfg name "lxc")
        (pc/pve-ssh-soft cfg (format "rm -f %s" tmpl))
        (println (format "Created LXC '%s' (VMID: %s)." name vmid))
        (println (format "  Profile: %s, rootfs: %sG on %s" prof (rootfs-gb size) (:pve-storage cfg)))
        (println (format "  Hostname: %s" hostname))))))

;; ─── the record ──────────────────────────────────────────────────────────────

(defrecord Lxc []
  b/Backend
  (create-disks [_ cfg name var-size] (create-ct! cfg name (machine/normalize-size (or var-size "8G"))))
  (create-disks-mutable [_ cfg name disk-size] (create-ct! cfg name (machine/normalize-size (or disk-size "8G"))))

  (sync-identity [this cfg name]
    (pc/validate! cfg)
    (let [vmid (pc/get-vmid cfg name)
          was-running (b/running? this cfg name)]
      (when was-running
        (println "Stopping container for identity sync...")
        (b/force-stop this cfg name)
        (loop [n 0] (when (and (b/running? this cfg name) (< n 30)) (Thread/sleep 1000) (recur (inc n)))))
      (inject-rootfs! cfg name vmid)
      (pc/sync-firewall! cfg name "lxc")
      (println "Identity files synced.")
      (when was-running (println "Restarting container...") (b/start this cfg name))))

  (generate-config [_ cfg name memory vcpus]
    (pc/validate! cfg)
    (let [vmid (pc/get-vmid cfg name)
          memory (or memory "2048") vcpus (or vcpus "2")
          md (machine/machine-dir cfg name)]
      (spit (str md "/memory") (str memory "\n"))
      (spit (str md "/vcpus") (str vcpus "\n"))
      (pc/pve-ssh! cfg (format "pct set %s --memory %s --cores %s" vmid memory vcpus))
      (println (format "Container config updated: memory=%sMB, vcpus=%s" memory vcpus))))

  (define [_ cfg name]
    (println (format "Container '%s' is already defined on Proxmox (VMID: %s)" name (pc/get-vmid cfg name))))

  (undefine [_ cfg name]
    (pc/validate! cfg)
    (let [vmid (pc/get-vmid cfg name)]
      (println (format "Destroying container (VMID: %s)..." vmid))
      (pc/pve-ssh-soft cfg (format "pct stop %s" vmid))
      (pc/pve-ssh-soft cfg (format "pct destroy %s --purge 1 --destroy-unreferenced-disks 1" vmid))
      (fs/delete-if-exists (pc/vmid-file cfg name))
      (println "Container removed from Proxmox.")))

  (start [_ cfg name]
    (pc/validate! cfg)
    (let [vmid (pc/get-vmid cfg name)]
      (println (format "Starting container: %s (VMID: %s)" name vmid))
      (pc/pve-ssh! cfg (format "pct start %s" vmid))))

  (stop [_ cfg name]
    (pc/validate! cfg)
    (let [vmid (pc/get-vmid cfg name)]
      (println (format "Stopping container: %s (VMID: %s)" name vmid))
      (pc/pve-ssh! cfg (format "pct shutdown %s" vmid))))

  (reboot [_ cfg name]
    (pc/validate! cfg)
    (pc/pve-ssh! cfg (format "pct reboot %s" (pc/get-vmid cfg name))))

  (force-stop [_ cfg name]
    (pc/validate! cfg)
    (pc/pve-ssh-soft cfg (format "pct stop %s" (pc/get-vmid cfg name))))

  (status [this cfg name]
    (pc/validate! cfg)
    (let [vmid (pc/get-vmid cfg name)]
      (pc/pve-ssh! cfg (format "pct status %s --verbose" vmid))
      (println)
      (println "IP Address:")
      (let [ip (b/get-ip this cfg name)]
        (println (if (str/blank? ip) "  (not available - container may not be running)" (str "  " ip))))))

  (list-vms [_ cfg]
    (pc/validate! cfg)
    (let [files (sort (fs/glob (:machines-dir cfg) "*/vmid"))
          rows (vec (for [f files
                          :let [md (str (fs/parent f))
                                nm (fs/file-name (fs/parent f))
                                vmid (str/trim (slurp (str f)))]
                          :when (not (str/blank? vmid))]
                      (let [st (try (-> (pc/pve-ssh cfg (format "pct status %s" vmid))
                                        (str/replace #"^status: " "") str/trim)
                                    (catch Exception _ "not found"))]
                        [vmid nm st md])))]
      (if (empty? rows)
        (println "No managed containers found.")
        (b/print-table ["VMID" "NAME" "STATUS" "CONFIG"] rows))))

  (get-ip [_ cfg name]
    (pc/validate! cfg)
    (let [vmid (pc/get-vmid cfg name)
          out (try (pc/pve-ssh cfg (format "lxc-info -n %s -iH 2>/dev/null" vmid)) (catch Exception _ ""))]
      (->> (str/split-lines out)
           (map str/trim)
           (remove str/blank?)
           (remove #(str/includes? % ":"))
           (remove #(str/starts-with? % "127."))
           first)))

  (console [_ cfg name]
    (pc/validate! cfg)
    (let [vmid (pc/get-vmid cfg name)]
      (println (format "Connecting to console for '%s' (VMID: %s)... (Ctrl+a q to exit)" name vmid))
      (proc/run! (concat (pc/ssh-prefix cfg) [(pc/ssh-host cfg) "-t" (format "pct console %s" vmid)]))))

  (snapshot [_ cfg name snap]
    (pc/validate! cfg)
    (pc/pve-ssh! cfg (format "pct snapshot %s %s" (pc/get-vmid cfg name) snap))
    (println (format "Snapshot '%s' created." snap)))

  (restore-snapshot [_ cfg name snap]
    (pc/validate! cfg)
    (pc/pve-ssh! cfg (format "pct rollback %s %s" (pc/get-vmid cfg name) snap))
    (println (format "Container restored to '%s'." snap)))

  (list-snapshots [_ cfg name]
    (pc/validate! cfg)
    (pc/pve-ssh! cfg (format "pct listsnapshot %s" (pc/get-vmid cfg name))))

  (snapshot-count [_ cfg name]
    (pc/validate! cfg)
    (let [out (try (pc/pve-ssh cfg (format "pct listsnapshot %s" (pc/get-vmid cfg name))) (catch Exception _ ""))
          lines (remove str/blank? (str/split-lines out))]
      (count (remove #(re-find #"current" %) lines))))

  (suspend [_ cfg name]
    (pc/validate! cfg)
    (pc/pve-ssh-soft cfg (format "pct suspend %s" (pc/get-vmid cfg name))))

  (resume [_ cfg name]
    (pc/validate! cfg)
    (pc/pve-ssh-soft cfg (format "pct resume %s" (pc/get-vmid cfg name))))

  (running? [_ cfg name]
    (pc/validate! cfg)
    (let [f (pc/vmid-file cfg name)]
      (if-not (fs/exists? f)
        false
        (let [s (try (pc/pve-ssh cfg (format "pct status %s" (str/trim (slurp f)))) (catch Exception _ ""))]
          (str/includes? s "running")))))

  (vm-state [_ cfg name]
    (pc/validate! cfg)
    (let [f (pc/vmid-file cfg name)]
      (if-not (fs/exists? f)
        "undefined"
        (let [s (try (pc/pve-ssh cfg (format "pct status %s" (str/trim (slurp f)))) (catch Exception _ ""))]
          (cond (str/includes? s "running") "running"
                (str/includes? s "stopped") "stopped"
                :else "undefined")))))

  (vm-version [_ cfg name]
    (pc/validate! cfg)
    (let [f (pc/vmid-file cfg name)]
      (when (fs/exists? f)
        (let [vmid (str/trim (slurp f))]
          (try (pc/pve-ssh cfg (format "pct exec %s -- /run/current-system/sw/bin/cat /etc/nixos-image-version 2>/dev/null" vmid))
               (catch Exception _ nil))))))

  (cleanup [_ cfg name] (fs/delete-tree (vm-dir cfg name)))

  (provision! [this cfg name var-size] (b/create-disks this cfg name var-size))
  (provisioned? [_ cfg name] (fs/exists? (pc/vmid-file cfg name))))

;; ─── composites ──────────────────────────────────────────────────────────────

(defn- create-summary! [cfg name profile ip]
  (b/print-create-summary cfg name "mutable" ip
                          (format "Container '%s' created and started on Proxmox (VMID: %s, profile: %s)."
                                  name (pc/get-vmid cfg name) profile)))

(defn- finish-create! [this cfg name]
  (let [profile (or (machine/read-field cfg name "profile") "core")
        var-size (or (machine/read-field cfg name "var_size") "8G")]
    (profile/build-lxc-profile cfg profile)
    (b/create-disks this cfg name var-size)
    (b/start this cfg name)
    (create-summary! cfg name profile (b/wait-for-vm-ip this cfg name))))

(defn create-vm [this cfg name]
  (when (b/running? this cfg name)
    (println (format "Error: Container '%s' is currently running. Destroy it first." name))
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
    (pc/validate! cfg)
    (when-not (fs/directory? src-md)
      (println (format "Error: Source machine config not found: %s" src-md)) (System/exit 1))
    (when (fs/directory? dst-md)
      (println (format "Error: Destination machine config already exists: %s" dst-md)) (System/exit 1))
    (let [memory (if (str/blank? memory) (or (machine/read-field cfg source "memory") "2048") memory)
          vcpus (if (str/blank? vcpus) (or (machine/read-field cfg source "vcpus") "2") vcpus)
          source-vmid (pc/get-vmid cfg source)]
      (when (b/running? this cfg source)
        (println (format "Error: Source container '%s' must be stopped before cloning." source)) (System/exit 1))
      (println (format "Cloning container '%s' -> '%s'" source dest))
      (machine/init-machine-clone cfg source dest network)
      (spit (str dst-md "/memory") (str memory "\n"))
      (spit (str dst-md "/vcpus") (str vcpus "\n"))
      (when (fs/exists? (str src-md "/mounts"))
        (proc/run! ["cp" (str src-md "/mounts") (str dst-md "/mounts")]))
      (when (fs/exists? (str src-md "/privileged"))
        (proc/run! ["cp" (str src-md "/privileged") (str dst-md "/privileged")]))
      (let [dest-vmid (pc/determine-vmid! cfg dest "lxc")
            bridge (pc/bridge-for cfg dest)
            mac (machine/read-field cfg dest "mac-address")]
        (pc/pve-ssh! cfg (format "pct clone %s %s --full 1 --hostname %s --storage %s"
                                 source-vmid dest-vmid dest (:pve-storage cfg)))
        (pc/pve-ssh! cfg (format "pct set %s --net0 name=eth0,bridge=%s,hwaddr=%s,ip=dhcp,firewall=%s" dest-vmid bridge mac (:pve-firewall cfg)))
        (pc/pve-ssh! cfg (format "pct set %s --memory %s --cores %s" dest-vmid memory vcpus))
        (b/sync-identity this cfg dest)
        (println (format "Container '%s' cloned from '%s' (VMID: %s)." dest source dest-vmid))
        (println (format "Start with: BACKEND=proxmox-lxc just start %s" dest))))))

(defn upgrade-vm [_this cfg name]
  ;; LXC is mutable-only. There's no host-side image swap like the KVM backends;
  ;; instead recreate (rootfs is disposable, bind-mounted data is preserved) or
  ;; nixos-rebuild from inside.
  (b/validate-machine! cfg name)
  (println (format "'%s' is an LXC container — there is no host-side upgrade." name))
  (println)
  (println "Pick one of these instead:")
  (println)
  (println "1. Roll out repo changes (updated profiles/modules) — recreate.")
  (println "   Rebuilds the rootfs from the current image (recreate does the build")
  (println "   for you); your host ZFS bind mounts (the data) are NOT touched:")
  (println (format "     BACKEND=proxmox-lxc just recreate %s" name))
  (println)
  (println "2. Ad-hoc changes from inside the container:")
  (println (format "     just ssh admin@%s" name))
  (println "     sudo nixos-rebuild switch")
  (println "   NOTE: /etc/nixos inside the container is a snapshot from create time.")
  (println "   To refresh it with the latest repo profiles/modules first:")
  (println (format "     BACKEND=proxmox-lxc just sync-identity %s" name)))

(defn resize-var [this cfg name size]
  (pc/validate! cfg)
  (let [vmid (pc/get-vmid cfg name)]
    (when (b/running? this cfg name)
      (println (format "Error: Container '%s' must be stopped before resizing." name)) (System/exit 1))
    (println (format "Resizing rootfs to %sG..." (rootfs-gb (machine/normalize-size size))))
    (pc/pve-ssh! cfg (format "pct resize %s rootfs %sG" vmid (rootfs-gb (machine/normalize-size size))))
    (println "Resize complete.")))

(defn resize-vm [this cfg name]
  (pc/validate! cfg)
  (b/validate-machine! cfg name)
  (let [vmid (pc/get-vmid cfg name)
        cur-mem (or (machine/read-field cfg name "memory") "2048")
        cur-vcpus (or (machine/read-field cfg name "vcpus") "2")
        md (machine/machine-dir cfg name)]
    (when (b/running? this cfg name)
      (println (format "Error: Container '%s' must be stopped before resizing." name)) (System/exit 1))
    (println (format "Current: memory=%sMB vcpus=%s" cur-mem cur-vcpus))
    (let [new-mem (let [v (b/prompt-line (format "New memory in MB [%s]: " cur-mem))] (if (str/blank? v) cur-mem v))
          new-vcpus (let [v (b/prompt-line (format "New vCPUs [%s]: " cur-vcpus))] (if (str/blank? v) cur-vcpus v))
          new-disk (b/prompt-line "New rootfs size in GB (blank = unchanged): ")]
      (spit (str md "/memory") (str new-mem "\n"))
      (spit (str md "/vcpus") (str new-vcpus "\n"))
      (pc/pve-ssh! cfg (format "pct set %s --memory %s --cores %s" vmid new-mem new-vcpus))
      (when-not (str/blank? new-disk)
        (pc/pve-ssh! cfg (format "pct resize %s rootfs %sG" vmid (rootfs-gb new-disk))))
      (println "Resize complete."))))

(defn backup-vm [_this cfg name]
  (pc/validate! cfg)
  (let [vmid (pc/get-vmid cfg name)]
    (println (format "Creating backup of container '%s' (VMID: %s) via vzdump..." name vmid))
    (pc/pve-ssh! cfg (format "vzdump %s --mode snapshot --compress zstd --storage %s" vmid (:pve-backup-storage cfg)))
    (println "Backup complete.")))

(defn restore-backup-vm [this cfg name backup-file]
  (pc/validate! cfg)
  (b/validate-machine! cfg name)
  (let [vmid (pc/get-vmid cfg name)
        node (:pve-node cfg)]
    (if (str/blank? backup-file)
      (let [backups (try (pc/pve-ssh cfg (format "pvesh get /nodes/%s/storage/%s/content --content backup --vmid %s --output-format json"
                                                 node (:pve-backup-storage cfg) vmid))
                         (catch Exception _ "[]"))
            parsed (try (json/parse-string backups true) (catch Exception _ []))]
        (if (empty? parsed)
          (do (println "  No backups found.") (System/exit 1))
          (do (doseq [b parsed] (println (format "  %s" (:volid b))))
              (println (format "Specify: BACKEND=proxmox-lxc just restore-backup %s <volid>" name))
              (System/exit 0))))
      (do
        (println (format "WARNING: This replaces container '%s' with backup contents." name))
        (b/confirm-or-abort "Are you sure? [y/N] ")
        (b/force-stop this cfg name)
        (pc/pve-ssh-soft cfg (format "pct destroy %s --purge 1" vmid))
        (pc/pve-ssh! cfg (format "pct restore %s %s --storage %s" vmid backup-file (:pve-storage cfg)))
        (println (format "Restore complete. Start with: BACKEND=proxmox-lxc just start %s" name))))))

(defn ssh-vm [cfg input]
  (let [[ssh-user name] (if (str/includes? input "@") (str/split input #"@" 2) ["user" input])
        ip (b/get-ip (->Lxc) cfg name)]
    (when (str/blank? ip)
      (println (format "Error: Could not determine IP for container '%s'" name)) (System/exit 1))
    (println (format "Connecting to %s at %s as %s..." name ip ssh-user))
    (proc/run! (concat (:ssh cfg) ["-o" "StrictHostKeyChecking=accept-new" (str ssh-user "@" ip)]))))

(defn list-backups [cfg]
  (pc/validate! cfg)
  (let [vmids (->> (fs/glob (:machines-dir cfg) "*/vmid")
                   (map #(str/trim (slurp (str %)))) (remove str/blank?) set)]
    (if (empty? vmids)
      (println "No managed containers found.")
      (let [backups (try (pc/pve-ssh cfg (format "pvesh get /nodes/%s/storage/%s/content --content backup --output-format json"
                                                 (:pve-node cfg) (:pve-backup-storage cfg)))
                         (catch Exception _ "[]"))
            parsed (try (json/parse-string backups true) (catch Exception _ []))
            filtered (filter #(contains? vmids (str (:vmid %))) parsed)]
        (println (format "Backups on '%s' (managed containers):" (:pve-backup-storage cfg)))
        (if (empty? filtered)
          (println "  (none)")
          (doseq [b filtered] (println (format "  %s  VMID=%s" (:volid b) (:vmid b)))))))))
