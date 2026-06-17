(ns vm.mutable
  "Shared preparation of a mutable VM's single read-write disk: copy the base
  image, resize, and use guestfish to write hostname/machine-id, SSH keys,
  firewall ports, network config, root password, and an /etc/nixos flake for
  nixos-rebuild. Identical between libvirt and proxmox (both build the disk
  locally; proxmox then transfers it)."
  (:require [clojure.string :as str]
            [babashka.fs :as fs]
            [vm.proc :as proc]
            [vm.machine :as machine]
            [vm.profile :as profile]))

(defn generate-mutable-flake
  "flake.nix content for an /etc/nixos mutable VM (nixos-rebuild)."
  [hostname system profile-str]
  (let [imports (apply str (map #(str "          ./profiles/" % ".nix\n")
                                (str/split profile-str #",")))]
    (str "{\n"
         "  description = \"NixOS VM configuration\";\n\n"
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
         "          # Core modules (see modules/default.nix)\n"
         "          ./modules\n"
         "          home-manager.nixosModules.home-manager\n"
         "          # Profile modules\n"
         imports
         "          # VM-specific settings\n"
         "          {\n"
         "            vm.mutable = true;\n"
         "            networking.hostName = \"" hostname "\";\n"
         "          }\n"
         "        ];\n"
         "      };\n"
         "    };\n"
         "}\n")))

(defn- c [& toks] (cons ":" (map str toks)))

(defn- non-empty? [path] (and (fs/regular-file? path) (pos? (fs/size path))))

(defn- gf!
  "Run guestfish on disk with the given token seq, LIBGUESTFS_BACKEND set."
  [cfg disk tokens]
  (proc/run! (concat (:guestfish cfg) ["-a" disk] tokens)
             {:extra-env {"LIBGUESTFS_BACKEND" (:libguestfs-backend cfg)}}))

(defn- detect-system []
  (case (proc/capture ["uname" "-m"])
    "x86_64" "x86_64-linux"
    "aarch64" "aarch64-linux"
    "x86_64-linux"))

(defn prepare-disk!
  "Copy the profile base image to disk-path, resize, and populate identity and
  the nixos-rebuild flake. Exits on missing image or unreadable nixos partition."
  [cfg name disk-size disk-path]
  (let [md (machine/machine-dir cfg name)
        prof (profile/normalize-profiles (machine/read-field cfg name "profile"))
        repo (:repo-dir cfg)
        img (str (proc/capture (concat (:readlink cfg) ["-f" (str (:output-dir cfg) "/profiles/" prof)]))
                 "/nixos.qcow2")]
    (println (format "Creating VM disk: %s (profile: %s, mutable)" name prof))
    (fs/create-dirs (fs/parent disk-path))
    (when-not (fs/regular-file? img)
      (println (format "Error: Mutable profile image not found: %s" img))
      (println (format "Run 'just build %s' first" prof))
      (System/exit 1))
    (println "Copying base image (this may take a moment)...")
    (proc/run! (concat (:cp cfg) [img disk-path]))
    (proc/run! ["chmod" "644" disk-path])
    (println (format "Resizing disk to %s..." disk-size))
    (proc/run! (concat (:qemu-img cfg) ["resize" disk-path disk-size]))
    (let [hostname (machine/read-field cfg name "hostname")
          machine-id (machine/read-field cfg name "machine-id")
          tmp (str (fs/create-temp-dir))]
      (println "Configuring mutable VM...")
      (spit (str tmp "/hostname") (str hostname "\n"))
      (spit (str tmp "/machine-id") (str machine-id "\n"))
      (let [nixos-dev (proc/capture (concat (:guestfish cfg) ["--ro" "-a" disk-path])
                                    {:in "run\nfindfs-label nixos\n"
                                     :extra-env {"LIBGUESTFS_BACKEND" (:libguestfs-backend cfg)}})]
        (when (str/blank? nixos-dev)
          (println "Error: Could not find nixos partition")
          (fs/delete-tree tmp)
          (System/exit 1))
        (println (format "  Found nixos partition: %s" nixos-dev))
        ;; chain 1: hostname/machine-id + authorized_keys.d + firewall-ports + network-config
        (let [admin (str md "/admin_authorized_keys")
              user (str md "/user_authorized_keys")
              admin-tmp (str tmp "/admin")
              user-tmp (str tmp "/user")
              keyfilter (fn [src dst]
                          (when (non-empty? src)
                            (spit dst (str (->> (str/split-lines (slurp src))
                                                (remove #(or (str/starts-with? % "#") (str/blank? %)))
                                                (str/join "\n"))
                                           "\n"))))
              _ (keyfilter admin admin-tmp)
              _ (keyfilter user user-tmp)
              akeys (fn [tmp-file leaf]
                      (when (non-empty? tmp-file)
                        (concat (c "mkdir-p" "/etc/ssh/authorized_keys.d")
                                (c "chown" "0" "0" "/etc/ssh/authorized_keys.d")
                                (c "chmod" "0755" "/etc/ssh/authorized_keys.d")
                                (c "copy-in" tmp-file "/etc/ssh/authorized_keys.d/")
                                (c "chmod" "0644" (str "/etc/ssh/authorized_keys.d/" leaf))
                                (c "chown" "0" "0" (str "/etc/ssh/authorized_keys.d/" leaf)))))
              fwfile (fn [leaf]
                       (let [src (str md "/" leaf)]
                         (when (non-empty? src)
                           (concat (c "copy-in" src "/etc/firewall-ports/")
                                   (c "chmod" "0644" (str "/etc/firewall-ports/" leaf))
                                   (c "chown" "0" "0" (str "/etc/firewall-ports/" leaf))))))
              static-ip (str md "/static_ip")
              resolv (str md "/resolv.conf")
              net-cmds (when (non-empty? static-ip)
                         (concat (c "mkdir-p" "/etc/network-config")
                                 (c "chown" "0" "0" "/etc/network-config")
                                 (c "chmod" "0755" "/etc/network-config")
                                 (c "copy-in" static-ip "/etc/network-config/")
                                 (c "chmod" "0644" "/etc/network-config/static_ip")
                                 (c "chown" "0" "0" "/etc/network-config/static_ip")
                                 (when (non-empty? resolv)
                                   (concat (c "copy-in" resolv "/etc/network-config/")
                                           (c "chmod" "0644" "/etc/network-config/resolv.conf")
                                           (c "chown" "0" "0" "/etc/network-config/resolv.conf")))))]
          (gf! cfg disk-path
               (concat ["run"]
                       (c "mount" nixos-dev "/")
                       (c "copy-in" (str tmp "/hostname") "/etc/")
                       (c "copy-in" (str tmp "/machine-id") "/etc/")
                       (c "chmod" "0644" "/etc/hostname")
                       (c "chown" "0" "0" "/etc/hostname")
                       (c "chmod" "0444" "/etc/machine-id")
                       (c "chown" "0" "0" "/etc/machine-id")
                       (akeys admin-tmp "admin")
                       (akeys user-tmp "user")
                       (c "mkdir-p" "/etc/firewall-ports")
                       (c "chown" "0" "0" "/etc/firewall-ports")
                       (c "chmod" "0755" "/etc/firewall-ports")
                       (fwfile "tcp_ports")
                       (fwfile "udp_ports")
                       (fwfile "allowed_cidrs")
                       net-cmds)))
        ;; chain 2: root password hash
        (let [rph (str md "/root_password_hash")]
          (when (non-empty? rph)
            (gf! cfg disk-path
                 (concat ["run"] (c "mount" nixos-dev "/")
                         (c "copy-in" rph "/etc/")
                         (c "chmod" "0600" "/etc/root_password_hash")
                         (c "chown" "0" "0" "/etc/root_password_hash")))))
        ;; chain 3: /etc/nixos flake + modules + profiles
        (spit (str tmp "/flake.nix") (generate-mutable-flake hostname (detect-system) prof))
        (proc/run! ["cp" (str repo "/flake.lock") (str tmp "/flake.lock")])
        (proc/run! ["cp" "-r" "--no-preserve=mode" (str repo "/modules") (str tmp "/modules")])
        (proc/run! ["cp" "-r" "--no-preserve=mode" (str repo "/profiles") (str tmp "/profiles")])
        (gf! cfg disk-path
             (concat ["run"] (c "mount" nixos-dev "/")
                     (c "copy-in" (str tmp "/flake.nix") "/etc/nixos/")
                     (c "copy-in" (str tmp "/flake.lock") "/etc/nixos/")
                     (c "copy-in" (str tmp "/modules") "/etc/nixos/")
                     (c "copy-in" (str tmp "/profiles") "/etc/nixos/")
                     (c "chmod" "0644" "/etc/nixos/flake.nix")
                     (c "chmod" "0644" "/etc/nixos/flake.lock")))
        (fs/delete-tree tmp)))))
