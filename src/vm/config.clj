(ns vm.config
  "Reproduces the `${VAR:-default}` environment surface of the three backend
  scripts (common.sh + libvirt.sh + proxmox.sh headers) so machine-dir locations
  and tool invocations stay byte-compatible with the Bash implementation.

  Tool commands (nix, virsh, qemu-img, ...) are resolved to argument *vectors*
  including any HOST_CMD / SUDO prefix tokens, per vm.proc's contract."
  (:require [clojure.string :as str]
            [babashka.fs :as fs]
            [babashka.process :as p]))

(defn- env
  "Read an env var with bash `:-` semantics: blank (unset OR empty) -> default."
  ([k] (env k nil))
  ([k default]
   (let [v (System/getenv k)]
     (if (str/blank? v) default v))))

(defn- tokens
  "Split a command string into non-blank whitespace-separated tokens."
  [s]
  (->> (str/split (str/trim (or s "")) #"\s+")
       (remove str/blank?)))

(defn- tool
  "Resolve a tool command to an argv vector. An explicit env override is
  tokenized verbatim; otherwise `base` is prefixed with the given prefix
  strings (each may be blank/multi-word, e.g. HOST_CMD, SUDO)."
  [override prefixes base]
  (if-not (str/blank? override)
    (vec (tokens override))
    (vec (concat (mapcat tokens prefixes) [base]))))

(defn- sh-out
  "Run a command capturing trimmed stdout; return \"\" on any failure."
  [& args]
  (try (str/trim (:out (apply p/shell {:out :string :err :string} args)))
       (catch Exception _ "")))

(defn- hostname-s [] (sh-out "hostname" "-s"))

(defn- in-libvirt-group? []
  (let [groups (tokens (sh-out "id" "-nG"))]
    (boolean (some #(= % "libvirt") groups))))

(defn- first-existing
  "Return the first path that is an existing regular file, or \"\"."
  [paths]
  (or (first (filter #(fs/regular-file? %) paths)) ""))

(defn- detect-ovmf-code []
  (first-existing ["/usr/share/edk2/ovmf/OVMF_CODE.fd"
                   "/usr/share/OVMF/OVMF_CODE.fd"
                   "/usr/share/edk2/x64/OVMF_CODE.4m.fd"]))

(defn- detect-ovmf-vars []
  (first-existing ["/usr/share/edk2/ovmf/OVMF_VARS.fd"
                   "/usr/share/OVMF/OVMF_VARS.fd"
                   "/usr/share/edk2/x64/OVMF_VARS.4m.fd"]))

(defn load-config
  "Build the resolved config map for the given backend (\"libvirt\"|\"proxmox\")."
  [backend]
  (let [host-cmd (env "HOST_CMD" "")
        sudo (env "SUDO" (if (in-libvirt-group?) "" "sudo"))
        home (env "HOME" "")
        xdg-data (env "XDG_DATA_HOME" (str home "/.local/share"))
        xdg-config (env "XDG_CONFIG_HOME" (str home "/.config"))
        output-dir (env "OUTPUT_DIR" (str xdg-data "/nixos-vm-template"))
        machines-base (env "NIXOS_VM_MACHINES_DIR"
                           (str xdg-config "/nixos-vm-template/machines"))
        host (env "HOST" (hostname-s))
        machines-dir (env "MACHINES_DIR"
                          (if backend
                            (str machines-base "/" backend "/" host)
                            machines-base))
        base {:backend backend
              :host-cmd host-cmd
              :sudo sudo
              :host host
              :repo-dir (System/getProperty "user.dir")
              :output-dir output-dir
              :machines-dir machines-dir
              ;; Per-VM disk dir, scoped by backend/host (mirrors machines-dir) so
              ;; a libvirt and a proxmox VM of the same name don't collide on disk.
              :vms-dir (str output-dir "/vms/" backend "/" host)
              :nix (tool (env "NIX") [host-cmd] "nix")
              :ssh (tool (env "SSH") [host-cmd] "ssh")
              :readlink (tool (env "READLINK") [host-cmd] "readlink")
              :cp (tool (env "CP") [host-cmd] "cp")}]
    (merge
     base
     (case backend
       "libvirt"
       {:virsh (tool (env "VIRSH") [host-cmd sudo] "virsh")
        :qemu-img (tool (env "QEMU_IMG") [host-cmd] "qemu-img")
        :guestfish (tool (env "GUESTFISH") [host-cmd] "guestfish")
        :libvirt-uri (env "LIBVIRT_URI" "qemu:///system")
        :libvirt-dir (env "LIBVIRT_DIR" "libvirt")
        :libguestfs-backend (env "LIBGUESTFS_BACKEND" "direct")
        :ovmf-code (env "OVMF_CODE" (detect-ovmf-code))
        :ovmf-vars (env "OVMF_VARS" (detect-ovmf-vars))}

       "proxmox"
       {:pve-host (env "PVE_HOST" "")
        :pve-node (env "PVE_NODE" (env "PVE_HOST" ""))
        :pve-storage (env "PVE_STORAGE" "local")
        :pve-bridge (env "PVE_BRIDGE" "vmbr0")
        :pve-disk-format (env "PVE_DISK_FORMAT" "qcow2")
        :pve-firewall (env "PVE_FIREWALL" "1")
        :pve-backup-storage (env "PVE_BACKUP_STORAGE" "local")
        :pve-staging-dir (env "PVE_STAGING_DIR" "/tmp/nixos-vm-staging")
        :qemu-img (tool (env "QEMU_IMG") [host-cmd] "qemu-img")
        :guestfish (tool (env "GUESTFISH") [host-cmd] "guestfish")
        :libguestfs-backend (env "LIBGUESTFS_BACKEND" "direct")}

       ;; Proxmox LXC backend: shares the PVE-over-SSH surface with "proxmox"
       ;; (pct/pvesh/zfs over ssh), plus LXC-specific knobs. No qcow/guestfish:
       ;; the rootfs is a tarball and identity is injected via `pct mount`.
       "proxmox-lxc"
       {:pve-host (env "PVE_HOST" "")
        :pve-node (env "PVE_NODE" (env "PVE_HOST" ""))
        ;; rootfs storage for the container — MUST be a CT-capable storage
        ;; (zfspool or dir), e.g. local-zfs / rust; NOT a bare ZFS pool name.
        :pve-storage (env "PVE_STORAGE" "local")
        :pve-bridge (env "PVE_BRIDGE" "vmbr0")
        :pve-firewall (env "PVE_FIREWALL" "1")
        :pve-backup-storage (env "PVE_BACKUP_STORAGE" "local")
        :pve-staging-dir (env "PVE_STAGING_DIR" "/tmp/nixos-vm-staging")
        :pve-template-dir (env "PVE_TEMPLATE_DIR" "/var/lib/vz/template/cache")
        :lxc-features (env "LXC_FEATURES" "nesting=1")}

       {}))))
