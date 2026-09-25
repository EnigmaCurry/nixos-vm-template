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

(defn- first-token
  "First whitespace-separated token of a string. script-wizard trims and can
  reflow the labels it echoes back to us, so we key selections off the leading
  identifier (pool/dataset/snapshot name) rather than exact label equality —
  same pattern as vm.wizard uses for bridge picks."
  [s]
  (first (str/split (str s) #"\s+")))

;; script-wizard signals cancel (ESC / Ctrl-C) by raising through the pod. In
;; a nested menu we want that to unwind one level, not blow the whole CLI out
;; with a non-zero exit — so these wrappers translate cancel into the same
;; value the caller would produce by explicitly picking BACK / leaving the
;; field blank / answering \"no\". Existing menu loops already handle those
;; cases, so no call-site logic changes.
;;
;; We catch Throwable (not just Exception) because the pod's cancel path may
;; surface as things outside the Exception hierarchy — broken-pipe errors if
;; the pod subprocess exits, sci-level throwables, etc. NIXOS_VM_DEBUG=1
;; logs the caught throwable to *err* so we can diagnose future surprises
;; without having to widen the catch again.

(defn- debug? [] (contains? #{"1" "true" "yes"} (System/getenv "NIXOS_VM_DEBUG")))

(defn- log-cancel! [tag t-or-v]
  (when (debug?)
    (binding [*out* *err*]
      (if (instance? Throwable t-or-v)
        (println (format "admin: %s caught: %s: %s"
                         tag (.getSimpleName (class t-or-v)) (.getMessage t-or-v)))
        (println (format "admin: %s returned nil (pod signalled cancel via :value nil)" tag))))))

(defn- choose-or-back
  ([msg items]
   (let [r (try (prompt/choose msg items) (catch Throwable t (log-cancel! "choose" t) nil))]
     (if (nil? r) (do (log-cancel! "choose" nil) BACK) r)))
  ([msg items default]
   (let [r (try (prompt/choose msg items default) (catch Throwable t (log-cancel! "choose" t) nil))]
     (if (nil? r) (do (log-cancel! "choose" nil) BACK) r))))

(defn- ask-or-nil
  ([msg] (try (prompt/ask msg) (catch Throwable t (log-cancel! "ask" t) nil)))
  ([msg default] (try (prompt/ask msg default) (catch Throwable t (log-cancel! "ask" t) nil))))

(defn- confirm-or-no
  ([msg]
   (let [r (try (prompt/confirm msg) (catch Throwable t (log-cancel! "confirm" t) nil))]
     (if (nil? r) false r)))
  ([msg default]
   (let [r (try (prompt/confirm msg default) (catch Throwable t (log-cancel! "confirm" t) nil))]
     (if (nil? r) false r))))

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

;; ─── snapshot lifecycle ──────────────────────────────────────────────────────

(defn- default-snapshot-name []
  (str "manual-"
       (-> (java.time.LocalDateTime/now)
           (.format (java.time.format.DateTimeFormatter/ofPattern "yyyyMMdd-HHmm")))))

(defn- valid-snapshot-name?
  "Restrict snapshot names to characters ZFS accepts *and* that survive
  substitution into a remote ssh command without quoting. Reject @ and /."
  [s]
  (boolean (and (not (str/blank? s))
                (re-matches #"[A-Za-z0-9_\-.:]+" s))))

(defn- snapshot-label [s]
  (format "%-60s  used=%-8s  %s"
          (:name s) (fmt-bytes (:used s)) (fmt-epoch (:creation s))))

(defn- create-snapshot! [cfg dataset]
  (when-let [snap-name (loop []
                         (let [raw (ask-or-nil "Snapshot name:" (default-snapshot-name))]
                           (when raw
                             (let [v (str/trim raw)]
                               (cond
                                 (str/blank? v) (recur)
                                 (not (valid-snapshot-name? v))
                                 (do (println "  invalid — use letters, digits, and _-.: only")
                                     (recur))
                                 :else v)))))]
    (let [full (str dataset "@" snap-name)]
      (when (confirm-or-no (format "Create snapshot %s?" full) :yes)
        (if (pve/pve-ssh-soft cfg (format "zfs snapshot %s" full))
          (println (format "  ✓ created %s" full))
          (println "  ✗ zfs snapshot failed — see error above"))))))

(defn- destroy-snapshot! [cfg snaps]
  (let [labels (mapv snapshot-label snaps)
        pick (choose-or-back "Destroy which snapshot?" (conj labels BACK))]
    (when (not= pick BACK)
      (let [key (first-token pick)
            chosen (some #(when (= (:name %) key) %) snaps)
            full (:name chosen)]
        (when (confirm-or-no (format "Destroy %s? This CANNOT be undone." full) :no)
          (if (pve/pve-ssh-soft cfg (format "zfs destroy %s" full))
            (println (format "  ✓ destroyed %s" full))
            (println "  ✗ zfs destroy failed — see error above")))))))

(defn- show-restore-paths [dataset-map consumers snaps]
  (let [labels (mapv snapshot-label snaps)
        pick (choose-or-back "Show restore paths for which snapshot?"
                            (conj labels BACK))]
    (when (not= pick BACK)
      (let [key (first-token pick)
            chosen (some #(when (= (:name %) key) %) snaps)
            snap-name (second (str/split (:name chosen) #"@"))
            mount (or (:mountpoint dataset-map) (str "/" (:name dataset-map)))
            host-path (str mount "/.zfs/snapshot/" snap-name)
            cons (get consumers (:name dataset-map))]
        (println)
        (println (format "Snapshot: %s" (:name chosen)))
        (println "Read-only view of the dataset at that instant:")
        (println (format "  Host:                %s/" host-path))
        (doseq [c cons]
          (println (format "  CT %s (%s):%s%s/.zfs/snapshot/%s/"
                           (:vmid c) (:name c)
                           (apply str (repeat (max 1 (- 8 (count (:vmid c)) (count (or (:name c) "")))) " "))
                           (:path c) snap-name)))
        (println)
        (println "Copy files back with e.g.:")
        (println (format "  cp -a %s/some/file /target/" host-path))
        (println)
        (choose-or-back "" [BACK])))))

;; ─── views ───────────────────────────────────────────────────────────────────

(defn- view-snapshots [cfg dataset-map consumers]
  (loop []
    (let [dataset (:name dataset-map)
          snaps (zfs-snapshots cfg dataset)]
      (println)
      (println (format "── Snapshots: %s ──" dataset))
      (if (empty? snaps)
        (println "  (no snapshots)")
        (doseq [s snaps] (println (str "  " (snapshot-label s)))))
      (println)
      (let [items (cond-> ["Create snapshot"]
                    (seq snaps) (into ["Destroy snapshot"
                                       "Show restore paths for a snapshot"])
                    :always (conj BACK))
            pick (choose-or-back "" items)]
        (case pick
          "Create snapshot"                     (do (create-snapshot! cfg dataset) (recur))
          "Destroy snapshot"                    (do (destroy-snapshot! cfg snaps) (recur))
          "Show restore paths for a snapshot"   (do (show-restore-paths dataset-map consumers snaps) (recur))
          nil)))))

(defn- view-pool [cfg pool consumers sections sanoid?]
  (loop []
    (println)
    (println (format "── Pool: %s ──" pool))
    (let [dss (zfs-datasets cfg pool)]
      (if (empty? dss)
        (do (println "  (no child datasets)")
            (choose-or-back "" [BACK]))
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
              pick (choose-or-back "Select a dataset for details:" labels)]
          (when (not= pick BACK)
            (let [key (first-token pick)
                  chosen (some #(when (= (:name (:dataset %)) key) (:dataset %)) rows)]
              (view-snapshots cfg chosen consumers)
              (recur))))))))

(defn- zfs-admin [cfg]
  (println)
  (println "── ZFS Admin ──")
  (let [pools (zpool-list cfg)]
    (if (empty? pools)
      (do (println (format "No ZFS pools found on %s (or the host has no ZFS)."
                           (or (:pve-node cfg) "the PVE node")))
          (choose-or-back "" [BACK]))
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
                pick (choose-or-back "Select a ZFS pool:" labels)]
            (when (not= pick BACK)
              (let [pool-name (first-token pick)]
                (view-pool cfg pool-name consumers sections sanoid?)
                (recur)))))))))

;; ─── main menu ───────────────────────────────────────────────────────────────

(defn main-menu
  "Interactive top-level admin menu. The ZFS entry appears only on PVE
  backends (proxmox / proxmox-lxc); other backends see only the Quit option
  with an explanatory note. Top-level Throwable catch prints the type/message
  and unwinds cleanly rather than propagating out to cli.clj's -main (which
  would exit non-zero) — belt-and-suspenders on top of the per-prompt catches."
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
            pick (choose-or-back "" items)]
        (cond
          (= pick "ZFS admin")
          (do (try (zfs-admin cfg)
                   (catch Throwable t
                     (binding [*out* *err*]
                       (println (format "admin: unwound to main menu (%s: %s)"
                                        (.getSimpleName (class t)) (.getMessage t))))))
              (recur))
          (= pick "Quit") nil)))))
