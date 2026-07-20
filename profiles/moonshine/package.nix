# Vendored from github.com/philpax/nixos-configuration
#   nixos/mindgame/moonshine/package.nix @ 3fb10ac9
# Builds hgaiser/moonshine (headless Moonlight/GameStream streaming server).
# Moonshine is not (yet) in nixpkgs; this derivation carries the inputtino-sys
# build-script workaround upstream requires.
{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  cmake,
  shaderc,
  perl,
  makeWrapper,
  wayland,
  wayland-protocols,
  libxkbcommon,
  libevdev,
  libpulseaudio,
  libopus,
  libGL,
  libgbm,
  libdrm,
  mesa,
  systemd,
  vulkan-loader,
  vulkan-headers,
  avahi,
  dbus,
  libxcb,
  libx11,
  xwayland,
}:

rustPlatform.buildRustPackage rec {
  pname = "moonshine";
  version = "0.11.0";

  src = fetchFromGitHub {
    owner = "hgaiser";
    repo = "moonshine";
    rev = "v${version}";
    hash = "sha256-wV34OVdlcs/63eOjSmvMdwiNSHY/NrZ43sPCFBLZ29A=";
  };

  # The inputtino-sys crate's build.rs compiles the inputtino C++ library via
  # cmake, expecting the full inputtino repo at a relative path ("../../../").
  # nixpkgs' cargoLock vendoring copies only the crate's own subdirectory, so
  # that relative path is broken; we supply the full repo and patch build.rs.
  inputtinoSrc = fetchFromGitHub {
    owner = "games-on-whales";
    repo = "inputtino";
    rev = "f4ce2b0df536ef309e9ff318f75b460f7097d7c1";
    hash = "sha256-mAAXbIK7aNSLyN7OZX9YeesMvT6OZmT9uAx0md6pyRM=";
  };

  cargoLock = {
    lockFile = "${src}/Cargo.lock";
    outputHashes = {
      "ash-0.38.0+1.4.329" = "sha256-apzc//AZqS3F4e4Epm3Dl20ZkkMKUvLjyxv7ZwJh1Jw=";
      "inputtino-0.1.0" = "sha256-mAAXbIK7aNSLyN7OZX9YeesMvT6OZmT9uAx0md6pyRM=";
      "inputtino-sys-0.1.0" = "sha256-mAAXbIK7aNSLyN7OZX9YeesMvT6OZmT9uAx0md6pyRM=";
      "pixelforge-0.3.0" = "sha256-zAGeR7K32ptCo3yo+TpOwLBTew37eZqav0yl/+ONggg=";
      "smithay-0.7.0" = "sha256-MnPoJ97kOZS3y5BsYNZLCY1VfIKDC3PYrfn8ksn1v14=";
    };
  };

  # The root is both a package and a workspace; plain `cargo build` builds only
  # `moonshine`. Build the whole workspace so the moonshine-wsi cdylib is produced.
  cargoBuildFlags = [ "--workspace" ];

  nativeBuildInputs = [
    pkg-config
    cmake
    shaderc
    perl
    makeWrapper
    rustPlatform.bindgenHook
    wayland
  ];

  buildInputs = [
    wayland
    wayland-protocols
    libxkbcommon
    libevdev
    libpulseaudio
    libopus
    libGL
    libgbm
    libdrm
    mesa
    systemd
    vulkan-loader
    vulkan-headers
    avahi
    dbus
    libxcb
    libx11
  ];

  # aws-lc-sys / bindgen need libclang; cmake finds it via bindgenHook.
  # shaderc-sys: use nixpkgs prebuilt shaderc instead of building from source.
  SHADERC_LIB_DIR = "${lib.getLib shaderc}/lib";

  # After cargoSetupHook vendors the git crates, redirect inputtino-sys' cmake
  # source path from the broken "../../../" to the full inputtino tree.
  preBuild = ''
    for bs in $(find "$NIX_BUILD_TOP" -path '*inputtino-sys*/build.rs'); do
      chmod u+w "$bs"
      substituteInPlace "$bs" \
        --replace-fail 'PathBuf::from("../../../")' 'PathBuf::from("${inputtinoSrc}")' \
        --replace-fail 'println!("cargo:rustc-link-lib=c++");' ""
      echo "Patched inputtino-sys build.rs: $bs"
    done
  '';

  postInstall = ''
    # (2) WSI Vulkan layer cdylib
    wsi="$(find "$NIX_BUILD_TOP" -name libmoonshine_wsi.so -type f | head -1)"
    if [ -z "$wsi" ]; then
      echo "ERROR: libmoonshine_wsi.so not found; candidates:" >&2
      find "$NIX_BUILD_TOP" -name '*moonshine_wsi*' >&2 || true
      exit 1
    fi
    echo "Installing WSI layer from: $wsi"
    install -Dm755 "$wsi" $out/lib/moonshine/vulkan-layers/libmoonshine_wsi.so

    # (3) Vulkan implicit layer manifest, patched to absolute store path
    mkdir -p $out/share/vulkan/implicit_layer.d
    substitute $src/dist/VkLayer_moonshine_wsi.json \
      $out/share/vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json \
      --replace "/usr/lib/moonshine/vulkan-layers/libmoonshine_wsi.so" \
                "$out/lib/moonshine/vulkan-layers/libmoonshine_wsi.so"

    # (4) reference dist files
    mkdir -p $out/share/moonshine/dist
    cp -v $src/dist/60-moonshine.rules \
          $src/dist/moonshine@.service \
          $src/dist/start-moonshine.sh \
          $out/share/moonshine/dist/ 2>/dev/null || true
    # moonshine-modules.conf may not exist in this release; copy if present
    [ -f $src/dist/moonshine-modules.conf ] && \
      cp -v $src/dist/moonshine-modules.conf $out/share/moonshine/dist/ || true

    # (1) wrap server binary so xwayland + vulkan loader resolve at runtime
    wrapProgram $out/bin/moonshine \
      --prefix PATH : ${lib.makeBinPath [ xwayland ]} \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ vulkan-loader libGL ]}
  '';

  meta = {
    description = "Headless Moonlight/GameStream streaming server";
    homepage = "https://github.com/hgaiser/moonshine";
    license = lib.licenses.gpl3Only;
    platforms = [ "x86_64-linux" ];
    mainProgram = "moonshine";
  };
}
