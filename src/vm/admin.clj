(ns vm.admin
  "Top-level `just admin` menu for host-side administrative tasks that don't
  belong to any individual VM. Currently ships a single submenu — ZFS admin —
  which drills pools -> datasets (with sanoid policy and LXC consumers) ->
  snapshots. Supports creating datasets, taking/destroying snapshots, and
  setting / changing / removing sanoid snapshot policies (policies are only
  written to /etc/sanoid/sanoid.d/nixos-vm-template.conf; policies defined
  elsewhere are read-only from the admin menu's perspective)."
  (:require [clojure.string :as str]
            [babashka.process :as p]
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

;; script-wizard's babashka pod (which vm.prompt uses everywhere else) signals
;; cancel (ESC / Ctrl-C) by sending a shutdown message to bb — which calls
;; System/exit directly, bypassing every try/catch. Not usable for menu-style
;; UIs where cancel should unwind one level.
;;
;; Workaround: for admin.clj only, shell out to script-wizard's CLI mode via
;; babashka.process. Cancel becomes a non-zero exit code that :continue true
;; returns as data — no way for the subprocess to blow up bb. Uses :in :inherit
;; + :err :inherit so script-wizard has TTY access; captures stdout for the
;; picked value.

(defn- sw
  "Run `script-wizard <argv>` with TTY passthrough for interaction, capturing
  stdout. Returns {:exit int :out string}. :continue keeps babashka.process
  from throwing on non-zero exit."
  [argv]
  (let [r (apply p/shell
                 {:out :string :err :inherit :in :inherit :continue true}
                 "script-wizard" argv)]
    {:exit (:exit r) :out (str/trim (str (:out r)))}))

(defn- choose-or-back
  ([msg items] (choose-or-back msg items nil))
  ([msg items default]
   (let [argv (cond-> ["choose"]
                default (into ["-d" (str default)])
                :always (conj (str msg))
                :always (into (mapv str items)))
         {:keys [exit out]} (sw argv)]
     (if (zero? exit) out BACK))))

(defn- ask-or-nil
  ([msg] (ask-or-nil msg nil))
  ([msg default]
   (let [argv (cond-> ["ask" (str msg)]
                (some? default) (conj (str default)))
         {:keys [exit out]} (sw argv)]
     (if (zero? exit) out nil))))

(defn- confirm-or-no
  ([msg] (confirm-or-no msg nil))
  ([msg default]
   (let [dflt (case default :yes "yes" :no "no" nil)
         argv (cond-> ["confirm" (str msg)]
                dflt (conj dflt))
         {:keys [exit]} (sw argv)]
     ;; script-wizard `confirm` signals the answer via exit code alone
     ;; (0 = yes, non-zero = no or cancel); it writes nothing to stdout,
     ;; so a stdout-based check would treat every "yes" as "no".
     (zero? exit))))

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

(defn- sanoid-templates
  "Parse a sanoid config, return sorted names of `template_*` sections. These
  are what the `use_template = X` directive references from dataset sections."
  [raw]
  (->> (str/split-lines (or raw ""))
       (map #(str/replace % #"[#;].*$" ""))
       (map str/trim)
       (keep #(second (re-matches #"^\[(template_.+)\]$" %)))
       sort vec))

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

;; `view-snapshots` is a leaf of the pool-drill-down; the policy helpers it
;; calls are grouped with the create-dataset flow below since they were
;; written for that flow and stayed there when Manage-existing gained edit
;; capabilities. Forward-declared here rather than reshuffling the sections.
(declare policy-in-admin-file? remove-sanoid-section! pick-and-write-policy!)

(defn- policy-info-line
  "Human-readable annotation for the header of `view-snapshots`. Nil if
  nothing to say (sanoid absent or no effective policy)."
  [sanoid? effective in-admin-file? dataset]
  (cond
    (not sanoid?) nil
    (nil? effective) "(policy: none)"
    (= (:name effective) dataset)
    (if in-admin-file?
      (format "(policy: %s — managed here)" (:name effective))
      (format "(policy: %s — defined outside admin-managed config)" (:name effective)))
    :else
    (format "(policy: inherited from %s%s)"
            (:name effective) (if (:recursive? effective) " (recursive)" ""))))

(defn- view-snapshots [cfg dataset-map consumers sanoid?]
  (loop []
    (let [dataset (:name dataset-map)
          snaps (zfs-snapshots cfg dataset)
          raw (when sanoid? (sanoid-config-raw cfg))
          sections (if sanoid? (sanoid-sections raw) [])
          effective (policy-for sections dataset)
          in-admin? (when sanoid? (policy-in-admin-file? cfg dataset))
          info (policy-info-line sanoid? effective in-admin? dataset)]
      (println)
      (println (format "── Snapshots: %s ──" dataset))
      (when info (println (str "  " info)))
      (if (empty? snaps)
        (println "  (no snapshots)")
        (doseq [s snaps] (println (str "  " (snapshot-label s)))))
      (println)
      (let [;; Policy items: only offered when sanoid is installed. If a
            ;; section already lives in the admin-managed file we can edit or
            ;; remove it; otherwise the only action is Set (which may
            ;; override an inherited/external policy by writing a more
            ;; specific section).
            policy-items (cond
                           (not sanoid?) []
                           in-admin? ["Change snapshot policy" "Remove snapshot policy"]
                           :else ["Set snapshot policy"])
            items (cond-> ["Create snapshot"]
                    (seq snaps) (into ["Destroy snapshot"
                                       "Show restore paths for a snapshot"])
                    (seq policy-items) (into policy-items)
                    :always (conj BACK))
            pick (choose-or-back "" items)]
        (case pick
          "Create snapshot"                     (do (create-snapshot! cfg dataset) (recur))
          "Destroy snapshot"                    (do (destroy-snapshot! cfg snaps) (recur))
          "Show restore paths for a snapshot"   (do (show-restore-paths dataset-map consumers snaps) (recur))
          "Set snapshot policy"                 (do (pick-and-write-policy! cfg dataset raw) (recur))
          "Change snapshot policy"              (do (when (remove-sanoid-section! cfg dataset)
                                                      (pick-and-write-policy! cfg dataset raw))
                                                    (recur))
          "Remove snapshot policy"              (do (when (confirm-or-no
                                                           (format "Remove snapshot policy for %s?" dataset)
                                                           :no)
                                                      (when (remove-sanoid-section! cfg dataset)
                                                        (println (format "  ✓ removed policy for %s" dataset))))
                                                    (recur))
          nil)))))

(defn- view-pool [cfg pool consumers sanoid?]
  (loop []
    (println)
    (println (format "── Pool: %s ──" pool))
    ;; Re-fetch datasets *and* the sanoid config each iteration so policies
    ;; attached/removed from view-snapshots reflect in the labels.
    (let [dss (zfs-datasets cfg pool)
          sections (if sanoid? (sanoid-sections (sanoid-config-raw cfg)) [])]
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
              (view-snapshots cfg chosen consumers sanoid?)
              (recur))))))))

;; ─── dataset creation + snapshot-policy attach ──────────────────────────────

(defn- valid-dataset-name?
  "ZFS accepts [A-Za-z0-9_.-:] and / for nesting. Each segment must start with
  an alphanumeric or _, and must not start with a dot."
  [s]
  (boolean
   (and (not (str/blank? s))
        (re-matches #"[A-Za-z0-9_][A-Za-z0-9_.:\-]*(/[A-Za-z0-9_][A-Za-z0-9_.:\-]*)*" s))))

(defn- dataset-exists? [cfg full]
  (pve/pve-ssh-ok? cfg (format "zfs list -H -o name %s 2>/dev/null" full)))

(defn- b64 ^String [^String s]
  (.encodeToString (java.util.Base64/getEncoder) (.getBytes s "UTF-8")))

(def ^:private admin-sanoid-file
  "/etc/sanoid/sanoid.d/nixos-vm-template.conf")

(defn- write-sanoid-section!
  "Append a `[dataset]` section (with body-lines, one per line, auto-indented)
  to /etc/sanoid/sanoid.d/nixos-vm-template.conf on the PVE host. Ensures
  sanoid.conf carries an `!include /etc/sanoid/sanoid.d/*.conf` line so the
  section is actually loaded. Returns true on success, false on failure. Uses
  base64 so shell quoting never touches user-supplied content."
  [cfg dataset body-lines]
  (let [section (str "\n[" dataset "]\n"
                     (str/join "\n" (map #(str "    " %) body-lines))
                     "\n")
        include-line "!include /etc/sanoid/sanoid.d/*.conf"
        cmd (str
             "mkdir -p /etc/sanoid/sanoid.d && "
             "touch /etc/sanoid/sanoid.conf && "
             "grep -qxF '" include-line "' /etc/sanoid/sanoid.conf || "
             "{ echo " (b64 (str include-line "\n")) " | base64 -d "
             ">> /etc/sanoid/sanoid.conf; } && "
             "echo " (b64 section) " | base64 -d "
             ">> " admin-sanoid-file)]
    (try (pve/pve-ssh! cfg cmd) true
         (catch Throwable t
           (println (format "  ✗ failed to write sanoid config: %s" (.getMessage t)))
           false))))

(defn- policy-in-admin-file?
  "Whether the admin-managed sanoid file has a section header exactly matching
  [dataset]. Passes the target via base64 to sidestep shell quoting."
  [cfg dataset]
  (pve/pve-ssh-ok?
   cfg
   (format (str "tgt=$(echo %s | base64 -d) && "
                "grep -qxF \"$tgt\" %s 2>/dev/null")
           (b64 (str "[" dataset "]")) admin-sanoid-file)))

(defn- remove-sanoid-section!
  "Strip any [dataset] section (header line and body lines through the next
  section header) from the admin-managed sanoid file. No-op if the file or
  section is absent. Only touches admin-sanoid-file; sections defined
  elsewhere are left untouched."
  [cfg dataset]
  (let [awk-body (str "BEGIN{skip=0} "
                      "/^[[:space:]]*\\[.+\\][[:space:]]*$/{"
                      "match($0,/\\[.+\\]/); "
                      "sec=substr($0,RSTART+1,RLENGTH-2); "
                      "skip=(sec==tgt)?1:0"
                      "} "
                      "!skip{print}")
        cmd (str "f=" admin-sanoid-file "; "
                 "[ -f \"$f\" ] || exit 0; "
                 "tgt=$(echo " (b64 dataset) " | base64 -d); "
                 "awk -v tgt=\"$tgt\" '" awk-body "' \"$f\" > \"$f.tmp\" && "
                 "mv \"$f.tmp\" \"$f\"")]
    (try (pve/pve-ssh! cfg cmd) true
         (catch Throwable t
           (println (format "  ✗ failed to update sanoid config: %s" (.getMessage t)))
           false))))

(defn- prompt-custom-retention
  "Ask for hourly/daily/weekly/monthly counts. Returns body-lines vector, or
  nil if the user cancelled at any step."
  []
  (let [ask-int (fn [msg default]
                  (loop []
                    (when-let [raw (ask-or-nil msg default)]
                      (let [t (str/trim raw)]
                        (if (re-matches #"\d+" t)
                          t
                          (do (println "  must be a non-negative integer")
                              (recur)))))))
        h (ask-int "Hourly snapshots to keep (0 = none):" "24")
        d (when h (ask-int "Daily snapshots to keep:" "7"))
        w (when d (ask-int "Weekly snapshots to keep:" "4"))
        m (when w (ask-int "Monthly snapshots to keep:" "12"))]
    (when (and h d w m)
      [(str "hourly = " h)
       (str "daily = " d)
       (str "weekly = " w)
       (str "monthly = " m)
       "autosnap = yes"
       "autoprune = yes"])))

(def ^:private hardcoded-policies
  "Canned policy presets shown when the host's sanoid config has no templates
  defined. Written inline (not `use_template`) so no template dependency."
  {"frequent (hourly=48, daily=7)"
   ["hourly = 48" "daily = 7" "autosnap = yes" "autoprune = yes"]
   "production (hourly=36, daily=30, monthly=3)"
   ["hourly = 36" "daily = 30" "monthly = 3" "autosnap = yes" "autoprune = yes"]})

(defn- pick-and-write-policy!
  "Prompt for a policy choice (template / hardcoded / custom / none / back)
  and write it to the admin-managed sanoid file. raw is the concatenated
  sanoid config (for template detection). No outer confirm — call sites are
  expected to already know the user is committing to attaching a policy."
  [cfg dataset raw]
  (let [templates (sanoid-templates raw)
        template-labels (mapv #(str % " (use_template)") templates)
        hardcoded-labels (vec (sort (keys hardcoded-policies)))
        options (cond-> []
                  (seq template-labels) (into template-labels)
                  (empty? template-labels) (into hardcoded-labels)
                  :always (into ["custom (enter retention inline)" "none"]))
        pick (choose-or-back "Choose a snapshot policy:" (conj options BACK))]
    (cond
      (contains? #{BACK "none"} pick)
      (println "  (no policy attached)")

      (str/ends-with? pick " (use_template)")
      (let [tpl (str/replace pick #" \(use_template\)$" "")]
        (when (write-sanoid-section! cfg dataset [(str "use_template = " tpl)])
          (println (format "  ✓ attached policy: use_template = %s" tpl))))

      (contains? hardcoded-policies pick)
      (when (write-sanoid-section! cfg dataset (get hardcoded-policies pick))
        (println (format "  ✓ attached policy: %s" pick)))

      (= pick "custom (enter retention inline)")
      (if-let [body (prompt-custom-retention)]
        (when (write-sanoid-section! cfg dataset body)
          (println "  ✓ attached custom policy"))
        (println "  (cancelled — no policy attached)")))))

(defn- attach-snapshot-policy!
  "After a dataset is created, offer to attach a sanoid snapshot policy.
  raw = concatenated sanoid config (for template detection); nil when sanoid
  isn't installed on the host."
  [cfg dataset sanoid? raw]
  (cond
    (not sanoid?)
    (println (str "  sanoid is not installed on the host — install with "
                  "`apt install sanoid` on PVE to enable snapshot policies"))

    (not (confirm-or-no (format "Apply a snapshot policy to %s?" dataset) :no))
    nil

    :else
    (pick-and-write-policy! cfg dataset raw)))

(defn- create-dataset!
  "Interactive: pick a pool, prompt for a dataset name, validate, `zfs create -p`,
  then offer to attach a snapshot policy. Reads pools once (already fetched by
  zfs-admin); raw is the current sanoid config (nil if sanoid absent)."
  [cfg pools sanoid? raw]
  (let [pool-labels (mapv :name pools)
        pool (choose-or-back "Select a pool for the new dataset:"
                             (conj pool-labels BACK))]
    (when (not= pool BACK)
      (let [pool-name (first-token pool)]
        (when-let [name (loop []
                          (when-let [raw-name (ask-or-nil
                                               "Dataset name (e.g. `movies` or `backups/nightly`):")]
                            (let [v (str/trim raw-name)
                                  full (str pool-name "/" v)]
                              (cond
                                (str/blank? v)
                                (do (println "  name cannot be empty") (recur))
                                (not (valid-dataset-name? v))
                                (do (println (str "  invalid — use A-Za-z0-9_-.: and / for nesting;"
                                                  " each segment must start with an alphanumeric or _"))
                                    (recur))
                                (dataset-exists? cfg full)
                                (do (println (format "  '%s' already exists" full)) (recur))
                                :else v))))]
          (let [full (str pool-name "/" name)]
            (println (format "Creating %s..." full))
            (if (pve/pve-ssh-soft cfg (format "zfs create -p %s" full))
              (do (println (format "  ✓ created %s" full))
                  (attach-snapshot-policy! cfg full sanoid? raw))
              (println "  ✗ zfs create failed — see error above"))))))))

;; ─── zfs admin submenu ───────────────────────────────────────────────────────

(defn- manage-existing-datasets
  "Original pool-selection loop, now a leaf of the zfs-admin submenu."
  [cfg pools consumers sanoid?]
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
          (view-pool cfg pool-name consumers sanoid?)
          (recur))))))

(defn- zfs-admin [cfg]
  (println)
  (println "── ZFS Admin ──")
  (let [pools (zpool-list cfg)]
    (if (empty? pools)
      (do (println (format "No ZFS pools found on %s (or the host has no ZFS)."
                           (or (:pve-node cfg) "the PVE node")))
          (choose-or-back "" [BACK]))
      (let [sanoid? (sanoid-installed? cfg)
            consumers (lxc-consumers cfg)]
        (when-not sanoid?
          (println "(sanoid not installed on host — policy column hidden)"))
        (loop []
          ;; Re-fetch sanoid config each iteration so create-dataset!'s
          ;; template-detection sees the current state.
          (let [raw (when sanoid? (sanoid-config-raw cfg))
                pick (choose-or-back ""
                                     ["Create new ZFS dataset"
                                      "Manage existing ZFS datasets"
                                      BACK])]
            (case pick
              "Create new ZFS dataset"
              (do (create-dataset! cfg pools sanoid? raw) (recur))

              "Manage existing ZFS datasets"
              (do (manage-existing-datasets cfg pools consumers sanoid?)
                  (recur))

              nil)))))))

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
            pick (choose-or-back "" items)]
        (cond
          (= pick "ZFS admin") (do (zfs-admin cfg) (recur))
          (= pick "Quit") nil)))))
