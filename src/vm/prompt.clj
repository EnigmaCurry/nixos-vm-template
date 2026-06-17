(ns vm.prompt
  "Interactive prompts via the script-wizard babashka pod, loaded lazily so that
  non-interactive commands never pull the pod binary. Also a silent password
  reader for `passwd`."
  (:require [babashka.pods :as pods]
            [babashka.process :as p]
            [clojure.string :as str]))

(def ^:private wiz-ns
  "Loads the script-wizard pod on first use and returns its namespace symbol."
  (delay
    (pods/load-pod 'enigmacurry/script-wizard "0.3.0")
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
  "Single choice from `choices`. Optional `default-idx` (0-based) preselects."
  ([msg choices] (apply wiz "choose" msg choices))
  ([msg default-idx choices]
   (apply wiz "choose" msg :default-index default-idx choices)))

(defn select
  "Multi-select from `choices`; returns a vector of selected strings."
  [msg choices]
  (apply wiz "select" msg choices))

(defn read-password
  "Read a password from the TTY without echo. Returns the entered string."
  [prompt]
  (str/trim-newline
   (:out (p/shell {:out :string :in :inherit}
                  "bash" "-c"
                  (str "read -rs -p " (pr-str prompt) " pw </dev/tty; echo \"$pw\"")))))
