(ns vm.net
  "Network configuration (nat / bridge:NAME / interactive bridge selection).
  Ports network_config and network_config_interactive from common.sh. The
  numbered prompts here use plain stdin reads, matching the Bash `read -p`."
  (:require [clojure.string :as str]
            [babashka.fs :as fs]))

(defn- machine-dir [cfg name] (str (:machines-dir cfg) "/" name))

(defn- read-field [cfg name field]
  (let [f (str (machine-dir cfg name) "/" field)]
    (when (fs/exists? f) (str/trim (slurp f)))))

(defn- prompt-line
  "Print a prompt (no newline) and read a line from stdin."
  [msg]
  (print msg)
  (flush)
  (or (read-line) ""))

(defn local-bridges
  "List local bridge interfaces, excluding libvirt's virbr*, docker*, br-* and
  fwbr* (the Bash uses the same /sys/class/net/*/bridge scan)."
  []
  (->> (fs/glob "/sys/class/net" "*/bridge")
       (map #(fs/file-name (fs/parent %)))
       (remove #(re-matches #"(virbr[0-9]+|docker[0-9]*|br-.*|fwbr.*)" %))
       sort
       vec))

(defn network-config
  "Set network configuration for a machine. `network` is nat, bridge:<name>, or
  bare bridge (interactive numbered selection of local bridges)."
  [cfg name network]
  (let [machine-dir (machine-dir cfg name)]
    (fs/create-dirs machine-dir)
    (cond
      (= network "nat")
      (do (spit (str machine-dir "/network") "nat\n")
          (println "Network configured: nat"))

      (str/starts-with? network "bridge:")
      (do (spit (str machine-dir "/network") (str network "\n"))
          (println (format "Network configured: %s" network)))

      (= network "bridge")
      (let [bridges (local-bridges)]
        (when (empty? bridges)
          (println "Error: No bridge interfaces found (excluding virbr0 and docker bridges).")
          (println)
          (println "To use bridged networking, you need to create a bridge interface first.")
          (println "This bridge should include your physical network interface.")
          (println)
          (println "NOTE: WiFi interfaces cannot be bridged (802.11 does not support L2")
          (println "bridging). If you only have WiFi, use NAT networking instead.")
          (println)
          (println "Example using NetworkManager (wired ethernet only):")
          (println "  nmcli connection add type bridge ifname br0 con-name br0")
          (println "  nmcli connection add type bridge-slave ifname eth0 master br0")
          (println)
          (println "After creating a bridge, run this command again.")
          (System/exit 1))
        (println)
        (println "Available bridge interfaces:")
        (doseq [[i br] (map-indexed vector bridges)]
          (println (format "  %d) %s" (inc i) br)))
        (println)
        (let [sel (prompt-line (format "Select bridge [1-%d]: " (count bridges)))]
          (if (and (re-matches #"[0-9]+" sel)
                   (<= 1 (parse-long sel) (count bridges)))
            (let [chosen (nth bridges (dec (parse-long sel)))]
              (spit (str machine-dir "/network") (str "bridge:" chosen "\n"))
              (println (format "Network configured: bridge:%s" chosen)))
            (do (println "Invalid selection.")
                (System/exit 1)))))

      :else
      (do (println (format "Error: Invalid network config '%s'. Use 'nat', 'bridge', or 'bridge:<name>'" network))
          (System/exit 1)))))

(defn network-config-interactive
  "Show current network config and prompt for a mode, then apply it."
  [cfg name network]
  (let [machine-dir (machine-dir cfg name)]
    (when-not (fs/directory? machine-dir)
      (println (format "Error: Machine config not found: %s" machine-dir))
      (println (format "Create the VM first with 'just create %s'" name))
      (System/exit 1))
    (let [current (or (read-field cfg name "network") "nat")
          network (if (str/blank? network)
                    (do (println (format "Current network config: %s" current))
                        (println)
                        (println "Select network mode:")
                        (println "  1) nat - NAT networking via libvirt (default)")
                        (println "  2) bridge - Bridged networking to physical network")
                        (println)
                        (case (prompt-line "Selection [1-2]: ")
                          "1" "nat"
                          "2" "bridge"
                          (do (println "Invalid selection.") (System/exit 1))))
                    network)]
      (network-config cfg name network))))
