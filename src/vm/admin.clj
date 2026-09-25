(ns vm.admin
  "Top-level `just admin` menu for host-side administrative tasks that don't
  belong to any individual VM. Currently ships a single submenu — ZFS admin —
  which is read-only in this cut: pools -> datasets (with sanoid policy and
  LXC consumers) -> snapshots. Mutation (create/destroy dataset, attach/edit
  sanoid policy, snapshot lifecycle) lives in follow-ups."
  (:require [clojure.string :as str]
            [vm.prompt :as prompt]
            [vm.backend.pve-common :as pve]))

(def ^:private BACK "← Back")

(defn- pve-backend? [cfg]
  (contains? #{"proxmox" "proxmox-lxc"} (:backend cfg)))

(defn- ssh-quiet
  "pve-ssh that swallows failure (returns \"\"). For optional probes like
  `command -v sanoid` where a non-zero exit is a legitimate answer."
  [cfg cmd]
  (try (pve/pve-ssh cfg cmd) (catch Exception _ "")))

;; ─── zfs introspection ───────────────────────────────────────────────────────

(defn- zpool-list
  "[{:name :size :alloc :free :health} ...] from `zpool list -Hp`."
  [cfg]
  (->> (str/split-lines
        (ssh-quiet cfg "zpool list -Hp -o name,size,alloc,free,health 2>/dev/null"))
       (remove str/blank?)
       (keep (fn [line]
               (let [[name size alloc free health] (str/split line #"\t")]
                 (when name
                   {:name name
                    :size (some-> size Long/parseLong)
                    :alloc (some-> alloc Long/parseLong)
                    :free (some-> free Long/parseLong)
                    :health health}))))
       vec))

(defn- zfs-datasets
  "Datasets under `pool` (recursive), excluding the pool root and PVE-managed
  guest volumes (subvol-<id>-* / vm-<id>-* / base-<id>-*)."
  [cfg pool]
  (->> (str/split-lines
        (ssh-quiet cfg (format "zfs list -Hp -o name,used,available,mountpoint -r %s 2>/dev/null"
                               pool)))
       (remove str/blank?)
       (keep (fn [line]
               (let [[name used avail mount] (str/split line #"\t")]
                 (when name
                   {:name name
                    :used (some-> used Long/parseLong)
                    :available (some-> avail Long/parseLong)
                    :mountpoint mount}))))
       (remove #(= (:name %) pool))
       (remove #(re-find #"/(subvol|vm|base|basevol)-\d+" (:name %)))
       vec))

(defn- zfs-snapshots
  "Snapshots of `dataset` (excluding descendants), newest-first."
  [cfg dataset]
  (let [prefix (str dataset "@")]
    (->> (str/split-lines
          (ssh-quiet cfg (format "zfs list -Hp -t snapshot -o name,used,creation -r %s 2>/dev/null"
                                 dataset)))
         (remove str/blank?)
         (keep (fn [line]
                 (let [[name used creation] (str/split line #"\t")]
                   (when (and name (str/starts-with? name prefix))
                     {:name name
                      :used (some-> used Long/parseLong)
                      :creation (some-> creation Long/parseLong)}))))
         (sort-by :creation >)
         vec)))

;; ─── sanoid config (read-only) ───────────────────────────────────────────────

(defn- sanoid-installed? [cfg]
  (not (str/blank? (ssh-quiet cfg "command -v sanoid 2>/dev/null"))))

(defn- sanoid-config-raw
  "Concatenation of /etc/sanoid/sanoid.conf and /etc/sanoid/sanoid.d/*.conf."
  [cfg]
  (ssh-quiet
   cfg
   (str "cat /etc/sanoid/sanoid.conf 2>/dev/null;"
        " for f in /etc/sanoid/sanoid.d/*.conf; do"
        " [ -f \"$f\" ] && cat \"$f\";"
        " done 2>/dev/null")))

(defn- sanoid-sections
  "Parse a sanoid config into [{:name :recursive?} ...] for dataset sections
  (template_* sections excluded)."
  [raw]
  (let [lines (->> (str/split-lines raw)
                   (map #(str/replace % #"[#;].*$" ""))
                   (map str/trim)
                   (remove str/blank?))]
    (loop [ls lines, cur nil, acc []]
      (if-let [l (first ls)]
        (if-let [sec (second (re-matches #"^\[(.+)\]$" l))]
          (recur (rest ls) {:name sec :recursive? false}
                 (if cur (conj acc cur) acc))
          (let [[_ k v] (re-matches #"^([^=]+?)\s*=\s*(.*)$" l)
                cur' (cond-> cur
                       (and cur (= k "recursive")
                            (contains? #{"yes" "true" "1"} (str/trim (or v ""))))
                       (assoc :recursive? true))]
            (recur (rest ls) cur' acc)))
        (->> (if cur (conj acc cur) acc)
             (remove #(str/starts-with? (:name %) "template_"))
             vec)))))

(defn- policy-for
  "Section covering `dataset` — exact match wins over recursive ancestor."
  [sections dataset]
  (or (some #(when (= (:name %) dataset) %) sections)
      (some (fn [s]
              (when (and (:recursive? s)
                         (str/starts-with? (str dataset "/")
                                           (str (:name s) "/")))
                s))
            sections)))

;; ─── LXC consumers (mpN bind mounts by dataset) ──────────────────────────────

(defn- lxc-consumers
  "Map of dataset -> [{:vmid :name :mount-key :path} ...] harvested from
  /etc/pve/lxc/*.conf. One SSH round trip. Stops parsing at each container's
  first [snapshot] section so snapshot-frozen configs are ignored."
  [cfg]
  (let [raw (ssh-quiet
             cfg
             (str "for f in /etc/pve/lxc/*.conf; do"
                  " [ -f \"$f\" ] && echo \"===$(basename $f .conf)===\""
                  " && cat \"$f\";"
                  " done 2>/dev/null"))]
    (loop [lines (str/split-lines raw)
           vmid nil, name nil, in-snap? false, acc {}]
      (if-let [l (first lines)]
        (let [hdr (re-matches #"^===(\d+)===$" l)
              sect (re-matches #"^\[.+\]\s*$" l)
              host (re-matches #"^hostname:\s*(.+)$" l)
              mp (re-matches #"^(mp\d+):\s*(.+)$" l)]
          (cond
            hdr   (recur (rest lines) (second hdr) nil false acc)
            sect  (recur (rest lines) vmid name true acc)
            in-snap? (recur (rest lines) vmid name in-snap? acc)
            host  (recur (rest lines) vmid (str/trim (second host)) in-snap? acc)
            mp    (let [[src & opts] (str/split (nth mp 2) #",")
                        src (some-> src str/trim)
                        path (some #(second (re-matches #"^\s*mp=(.+)$" %)) opts)]
                    (if (and vmid (not (str/blank? src))
                             (not (str/starts-with? src "/"))
                             (not (re-find #"/(subvol|vm|base|basevol)-\d+" src))
                             (not (str/includes? src ":")))
                      (recur (rest lines) vmid name in-snap?
                             (update acc src (fnil conj [])
                                     {:vmid vmid :name (or name "?")
                                      :mount-key (second mp) :path path}))
                      (recur (rest lines) vmid name in-snap? acc)))
            :else (recur (rest lines) vmid name in-snap? acc)))
        acc))))

;; ─── formatting ──────────────────────────────────────────────────────────────

(defn- fmt-bytes
  "Base-2 human bytes. nil -> '?'."
  [n]
  (if (nil? n) "?"
      (let [units ["B" "K" "M" "G" "T" "P"]]
        (loop [x (double n) i 0]
          (if (or (< x 1024.0) (= i (dec (count units))))
            (format (if (< x 10.0) "%.1f%s" "%.0f%s") x (nth units i))
            (recur (/ x 1024.0) (inc i)))))))

(defn- fmt-epoch [s]
  (if (nil? s) "?"
      (-> (java.time.Instant/ofEpochSecond s)
          (.atZone (java.time.ZoneId/systemDefault))
          (.format (java.time.format.DateTimeFormatter/ofPattern "yyyy-MM-dd HH:mm")))))

;; ─── views ───────────────────────────────────────────────────────────────────

(defn- view-snapshots [cfg dataset]
  (println)
  (println (format "── Snapshots: %s ──" dataset))
  (let [snaps (zfs-snapshots cfg dataset)]
    (if (empty? snaps)
      (println "  (no snapshots)")
      (doseq [s snaps]
        (println (format "  %-60s  used=%-8s  %s"
                         (:name s)
                         (fmt-bytes (:used s))
                         (fmt-epoch (:creation s))))))
    (println)
    (prompt/choose "" [BACK])))

(defn- view-pool [cfg pool consumers sections sanoid?]
  (loop []
    (println)
    (println (format "── Pool: %s ──" pool))
    (let [dss (zfs-datasets cfg pool)]
      (if (empty? dss)
        (do (println "  (no child datasets)")
            (prompt/choose "" [BACK]))
        (let [rows (mapv (fn [d]
                           (let [pol (when sanoid? (policy-for sections (:name d)))
                                 cons (get consumers (:name d))
                                 policy-str (cond
                                              (not sanoid?) ""
                                              pol (format "  policy=%s%s"
                                                          (:name pol)
                                                          (if (:recursive? pol) " (rec)" ""))
                                              :else "  policy=(none)")
                                 cons-str (if (seq cons)
                                            (str "  → "
                                                 (str/join ", "
                                                           (map #(format "%s (CT %s)"
                                                                         (:name %) (:vmid %))
                                                                cons)))
                                            "")]
                             {:dataset d
                              :label (format "%-40s  used=%-8s  avail=%-8s%s%s"
                                             (:name d)
                                             (fmt-bytes (:used d))
                                             (fmt-bytes (:available d))
                                             policy-str
                                             cons-str)}))
                         dss)
              labels (conj (mapv :label rows) BACK)
              pick (prompt/choose "Select a dataset for details:" labels)]
          (when (not= pick BACK)
            (let [chosen (some #(when (= (:label %) pick) (:dataset %)) rows)]
              (view-snapshots cfg (:name chosen))
              (recur))))))))

(defn- zfs-admin [cfg]
  (println)
  (println "── ZFS Admin ──")
  (let [pools (zpool-list cfg)]
    (if (empty? pools)
      (do (println (format "No ZFS pools found on %s (or the host has no ZFS)."
                           (or (:pve-node cfg) "the PVE node")))
          (prompt/choose "" [BACK]))
      (let [sanoid? (sanoid-installed? cfg)
            sections (if sanoid? (sanoid-sections (sanoid-config-raw cfg)) [])
            consumers (lxc-consumers cfg)]
        (when-not sanoid?
          (println "(sanoid not installed on host — policy column hidden)"))
        (loop []
          (let [rows (mapv (fn [p]
                             {:pool p
                              :label (format "%-16s  size=%-8s  free=%-8s  %s"
                                             (:name p)
                                             (fmt-bytes (:size p))
                                             (fmt-bytes (:free p))
                                             (or (:health p) "?"))})
                           pools)
                labels (conj (mapv :label rows) BACK)
                pick (prompt/choose "Select a ZFS pool:" labels)]
            (when (not= pick BACK)
              (let [pool-name (:name (:pool (some #(when (= (:label %) pick) %) rows)))]
                (view-pool cfg pool-name consumers sections sanoid?)
                (recur)))))))))

;; ─── main menu ───────────────────────────────────────────────────────────────

(defn main-menu
  "Interactive top-level admin menu. The ZFS entry appears only on PVE
  backends (proxmox / proxmox-lxc); other backends see only the Quit option
  with an explanatory note."
  [cfg]
  (let [pve? (pve-backend? cfg)]
    (loop []
      (println)
      (println "── Admin ──")
      (when-not pve?
        (println (format "(backend: %s — ZFS admin is PVE-only and hidden)"
                         (:backend cfg))))
      (let [items (cond-> []
                    pve? (conj "ZFS admin")
                    true (conj "Quit"))
            pick (prompt/choose "" items)]
        (cond
          (= pick "ZFS admin") (do (zfs-admin cfg) (recur))
          (= pick "Quit") nil)))))
