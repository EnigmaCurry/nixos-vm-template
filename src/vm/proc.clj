(ns vm.proc
  "Process helpers. Commands are passed as argument *vectors* (already including
  any HOST_CMD/SUDO prefix tokens resolved in vm.config), so local invocations
  avoid shell quoting entirely. babashka.process/shell throws on non-zero exit
  by default, which gives us `set -e` semantics for free."
  (:refer-clojure :exclude [run!])
  (:require [babashka.process :as p]
            [clojure.string :as str]))

(defn run!
  "Run argv (a seq of strings), inheriting stdout/stderr. Throws on non-zero."
  ([argv] (run! argv {}))
  ([argv opts] (apply p/shell opts argv)))

(defn run-ok?
  "Run argv with output suppressed; return true on exit 0, false otherwise.
  Equivalent to bash `cmd >/dev/null 2>&1`."
  ([argv] (run-ok? argv {}))
  ([argv opts]
   (try (apply p/shell (merge {:out :string :err :string} opts) argv) true
        (catch Exception _ false))))

(defn capture
  "Run argv and return trimmed stdout. Throws on non-zero exit (stderr inherited),
  matching bash `$(cmd)`."
  ([argv] (capture argv {}))
  ([argv opts]
   (str/trim (:out (apply p/shell (merge {:out :string} opts) argv)))))

(defn capture-result
  "Run argv capturing both streams without throwing. Returns the process map
  with :out :err :exit. Use when the exit code / stderr must be inspected."
  ([argv] (capture-result argv {}))
  ([argv opts]
   (apply p/shell (merge {:out :string :err :string :continue true} opts) argv)))
