#!/usr/bin/env bb
;; Generate RetroArch .lpl playlists from a system-per-subdir ROM tree.
;;
;; Usage: generate-retroarch-playlists.bb <roms-dir> <playlists-dir> <cores-dir>
;;
;; ROMs are expected under <roms-dir>/<subdir>/... where <subdir> matches one
;; of the entries in `systems` below. Each entry maps a subdir to a libretro
;; core (a *_libretro.so file under <cores-dir>) and a retroarch DB name
;; (which drives thumbnail lookups on libretro-thumbnails.libretro.com).
;; Subdirs not in the table are silently skipped. Empty playlists are not
;; written. Entries sharing a :db-name (e.g. amiga variants, genesis +
;; megadrive) are merged into one playlist.
;;
;; :exts is an ordered vector — highest priority first. When multiple files
;; in the same directory share a stem (Game.cue + Game.bin, Game.chd +
;; Game.cue), only the highest-priority extension is kept, preventing the
;; classic disc-based duplicate-entry problem.

(require '[babashka.fs :as fs]
         '[cheshire.core :as json]
         '[clojure.string :as str])

(def systems
  [{:subdir "nes"
    :core "mesen_libretro"
    :core-name "Nintendo - NES / Famicom (Mesen)"
    :db-name "Nintendo - Nintendo Entertainment System.lpl"
    :exts ["nes" "zip" "7z"]}
   {:subdir "snes"
    :core "snes9x_libretro"
    :core-name "Nintendo - SNES / SFC (Snes9x)"
    :db-name "Nintendo - Super Nintendo Entertainment System.lpl"
    :exts ["smc" "sfc" "fig" "swc" "zip" "7z"]}
   {:subdir "n64"
    :core "mupen64plus_next_libretro"
    :core-name "Nintendo - Nintendo 64 (Mupen64Plus-Next)"
    :db-name "Nintendo - Nintendo 64.lpl"
    :exts ["z64" "n64" "v64" "zip" "7z"]}
   {:subdir "gb"
    :core "sameboy_libretro"
    :core-name "Nintendo - Game Boy (SameBoy)"
    :db-name "Nintendo - Game Boy.lpl"
    :exts ["gb" "zip" "7z"]}
   {:subdir "gbc"
    :core "sameboy_libretro"
    :core-name "Nintendo - Game Boy Color (SameBoy)"
    :db-name "Nintendo - Game Boy Color.lpl"
    :exts ["gbc" "zip" "7z"]}
   {:subdir "gba"
    :core "mgba_libretro"
    :core-name "Nintendo - Game Boy Advance (mGBA)"
    :db-name "Nintendo - Game Boy Advance.lpl"
    :exts ["gba" "zip" "7z"]}
   {:subdir "nds"
    :core "melonds_libretro"
    :core-name "Nintendo - Nintendo DS (melonDS)"
    :db-name "Nintendo - Nintendo DS.lpl"
    :exts ["nds" "zip" "7z"]}
   {:subdir "genesis"
    :core "genesis_plus_gx_libretro"
    :core-name "Sega - MS/GG/MD/CD (Genesis Plus GX)"
    :db-name "Sega - Mega Drive - Genesis.lpl"
    :exts ["md" "gen" "smd" "bin" "zip" "7z"]}
   {:subdir "megadrive"
    :core "genesis_plus_gx_libretro"
    :core-name "Sega - MS/GG/MD/CD (Genesis Plus GX)"
    :db-name "Sega - Mega Drive - Genesis.lpl"
    :exts ["md" "gen" "smd" "bin" "zip" "7z"]}
   {:subdir "mastersystem"
    :core "genesis_plus_gx_libretro"
    :core-name "Sega - MS/GG/MD/CD (Genesis Plus GX)"
    :db-name "Sega - Master System - Mark III.lpl"
    :exts ["sms" "zip" "7z"]}
   {:subdir "gamegear"
    :core "genesis_plus_gx_libretro"
    :core-name "Sega - MS/GG/MD/CD (Genesis Plus GX)"
    :db-name "Sega - Game Gear.lpl"
    :exts ["gg" "zip" "7z"]}
   {:subdir "segacd"
    :core "genesis_plus_gx_libretro"
    :core-name "Sega - MS/GG/MD/CD (Genesis Plus GX)"
    :db-name "Sega - Mega-CD - Sega CD.lpl"
    :exts ["m3u" "chd" "cue"]}
   {:subdir "sega32x"
    :core "picodrive_libretro"
    :core-name "Sega - MS/GG/MD/32X (PicoDrive)"
    :db-name "Sega - 32X.lpl"
    :exts ["32x" "bin" "zip" "7z"]}
   {:subdir "saturn"
    :core "mednafen_saturn_libretro"
    :core-name "Sega - Saturn (Beetle Saturn)"
    :db-name "Sega - Saturn.lpl"
    :exts ["m3u" "chd" "cue"]}
   {:subdir "dreamcast"
    :core "flycast_libretro"
    :core-name "Sega - Dreamcast (Flycast)"
    :db-name "Sega - Dreamcast.lpl"
    :exts ["m3u" "chd" "gdi" "cue"]}
   {:subdir "psx"
    :core "mednafen_psx_hw_libretro"
    :core-name "Sony - PlayStation (Beetle PSX HW)"
    :db-name "Sony - PlayStation.lpl"
    :exts ["m3u" "chd" "pbp" "cue"]}
   {:subdir "psp"
    :core "ppsspp_libretro"
    :core-name "Sony - PSP (PPSSPP)"
    :db-name "Sony - PlayStation Portable.lpl"
    :exts ["iso" "cso" "pbp"]}
   {:subdir "arcade"
    :core "fbneo_libretro"
    :core-name "Arcade (FinalBurn Neo)"
    :db-name "FBNeo - Arcade Games.lpl"
    :exts ["zip" "7z"]}
   {:subdir "pcengine"
    :core "mednafen_pce_libretro"
    :core-name "NEC - PCE / TG-16 (Beetle PCE)"
    :db-name "NEC - PC Engine - TurboGrafx 16.lpl"
    :exts ["pce" "sgx" "chd" "cue" "zip" "7z"]}
   {:subdir "tg16"
    :core "mednafen_pce_libretro"
    :core-name "NEC - PCE / TG-16 (Beetle PCE)"
    :db-name "NEC - PC Engine - TurboGrafx 16.lpl"
    :exts ["pce" "sgx" "chd" "cue" "zip" "7z"]}
   {:subdir "atari2600"
    :core "stella_libretro"
    :core-name "Atari 2600 (Stella)"
    :db-name "Atari - 2600.lpl"
    :exts ["a26" "bin" "zip" "7z"]}
   {:subdir "ngp"
    :core "mednafen_ngp_libretro"
    :core-name "SNK - Neo Geo Pocket (Beetle NeoPop)"
    :db-name "SNK - Neo Geo Pocket.lpl"
    :exts ["ngp" "zip" "7z"]}
   {:subdir "ngpc"
    :core "mednafen_ngp_libretro"
    :core-name "SNK - Neo Geo Pocket Color (Beetle NeoPop)"
    :db-name "SNK - Neo Geo Pocket Color.lpl"
    :exts ["ngc" "zip" "7z"]}
   {:subdir "dos"
    :core "dosbox_pure_libretro"
    :core-name "DOS (DOSBox-Pure)"
    :db-name "DOS.lpl"
    :exts ["zip" "7z" "conf" "exe" "bat" "com" "iso"]}
   {:subdir "amiga"
    :core "puae_libretro"
    :core-name "Commodore - Amiga (PUAE)"
    :db-name "Commodore - Amiga.lpl"
    :exts ["ipf" "adf" "hdf" "lha" "zip" "7z"]}
   {:subdir "amiga600"
    :core "puae_libretro"
    :core-name "Commodore - Amiga (PUAE)"
    :db-name "Commodore - Amiga.lpl"
    :exts ["ipf" "adf" "hdf" "lha" "zip" "7z"]}
   {:subdir "amiga1200"
    :core "puae_libretro"
    :core-name "Commodore - Amiga (PUAE)"
    :db-name "Commodore - Amiga.lpl"
    :exts ["ipf" "adf" "hdf" "lha" "zip" "7z"]}
   {:subdir "amigacd32"
    :core "puae_libretro"
    :core-name "Commodore - Amiga (PUAE)"
    :db-name "Commodore - Amiga.lpl"
    :exts ["chd" "cue" "zip"]}
   {:subdir "c64"
    :core "vice_x64sc_libretro"
    :core-name "Commodore - 64 (VICE x64sc)"
    :db-name "Commodore - 64.lpl"
    :exts ["d64" "g64" "crt" "prg" "tap" "zip" "7z"]}
   {:subdir "scummvm"
    :core "scummvm_libretro"
    :core-name "ScummVM"
    :db-name "ScummVM.lpl"
    :exts ["scummvm"]}])

(defn ext-of [^java.io.File f]
  (let [n (.getName f)
        i (.lastIndexOf n ".")]
    (when (pos? i)
      (str/lower-case (subs n (inc i))))))

(defn scan-subdir [roms-dir subdir exts]
  (let [dir (fs/file (fs/path roms-dir subdir))]
    (when (fs/exists? dir)
      (let [ext-set (set exts)
            priority (zipmap exts (range))
            files (->> (file-seq dir)
                       (filter #(.isFile ^java.io.File %))
                       (filter #(contains? ext-set (ext-of %))))
            stem (fn [^java.io.File f]
                   [(.getParent f)
                    (str/replace (.getName f) #"\.[^.]+$" "")])]
        (->> files
             (group-by stem)
             vals
             (map (fn [group]
                    (apply min-key #(priority (ext-of %)) group)))
             (sort-by #(.getAbsolutePath ^java.io.File %)))))))

(defn playlist-item [^java.io.File f db-name]
  {:path (.getAbsolutePath f)
   :label (-> (.getName f)
              (str/replace #"\.[^.]+$" ""))
   :core_path "DETECT"
   :core_name "DETECT"
   :crc32 "00000000|crc"
   :db_name db-name})

(defn build-playlist [db-name entries cores-dir]
  (let [head (first entries)
        items (mapcat (fn [{:keys [files]}]
                        (map #(playlist-item % db-name) files))
                      entries)]
    {:version "1.5"
     :default_core_path (str cores-dir "/" (:core head) ".so")
     :default_core_name (:core-name head)
     :label_display_mode 0
     :right_thumbnail_mode 1
     :left_thumbnail_mode 3
     :sort_mode 0
     :items (vec items)}))

(defn -main [roms-dir playlists-dir cores-dir]
  (fs/create-dirs playlists-dir)
  (let [scanned (->> systems
                     (map (fn [sys]
                            (assoc sys :files
                                   (scan-subdir roms-dir
                                                (:subdir sys)
                                                (:exts sys)))))
                     (filter (comp seq :files)))
        by-db (group-by :db-name scanned)
        written (atom 0)
        total (atom 0)]
    (doseq [[db-name entries] by-db]
      (let [pl (build-playlist db-name entries cores-dir)
            out (str (fs/path playlists-dir db-name))]
        (spit out (json/generate-string pl {:pretty true}))
        (swap! written inc)
        (swap! total + (count (:items pl)))))
    (println (format "generate-retroarch-playlists: wrote %d playlists, %d entries"
                     @written @total))))

(apply -main *command-line-args*)
