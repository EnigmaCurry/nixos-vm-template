(ns vm.profile
  "Profile normalization and image building (nix build / export). Ports the
  build_profile / build_all / export_profile / list_profiles / normalize_profiles
  helpers from common.sh."
  (:require [clojure.string :as str]
            [babashka.fs :as fs]
            [babashka.process :as p]
            [vm.proc :as proc]))

(defn normalize-profiles
  "Sort + dedupe a comma-separated profile list, ensuring `core` is included.
  \"docker,python\" -> \"core,docker,python\"."
  [profiles]
  (let [parts (->> (str/split (or profiles "core") #",")
                   (map str/trim)
                   (remove str/blank?)
                   distinct
                   sort)]
    (str/join "," (if (some #(= % "core") parts) parts (cons "core" parts)))))

(defn list-profiles
  "Print available profiles (one per profiles/*.nix file)."
  [cfg]
  (println "Available profiles:")
  (let [files (sort (fs/glob (str (:repo-dir cfg) "/profiles") "*.nix"))]
    (if (seq files)
      (doseq [f files] (println (str/replace (fs/file-name f) #"\.nix$" "")))
      (println "(none)"))))

(defn- git-sha
  "Short HEAD sha of the repo, with `-dirty` suffix if the tree is dirty,
  or \"unknown\" if not a git repo."
  [repo-dir]
  (let [sha (try (str/trim (:out (p/shell {:out :string :err :string :dir repo-dir}
                                          "git" "rev-parse" "--short" "HEAD")))
                 (catch Exception _ "unknown"))]
    (if (and (not= sha "unknown")
             (not (zero? (:exit (p/shell {:out :string :err :string :dir repo-dir :continue true}
                                         "git" "diff" "--quiet" "HEAD")))))
      (str sha "-dirty")
      sha)))

(defn- nix-list
  "Convert a profile key to a nix list literal: \"core,docker\" -> [\"core\" \"docker\"]."
  [profile-key]
  (str "[" (str/join " " (map pr-str (str/split profile-key #","))) "]"))

(defn build-profile
  "Build a profile's base image. Honors SKIP_BUILD (bootstrap). FLAKE_UPDATE is
  taken from opts {:flake-update? bool} (upgrade) or the env var otherwise.
  Returns the profile key."
  [cfg profiles & [opts]]
  (let [profile-key (normalize-profiles (or profiles "core"))
        repo-dir (:repo-dir cfg)
        output-dir (:output-dir cfg)
        profiles-out (str output-dir "/profiles")]
    (if (= "true" (System/getenv "SKIP_BUILD"))
      (let [skip-image (str profiles-out "/" profile-key "/nixos.qcow2")]
        (if (fs/regular-file? skip-image)
          (do (println (format "Latest image already downloaded at %s" skip-image))
              profile-key)
          (do (println (format "Error: SKIP_BUILD=true but image not found: %s" skip-image))
              (System/exit 1))))
      (do
        (cond
          (str/includes? (str "," profile-key ",") ",mutable,")
          (println (format "Building mutable profile: %s" profile-key))
          (str/includes? (str "," profile-key ",") ",semi-mutable,")
          (println (format "Building semi-mutable profile: %s" profile-key))
          :else
          (println (format "Building immutable profile: %s" profile-key)))
        (fs/create-dirs profiles-out)
        (let [flake-update? (if (contains? opts :flake-update?)
                              (:flake-update? opts)
                              (= "true" (System/getenv "FLAKE_UPDATE")))
              tmp-flake (when flake-update? (str (fs/create-temp-dir)))
              flake-dir (or tmp-flake repo-dir)]
          (when flake-update?
            (proc/run! ["cp" "-a" (str repo-dir "/.") (str tmp-flake "/")])
            (proc/run! ["chmod" "-R" "u+w" tmp-flake])
            (println "Updating flake inputs...")
            (proc/run! (concat (:nix cfg) ["flake" "update" "--flake" tmp-flake])))
          (let [sha (git-sha repo-dir)
                expr (format "\n      let flake = builtins.getFlake \"%s\";\n      in flake.lib.mkCombinedImage \"x86_64-linux\" %s {}\n    "
                             flake-dir (nix-list profile-key))]
            (proc/run! (concat (:nix cfg)
                               ["build" "--impure" "--expr" expr
                                "--out-link" (str profiles-out "/" profile-key)])
                       {:dir repo-dir :extra-env {"IMAGE_COMMIT" sha}}))
          (when tmp-flake (fs/delete-tree tmp-flake)))
        (println (format "Built: %s/%s" profiles-out profile-key))
        (proc/run! ["ls" "-lhL" (str profiles-out "/" profile-key "/")])
        profile-key))))

(defn build-all
  "Build all base profiles."
  [cfg]
  (println "Building all base profiles...")
  (doseq [p ["core" "docker" "podman" "dev" "claude" "open-code"]]
    (build-profile cfg p))
  (println "All base profiles built."))

(defn export-profile
  "Export a built profile image with release metadata in the filename:
  output/export/nixos-{slug}-{date}-{gitsha}.qcow2."
  [cfg profiles]
  (let [profile-key (normalize-profiles (or profiles "core"))
        output-dir (:output-dir cfg)
        source-image (str output-dir "/profiles/" profile-key "/nixos.qcow2")]
    (when-not (fs/regular-file? source-image)
      (println (format "Error: Profile image not found: %s" source-image))
      (println (format "Run 'just build %s' first" profile-key))
      (System/exit 1))
    (let [date-stamp (proc/capture ["date" "+%Y%m%d"])
          sha (try (str/trim (:out (p/shell {:out :string :err :string :dir (:repo-dir cfg)}
                                            "git" "rev-parse" "--short" "HEAD")))
                   (catch Exception _ "unknown"))
          slug (str/replace profile-key "," "--")
          export-dir (str output-dir "/export")
          export-name (format "nixos-%s-%s-%s.qcow2" slug date-stamp sha)
          export-path (str export-dir "/" export-name)]
      (fs/create-dirs export-dir)
      (proc/run! (concat (:nix cfg)
                         ["shell" "nixpkgs#qemu-utils" "-c"
                          "qemu-img" "convert" "-f" "qcow2" "-O" "qcow2" "-c"
                          source-image export-path]))
      (println (format "Exported: %s" export-path))
      (proc/run! ["ls" "-lh" export-path]))))
