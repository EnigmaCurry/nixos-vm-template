(ns vm.machine
  "The persisted-state layer: the only reader/writer of $MACHINES_DIR/<name>/.
  File names and contents are frozen for byte-compatibility with the Bash
  implementation (existing machines and the .claude skills depend on them)."
  (:require [clojure.string :as str]
            [babashka.fs :as fs]))

(defn machine-dir [cfg name] (str (:machines-dir cfg) "/" name))

(defn exists? [cfg name] (fs/directory? (machine-dir cfg name)))

(defn field-path [cfg name field] (str (machine-dir cfg name) "/" field))

(defn read-field
  "Read a machine config file trimmed of surrounding whitespace, or nil if absent."
  [cfg name field]
  (let [f (field-path cfg name field)]
    (when (fs/exists? f) (str/trim (slurp f)))))

(defn read-raw
  "Read a machine config file verbatim (no trimming), or nil if absent."
  [cfg name field]
  (let [f (field-path cfg name field)]
    (when (fs/exists? f) (slurp f))))

(defn profile-of [cfg name] (or (read-field cfg name "profile") ""))

(defn- profile-has?
  "True if `token` is a member of the comma-separated profile list."
  [cfg name token]
  (str/includes? (str "," (profile-of cfg name) ",") (str "," token ",")))

(defn mutable? [cfg name] (profile-has? cfg name "mutable"))
(defn semi-mutable? [cfg name] (profile-has? cfg name "semi-mutable"))
(defn pipewire? [cfg name] (profile-has? cfg name "pipewire"))

(defn mode-of
  "VM mutability mode as a display string."
  [cfg name]
  (cond (mutable? cfg name) "mutable"
        (semi-mutable? cfg name) "semi-mutable"
        :else "immutable"))

(defn list-machines
  "Return a sorted vector of {:name :profile} for every machine config dir.
  :profile is \"unknown\" when the machine has no profile file."
  [cfg]
  (let [dir (:machines-dir cfg)]
    (if (fs/directory? dir)
      (->> (fs/list-dir dir)
           (filter fs/directory?)
           (mapv (fn [d]
                   (let [name (fs/file-name d)]
                     {:name name
                      :profile (or (read-field cfg name "profile") "unknown")})))
           (sort-by :name)
           vec)
      [])))
