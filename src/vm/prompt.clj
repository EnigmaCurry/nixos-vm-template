(ns vm.prompt
  "Interactive prompts via the script-wizard babashka pod, loaded lazily so that
  non-interactive commands never pull the pod binary. Also a silent password
  reader for `passwd`."
  (:require [babashka.pods :as pods]
            [babashka.process :as p]
            [clojure.string :as str]))

(def ^:private wiz-ns
  "Loads the script-wizard pod on first use and returns its namespace symbol.

  Loaded via the local `script-wizard` binary (provided by the flake devShell)
  rather than the babashka pod-registry. v0.3.0 in the registry has a bug
  where numeric-looking defaults are treated as indices and crash the picker
  when out of range (fixed upstream in v0.3.1). Switch back to the registry
  form once v0.3.1 lands there."
  (delay
    ;; (pods/load-pod 'enigmacurry/script-wizard "0.3.0")  ; buggy — see above
    (pods/load-pod ["script-wizard" "pod"])
    (require '[pod.enigmacurry.script-wizard])
    'pod.enigmacurry.script-wizard))

(defn- wiz
  "Resolve and call a script-wizard pod fn by name."
  [fname & args]
  (apply (requiring-resolve (symbol (name @wiz-ns) fname)) args))

(defn ask
  "Prompt for a line of input. Optional default pre-fills the answer."
  ([msg] (wiz "ask" msg))
  ([msg default] (wiz "ask" msg :default (or default ""))))

(defn confirm
  "Yes/no confirmation. `default` is :yes or :no."
  ([msg] (wiz "confirm" msg))
  ([msg default] (wiz "confirm" msg :default default)))

(defn choose
  "Single choice from `choices`. Optional `default` value preselects it."
  ([msg choices] (wiz "choose" msg (vec choices)))
  ([msg choices default] (wiz "choose" msg (vec choices) :default default)))

(defn select
  "Multi-select from `choices`; returns a vector of selected strings. Optional
  `default` is a vector of pre-selected values."
  ([msg choices] (wiz "select" msg (vec choices)))
  ([msg choices default] (wiz "select" msg (vec choices) :default default)))

(defn read-password
  "Read a password from the TTY without echo. Returns the entered string."
  [prompt]
  (str/trim-newline
   (:out (p/shell {:out :string :in :inherit}
                  "bash" "-c"
                  (str "read -rs -p " (pr-str prompt) " pw </dev/tty; echo \"$pw\"")))))
