#!/usr/bin/env bb
;; PostToolUse hook: reconcile Lisp parens from indentation using parinfer-rust
;; (indent mode). Reads the hook JSON from stdin, rewrites the edited file in
;; place. Never blocks an edit: any failure is swallowed and we exit 0.
(require '[cheshire.core :as json]
         '[babashka.fs :as fs]
         '[babashka.process :as p])

(def lisp-exts #{"clj" "cljs" "cljc" "bb" "edn"})

(defn lisp-file? [path]
  (and path (contains? lisp-exts (fs/extension path))))

(defn parinfer-cmd []
  (if (fs/which "parinfer-rust")
    ["parinfer-rust"]
    ["nix" "run" "nixpkgs#parinfer-rust" "--"]))

(defn -main []
  (try
    (let [data (json/parse-string (slurp *in*) true)
          path (or (get-in data [:tool_input :file_path])
                   (get-in data [:tool_response :filePath]))]
      (when (and (lisp-file? path) (fs/exists? path))
        (let [src (slurp path)
              cmd (into (parinfer-cmd) ["--mode" "indent" "-l" "clojure"])
              {:keys [exit out]} (p/sh cmd {:in src})]
          (when (and (zero? exit) (seq out) (not= out src))
            (spit path out)))))
    (catch Throwable _ nil))
  (System/exit 0))

(-main)
