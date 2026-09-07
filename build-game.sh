#!/bin/bash
# Builds the SuperTuxKart WebAssembly engine and asset bundles that index.html
# expects in ./game/.
#
# This wraps the port's own scripts (wasm/get_emsdk.sh, wasm/build_deps.sh,
# wasm/build.sh, wasm/pack_assets.sh) and works around three things that stop
# them on a current Emscripten SDK or a restricted network:
#
#   1. embuilder port names gained hyphens: sdl2_image-jpg, not sdl2_image_jpg.
#      The port's build.sh still uses the old spelling and aborts.
#   2. cmake needs -DCHECK_ASSETS=off unless a stk-assets tree sits beside the
#      source, and needs a few passes before its find_package cache settles.
#      That repeated-run quirk is documented in the port's own README.
#   3. Emscripten fetches SDL and friends as GitHub archive zips. Where those
#      are blocked but git is not, --seed-ports clones each port at its pinned
#      tag into the port cache and writes the .emscripten_url marker, which
#      makes Emscripten treat the port as already downloaded.
#
# Usage:
#   ./build-game.sh [--seed-ports] [--keep-png] [--quality low|mid|high|all] [--jobs N]
#
# --keep-png disables the asset generator's PNG-to-JPEG conversion. That step
# rewrites the texture names embedded in the .spm meshes, but it misses some, so
# a handful of powerup textures (bubblegum, swatter, the nitro models) end up
# asked for as .png when only a .jpg was written, and render untextured. Keeping
# PNG costs bundle size and avoids that entirely.
#
# Expect roughly an hour on four cores plus a large download. Linux only.

set -u

WORK="${STK_WORK:-$(pwd)/build}"
QUALITY="low"
JOBS="$(nproc --all 2>/dev/null || echo 4)"
SEED_PORTS=0
KEEP_PNG=0
HERE="$(cd "$(dirname "$0")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --seed-ports) SEED_PORTS=1; shift ;;
    --keep-png) KEEP_PNG=1; shift ;;
    --quality) QUALITY="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

STK="$WORK/stk-code"
ASSETS="$WORK/stk-assets"
EMSDK="$STK/wasm/emsdk"
say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

mkdir -p "$WORK" || die "cannot create $WORK"

# --------------------------------------------------------------- toolchain ---
say "host packages"
if command -v apt-get >/dev/null 2>&1; then
  sudo_cmd=""; [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
  $sudo_cmd apt-get update -qq || true
  $sudo_cmd apt-get install -y -qq \
    build-essential cmake ninja-build git python3 \
    autoconf automake libtool libtool-bin pkg-config ragel \
    imagemagick vorbis-tools pngquant advancecomp libjpeg-progs optipng \
    || echo "warning: some packages did not install; the build may fail later"
else
  echo "no apt-get here, assuming the toolchain is already present"
fi

say "source tree"
if [ ! -d "$STK" ]; then
  git clone --depth 1 --branch wasm https://github.com/ading2210/stk-code "$STK" \
    || die "could not clone the port"
fi

say "emscripten sdk"
if [ ! -f "$EMSDK/emsdk_env.sh" ]; then
  "$STK/wasm/get_emsdk.sh" || die "emsdk install failed"
fi
# shellcheck disable=SC1091
. "$EMSDK/emsdk_env.sh" >/dev/null 2>&1 || die "could not activate emsdk"

# ------------------------------------------------------------- port seeding ---
seed_port() {
  local name="$1" repo="$2" tag="$3" subdir="$4" url="$5"
  local ports="$EMSDK/upstream/emscripten/cache/ports"
  local dest="$ports/$name/$subdir"
  [ -f "$ports/$name/.emscripten_url" ] && { echo "  $name already seeded"; return 0; }
  echo "  seeding $name from $repo@$tag"
  rm -rf "${ports:?}/$name"; mkdir -p "$dest"
  git clone --quiet --depth 1 --branch "$tag" "$repo" "$dest" >/dev/null 2>&1 \
    || { echo "  warning: could not clone $name"; return 1; }
  rm -rf "$dest/.git"
  printf '%s\n' "$url" > "$ports/$name/.emscripten_url"
}

if [ "$SEED_PORTS" = 1 ]; then
  say "seeding emscripten ports from git"
  seed_port sdl2 https://github.com/libsdl-org/SDL release-2.32.10 SDL-release-2.32.10 \
    "https://github.com/libsdl-org/SDL/archive/release-2.32.10.zip"
  seed_port sdl2_ttf https://github.com/libsdl-org/SDL_ttf release-2.20.2 SDL_ttf-release-2.20.2 \
    "https://github.com/libsdl-org/SDL_ttf/archive/release-2.20.2.zip"
  seed_port sdl2_image https://github.com/libsdl-org/SDL_image release-2.6.0 SDL_image-release-2.6.0 \
    "https://github.com/libsdl-org/SDL_image/archive/refs/tags/release-2.6.0.zip"
  seed_port sdl2_mixer https://github.com/libsdl-org/SDL_mixer release-2.8.0 SDL_mixer-release-2.8.0 \
    "https://github.com/libsdl-org/SDL_mixer/archive/release-2.8.0.zip"
  seed_port freetype https://github.com/freetype/freetype VER-2-14-3 freetype-VER-2-14-3 \
    "https://github.com/freetype/freetype/archive/VER-2-14-3.zip"
  seed_port zlib https://github.com/madler/zlib v1.3.2 zlib-1.3.2 \
    "https://github.com/madler/zlib/archive/refs/tags/v1.3.2.tar.gz"
  echo "note: tags are pinned by this emsdk version; if a port still downloads,"
  echo "      read the TAG and SUBDIR from upstream/emscripten/tools/ports/<name>.py"
fi

# ------------------------------------------------------------- dependencies ---
say "wasm dependencies (ogg, vorbis, openssl, zlib, curl, jpeg, png, freetype, harfbuzz)"
"$STK/wasm/build_deps.sh" || die "dependency build failed"

# ------------------------------------------------------------------- engine ---
say "engine"
BUILD_DIR="$STK/cmake_build/Release"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR" || die "cannot enter $BUILD_DIR"

# Warm the port cache. Names are hyphenated now, and -pthread means the -mt
# variants are what actually get linked. Failure here is not fatal: the link
# step builds whatever is still missing.
embuilder build sdl2 sdl2-mt sdl2_ttf sdl2_ttf-mt \
  sdl2_image sdl2_image-jpg sdl2_image-jpg-mt sdl2_image-png sdl2_image-png-mt \
  sdl2_mixer sdl2_mixer-mt 2>/dev/null \
  || echo "note: some ports were not prebuilt; the link step will handle them"

cmake_ok=0
for attempt in 1 2 3 4 5 6; do
  echo "cmake pass $attempt"
  if emcmake cmake "$STK" -DNO_SHADERC=on -DCHECK_ASSETS=off -DCMAKE_BUILD_TYPE=Release; then
    cmake_ok=1; break
  fi
done
[ "$cmake_ok" = 1 ] || die "cmake never succeeded; see the output above"

make -j"$JOBS" || die "engine build failed"
[ -f "$BUILD_DIR/bin/supertuxkart.js" ] || die "the link produced no supertuxkart.js"

mkdir -p "$STK/wasm/web/game"
cp "$BUILD_DIR"/bin/supertuxkart.* "$STK/wasm/web/game/"
python3 "$STK/wasm/patch_js.py" "$STK/wasm/fragments" "$STK/wasm/web/game/supertuxkart.js"

# ------------------------------------------------------------------- assets ---
say "game assets"
if [ ! -d "$ASSETS/tracks" ]; then
  # The assets live in SVN, not git, but the source release carries the same
  # karts and tracks and is a plain download.
  REL="https://github.com/supertuxkart/stk-code/releases/download/1.4/SuperTuxKart-1.4-src.tar.xz"
  echo "fetching the 1.4 source release for karts and tracks (about 650 MB)"
  curl -fSL -C - -o "$WORK/stk-src.tar.xz" "$REL" || die "asset download failed"
  mkdir -p "$ASSETS"
  tar -xJf "$WORK/stk-src.tar.xz" -C "$ASSETS" --strip-components=2 \
    SuperTuxKart-1.4-src/data/karts SuperTuxKart-1.4-src/data/tracks \
    SuperTuxKart-1.4-src/data/library SuperTuxKart-1.4-src/data/models \
    SuperTuxKart-1.4-src/data/music SuperTuxKart-1.4-src/data/sfx \
    SuperTuxKart-1.4-src/data/textures || die "asset extraction failed"
fi

pack_one() {
  local name="$1" size="$2"
  local out="$STK/wasm/web/game/$name.tar.gz"
  local dir="$STK/wasm/web/game/$name"
  local convert=1
  [ "$KEEP_PNG" = 1 ] && convert=0
  say "packing $name (${size}px textures, jpeg conversion=$convert)"
  ASSETS_PATHS="$ASSETS" OUTPUT_PATH="$dir" TEXTURE_SIZE="$size" CONVERT_TO_JPG="$convert" \
    "$STK/android/generate_assets.sh" || die "asset generation failed for $name"
  [ -d "$dir/data" ] || die "no data directory produced for $name"
  [ -x "$dir/data/optimize_data.sh" ] && ( cd "$dir/data" && ./optimize_data.sh )
  tar -cf - -C "$dir/data" . | gzip -9 - > "$out"
  split -b 20m --numeric-suffixes "$out" "$out."
  { du -b "$out" | cut -f1
    find "$(dirname "$out")" -name "$(basename "$out").*" ! -name '*.manifest' -printf '%f\n' | sort
  } > "$out.manifest"
  rm -f "$out"
  rm -rf "$dir"
}

case "$QUALITY" in
  low)  pack_one data_low 256 ;;
  mid)  pack_one data_mid 512 ;;
  high) pack_one data_high 1024 ;;
  all)  pack_one data_low 256; pack_one data_mid 512; pack_one data_high 1024 ;;
  *) die "unknown quality: $QUALITY (use low, mid, high or all)" ;;
esac

# -------------------------------------------------------------------- done ---
say "installing into $HERE/game"
mkdir -p "$HERE/game"
cp -a "$STK/wasm/web/game/." "$HERE/game/"
ls -la "$HERE/game"

cat <<DONE

Build complete. Start the server and play:

    python3 "$HERE/serve.py"

then open http://localhost:8000
DONE
