(ns vm.prune
  "prune-images: find the built images (out-links under <output-dir>/profiles
  and <output-dir>/lxc-profiles) that no machine is configured to use, and offer
  to delete them. Each out-link is a Nix GC root, so an image nobody uses still
  pins its image and closure in /nix/store until its link goes.

  Built images are shared by every backend and host (the output dir is not
  scoped by either), so a machine anywhere under the machines base counts:
  <base>/<backend>/<host>/<name>/profile, and the legacy <base>/<name>/profile."
  (:require [clojure.string :as str]
            [babashka.fs :as fs]
            [babashka.process :as p]
            [vm.profile :as profile]
            [vm.backend :as b]))

(defn- machine-profile-files
  "Every machine's profile file, as [kind path]: kind is :lxc for a
  proxmox-lxc machine, :vm for another backend's, :any for the legacy layout
  (whose backend is unknown)."
  [machines-base]
  (when (fs/directory? machines-base)
    (concat
     (for [f (fs/glob machines-base "*/*/*/profile")
           :when (fs/regular-file? f)
           :let [backend (-> f fs/parent fs/parent fs/parent fs/file-name str)]]
       [(if (= backend "proxmox-lxc") :lxc :vm) (str f)])
     (for [f (fs/glob machines-base "*/profile")
           :when (fs/regular-file? f)]
       [:any (str f)]))))

(defn used-keys
  "{:vm #{key...} :lxc #{key...}}: the image keys the machines build, i.e.
  their profile lists normalized as build-profile does."
  [machines-base]
  (reduce (fn [acc [kind f]]
            (let [k (profile/normalize-profiles (str/trim (slurp f)))]
              (case kind
                :vm (update acc :vm conj k)
                :lxc (update acc :lxc conj k)
                :any (-> acc (update :vm conj k) (update :lxc conj k)))))
          {:vm #{} :lxc #{}}
          (machine-profile-files machines-base)))

(defn- size-of [link]
  (let [r (p/shell {:out :string :err :string :continue true} "du" "-sLh" (str link))]
    (if (zero? (:exit r)) (first (str/split (str/trim (:out r)) #"\s")) "?")))

(defn- built-on [link]
  (-> (fs/last-modified-time link {:nofollow-links true})
      str (subs 0 10)))

(defn unused-images
  "The out-links no machine uses: [{:link :kind :key}], sorted by path."
  [output-dir used]
  (sort-by :link
           (for [[kind dir] [[:vm "profiles"] [:lxc "lxc-profiles"]]
                 :let [d (str output-dir "/" dir)]
                 :when (fs/directory? d)
                 l (fs/list-dir d)
                 :when (fs/sym-link? l)
                 :let [k (str (fs/file-name l))]
                 :when (not (contains? (get used kind) k))]
             {:link (str l) :kind kind :key k})))

(defn prune-images
  "List the unused images with their size and build date, then (after a y/N,
  or straight away with --yes) delete their out-links."
  [cfg yes?]
  (let [base (:machines-base cfg)
        out (:output-dir cfg)
        used (used-keys base)
        unused (unused-images out used)]
    (println (format "Machines: %s (%d profile sets in use)"
                     base (count (into (:vm used) (:lxc used)))))
    (if (empty? unused)
      (println (format "Every built image under %s is used by a machine." out))
      (do
        (println (format "Built images under %s that no machine uses:" out))
        (doseq [{:keys [link]} unused]
          (println (format "  %6s  %s  %s" (size-of link) (built-on link)
                           (str (fs/relativize out link)))))
        (when-not yes?
          (b/confirm-or-abort (format "Delete these %d image links? [y/N] " (count unused))))
        (doseq [{:keys [link]} unused]
          (fs/delete link))
        (println (format "Deleted %d image links." (count unused)))
        (println "Their store paths are now garbage; free the space with:")
        (println "  nix-collect-garbage            (keeps your system generations)")))))
