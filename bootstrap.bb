#!/usr/bin/env bb
;; nixos-vm-template bootstrap
;; Create NixOS VMs from pre-built images — no local image build required.
;;
;; One-liner (auto-detects branch from URL):
;;   bb -e '(def *url* "https://github.com/EnigmaCurry/nixos-vm-template/raw/refs/heads/dev/bootstrap.bb") (load-string (slurp *url*))'
;;
;; Or from a cloned repo:
;;   bb bootstrap.bb
;;   just bootstrap

(require '[babashka.pods :as pods])
(pods/load-pod 'enigmacurry/script-wizard "0.3.0")

(require '[pod.enigmacurry.script-wizard :as wiz]
         '[babashka.process :as proc]
         '[babashka.http-client :as http]
         '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[cheshire.core :as json])

;; ─── Constants ──────────────────────────────────────────────────────────────

(def manifest-url
  (or (System/getenv "NIXOS_MANIFEST_URL")
      "https://nixos-vm-template.nyc3.digitaloceanspaces.com/manifest.json"))

(def repo-url "https://github.com/EnigmaCurry/nixos-vm-template.git")
(def repo-branch
  (or (System/getenv "NIXOS_VM_BRANCH")
      (try
        (when-let [v (resolve '*url*)]
          (second (re-find #"/refs/heads/([^/]+)/" (str @v))))
        (catch Exception _ nil))
      "dev"))
(def default-repo-dir (str (System/getenv "HOME") "/.cache/nixos-vm-template"))

;; ─── Repo detection ────────────────────────────────────────────────────────

(defn in-repo?
  "Check if a directory looks like the nixos-vm-template repo."
  [dir]
  (and dir
       (.exists (io/file dir "Justfile"))
       (.exists (io/file dir "backends" "common.sh"))))

(defn ensure-repo!
  "Return path to a usable repo checkout. Clones or updates as needed."
  []
  (let [;; Try *file* parent (running from cloned repo)
        file-dir (try
                   (let [f (io/file *file*)]
                     (if (.isAbsolute f)
                       (.getParent f)
                       (.getCanonicalPath (.getParentFile f))))
                   (catch Exception _ nil))]
    (if (in-repo? file-dir)
      file-dir
      ;; Running via URL or from outside repo — use default location
      (let [dir default-repo-dir]
        (if (in-repo? dir)
          (do
            (println (format "Updating repo in %s ..." dir))
            (proc/shell {:dir dir :out :string :err :string} "git" "pull" "--ff-only")
            dir)
          (do
            (println (format "Cloning repo to %s (branch: %s) ..." dir repo-branch))
            (proc/shell {:out :string :err :string}
                        "git" "clone" "--branch" repo-branch repo-url dir)
            dir))))))

;; ─── Utilities ──────────────────────────────────────────────────────────────

(def repo-dir (atom nil))

(defn sh
  "Run a shell command in repo dir. Throws on non-zero exit."
  [& args]
  (let [cmd (str/join " " args)]
    (proc/shell {:out :string :err :string :dir @repo-dir} "bash" "-c" cmd)))

(defn sh-ok
  "Run a shell command, return stdout trimmed."
  [& args]
  (str/trim (:out (apply sh args))))

(defn sh-inherit!
  "Run a shell command with inherited stdout/stderr (visible to user)."
  [& args]
  (let [cmd (str/join " " args)]
    (proc/shell {:dir @repo-dir} "bash" "-c" cmd)))

(defn fetch-json
  "Fetch and parse JSON from a URL."
  [url]
  (let [resp (http/get url {:headers {"Accept" "application/json"}})]
    (json/parse-string (:body resp) true)))

(defn format-size
  "Format byte count as human-readable size."
  [bytes]
  (cond
    (>= bytes (* 1024 1024 1024)) (format "%.1f GB" (/ bytes (* 1024.0 1024 1024)))
    (>= bytes (* 1024 1024))      (format "%.0f MB" (/ bytes (* 1024.0 1024)))
    :else                          (format "%d bytes" bytes)))

;; ─── Main ───────────────────────────────────────────────────────────────────

(defn -main []
  (println)
  (println "  nixos-vm-template bootstrap")
  (println "  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
  (println)

  ;; Ensure we have a repo checkout
  (reset! repo-dir (ensure-repo!))

  ;; Fetch manifest
  (print "Fetching image manifest... ")
  (flush)
  (let [manifest (try (fetch-json manifest-url)
                      (catch Exception e
                        (println "FAILED")
                        (println (format "  %s" (.getMessage e)))
                        (System/exit 1)))
        _ (println "OK")
        profiles (:profiles manifest)
        profile-keys (vec (sort (map name (keys profiles))))]

    (when (empty? profile-keys)
      (println "No profiles available in manifest.")
      (System/exit 1))

    ;; Display available profiles
    (println)
    (doseq [k profile-keys]
      (let [p (get profiles (keyword k))]
        (println (format "  %-35s %s  commit %s  %s"
                         k (:date p) (:commit p) (format-size (:size p))))))
    (println)

    ;; Choose profile
    (let [profile-key (wiz/choose "Select profile:" profile-keys)
          profile-info (get profiles (keyword profile-key))
          image-url (:url profile-info)
          image-sha256 (:sha256 profile-info)]

      ;; Ask for VM name
      (let [vm-name (wiz/ask "VM name:" :default "nixos")]

        ;; Download image
        (println)
        (let [profile-dir (str @repo-dir "/output/profiles/" profile-key)
              image-path (str profile-dir "/nixos.qcow2")
              needs-download? (atom true)]

          ;; Check if image already exists with correct checksum
          (when (.exists (io/file image-path))
            (print "  Checking existing image... ")
            (flush)
            (let [actual (first (str/split (sh-ok (format "sha256sum '%s'" image-path)) #"\s+"))]
              (if (= actual image-sha256)
                (do (println "OK (checksum matches)")
                    (reset! needs-download? false))
                (println "stale (re-downloading)"))))

          (when @needs-download?
            (.mkdirs (io/file profile-dir))
            (println (format "Downloading %s (%s)..."
                             (:filename profile-info)
                             (format-size (:size profile-info))))
            (sh-inherit! (format "curl -fL --progress-bar -o '%s' '%s'" image-path image-url))
            (print "  Verifying checksum... ")
            (flush)
            (let [actual (first (str/split (sh-ok (format "sha256sum '%s'" image-path)) #"\s+"))]
              (if (= actual image-sha256)
                (println "OK")
                (do (println "FAILED")
                    (println (format "  Expected: %s" image-sha256))
                    (println (format "  Actual:   %s" actual))
                    (io/delete-file image-path true)
                    (System/exit 1))))))

        ;; Create VM via just create-batch (reuses all existing backend logic)
        (println)
        (println (format "Creating VM '%s' with profile '%s'..." vm-name profile-key))
        (println)
        (let [result (proc/shell {:dir @repo-dir
                                  :extra-env {"SKIP_BUILD" "true"}}
                                 "just" "create-batch" vm-name profile-key)]
          (when (not= 0 (:exit result))
            (System/exit (:exit result))))))))

(-main)
