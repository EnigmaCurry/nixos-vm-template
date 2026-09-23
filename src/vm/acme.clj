(ns vm.acme
  "acme-dns helpers for Traefik's built-in ACME client. Manages
  machines/<name>/acme-dns.env and acme-dns.json on the workstation.

  - `acme-register`: POST to the acme-dns server's /register endpoint, append
    the returned account under the given domain in acme-dns.json, and print
    the CNAME record the user must publish. Writes ACME_DNS_API_BASE into
    acme-dns.env on first run.
  - `acme-verify`: resolve the CNAME for _acme-challenge.<domain> and compare
    against the fulldomain stored for that domain in acme-dns.json.

  Neither command touches the VM; run `just sync-identity <name>` afterwards
  to push acme-dns.json onto it."
  (:require [babashka.fs :as fs]
            [babashka.http-client :as http]
            [cheshire.core :as json]
            [clojure.string :as str]
            [vm.machine :as machine]
            [vm.proc :as proc]))

(defn- env-path [cfg name]  (str (machine/machine-dir cfg name) "/acme-dns.env"))
(defn- json-path [cfg name] (str (machine/machine-dir cfg name) "/acme-dns.json"))

(defn- parse-env-lines
  "Return `{:vars {\"KEY\" \"value\" ...} :lines [raw-line ...]}` from the
  systemd EnvironmentFile at `path` (or {:vars {} :lines []} if absent).
  Comment lines and blanks are preserved verbatim in :lines."
  [path]
  (if (fs/regular-file? path)
    (let [lines (str/split-lines (slurp path))
          vars (into {}
                     (for [ln lines
                           :let [t (str/trim ln)]
                           :when (and (not (str/blank? t))
                                      (not (str/starts-with? t "#"))
                                      (str/includes? t "="))
                           :let [[k v] (str/split t #"=" 2)]]
                       [(str/trim k) (str/trim v)]))]
      {:vars vars :lines lines})
    {:vars {} :lines []}))

(defn- write-env!
  "Write acme-dns.env with `ACME_DNS_API_BASE=<value>` uncommented. If a
  commented `# ACME_DNS_API_BASE=...` line exists, replace it in place;
  otherwise append."
  [path url existing-lines]
  (let [pat #"^\s*#?\s*ACME_DNS_API_BASE\s*=.*$"
        replaced? (atom false)
        rewritten (map (fn [ln]
                         (if (re-matches pat ln)
                           (do (reset! replaced? true)
                               (str "ACME_DNS_API_BASE=" url))
                           ln))
                       existing-lines)
        final (vec (if @replaced? rewritten (concat rewritten [(str "ACME_DNS_API_BASE=" url)])))]
    (spit path (str (str/join "\n" final) "\n"))
    (fs/set-posix-file-permissions path "rw-------")))

(defn- read-store [path]
  (if (fs/regular-file? path)
    (try (json/parse-string (slurp path) false)
         (catch Exception e
           (println (format "Error: %s is not valid JSON: %s" path (.getMessage e)))
           (System/exit 1)))
    {}))

(defn- write-store! [path m]
  (spit path (json/generate-string m {:pretty true}))
  (fs/set-posix-file-permissions path "rw-------"))

(defn- prompt-line [msg]
  (print msg) (flush)
  (str/trim (or (read-line) "")))

(defn- prompt-yes-no [msg default?]
  (let [answer (prompt-line (format "%s [%s] " msg (if default? "Y/n" "y/N")))]
    (cond
      (str/blank? answer)              default?
      (str/starts-with? (str/lower-case answer) "y") true
      :else                            false)))

(defn- ensure-api-base!
  "Read ACME_DNS_API_BASE from acme-dns.env; prompt + persist on first use."
  [cfg name]
  (let [path (env-path cfg name)
        {:keys [vars lines]} (parse-env-lines path)]
    (or (get vars "ACME_DNS_API_BASE")
        (let [_ (println (format "ACME_DNS_API_BASE is not configured for '%s'." name))
              url (prompt-line "Enter acme-dns server URL (e.g., https://acme-dns.example.com:2890): ")]
          (when (str/blank? url)
            (println "Aborted: URL required.")
            (System/exit 1))
          (write-env! path url lines)
          (println)
          (println (format "Wrote ACME_DNS_API_BASE=%s" url))
          (println (format "      to %s" path))
          (println)
          url))))

(defn- register!
  "POST to <api-base>/register (empty JSON body). Returns the parsed response
  map with string keys. Aborts on non-2xx."
  [api-base]
  (let [resp (try
               (http/post (str api-base "/register")
                          {:headers {"Content-Type" "application/json"}
                           :body "{}"
                           :throw false})
               (catch Exception e
                 (println (format "Error: HTTP request failed: %s" (.getMessage e)))
                 (System/exit 1)))
        status (:status resp)
        body (:body resp)]
    (when-not (and (integer? status) (<= 200 status 299))
      (println (format "Error: acme-dns /register returned HTTP %s" status))
      (when body (println (str "  body: " body)))
      (System/exit 1))
    (try (json/parse-string body false)
         (catch Exception _
           (println "Error: acme-dns response was not JSON:")
           (println body)
           (System/exit 1)))))

(defn- base-domain
  "Strip a leading `*.` from a wildcard SAN. This is also the key lego uses
  in the acme-dns storage file: ACME authorizations for wildcard certs have
  identifier.value = the base domain, and lego passes that verbatim to the
  provider's Present() — it never sees the `*.` itself."
  [domain]
  (if (str/starts-with? domain "*.") (subs domain 2) domain))

(defn- cname-source
  "The FQDN at which Let's Encrypt will look up the TXT record: `_acme-challenge.`
  prepended to the base domain."
  [domain]
  (str "_acme-challenge." (base-domain domain)))

(defn cmd-register
  "just acme-register <vm> <domain>"
  [cfg name domain]
  (when (or (str/blank? name) (str/blank? domain))
    (println "Usage: just acme-register <vm> <domain>")
    (System/exit 1))
  (let [md (machine/machine-dir cfg name)]
    (when-not (fs/directory? md)
      (println (format "Error: machine dir not found: %s" md))
      (System/exit 1)))
  (let [api-base (ensure-api-base! cfg name)
        jpath (json-path cfg name)
        store (read-store jpath)
        store-key (base-domain domain)]
    (when (contains? store store-key)
      (when-not (prompt-yes-no
                 (format "Domain '%s' (storage key '%s') already has acme-dns credentials. Rotate?"
                         domain store-key)
                 false)
        (println "Aborted.")
        (System/exit 0))
      (println "Rotating — the previous CNAME target will stop being validated.")
      (println))
    (println (format "Registering %s with %s ..." domain api-base))
    (let [account (register! api-base)
          entry (-> (select-keys account ["username" "password" "fulldomain" "subdomain"])
                    (assoc "server_url" api-base))]
      (write-store! jpath (assoc store store-key entry))
      (println "Registered.")
      (println)
      (println "Publish this DNS record at your domain's authoritative nameserver:")
      (println)
      (println (format "  %s.  CNAME  %s."
                       (cname-source domain) (get account "fulldomain")))
      (println)
      (println "Then push the updated credentials to the VM:")
      (println)
      (println (format "  just sync-identity %s" name))
      (println)
      (println "Verify the CNAME before Traefik requests a cert:")
      (println (format "  just acme-verify %s %s" name domain)))))

(defn- dig-cname
  "Return the CNAME target `name` resolves to (trailing dot stripped, single
  hop), or nil on no-answer. Aborts if `dig` isn't installed."
  [name]
  (let [r (proc/capture-result ["dig" "+short" "CNAME" name])]
    (when-not (zero? (:exit r))
      (println (format "Error: dig failed (exit %s): %s" (:exit r) (str/trim (or (:err r) ""))))
      (System/exit 1))
    (let [answer (->> (str/split-lines (or (:out r) ""))
                      (map str/trim)
                      (remove str/blank?)
                      first)]
      (some-> answer (str/replace #"\.\s*$" "")))))

(defn cmd-verify
  "just acme-verify <vm> <domain>"
  [cfg name domain]
  (when (or (str/blank? name) (str/blank? domain))
    (println "Usage: just acme-verify <vm> <domain>")
    (System/exit 1))
  (let [jpath (json-path cfg name)
        store (read-store jpath)
        store-key (base-domain domain)
        entry (get store store-key)]
    (when-not entry
      (println (format "Error: %s has no entry for '%s' (storage key '%s')." jpath domain store-key))
      (println (format "Register it first: just acme-register %s %s" name domain))
      (System/exit 1))
    (let [expected (some-> (get entry "fulldomain") (str/replace #"\.\s*$" ""))
          rr (cname-source domain)]
      (when (str/blank? expected)
        (println (format "Error: entry for '%s' has no fulldomain field." domain))
        (System/exit 1))
      (println (format "Resolving CNAME for %s ..." rr))
      (let [got (dig-cname rr)]
        (cond
          (nil? got)
          (do (println (format "FAIL: no CNAME record found at %s" rr))
              (println (format "      expected: %s" expected))
              (println (format "      publish:  %s.  CNAME  %s." rr expected))
              (System/exit 1))

          (= got expected)
          (println (format "OK: %s -> %s" rr got))

          :else
          (do (println "MISMATCH:")
              (println (format "  %s currently resolves to: %s" rr got))
              (println (format "  expected:                    %s" expected))
              (System/exit 1)))))))
