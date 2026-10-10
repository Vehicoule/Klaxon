#!/usr/bin/env bash
# scripts/fetch-deps.sh — fetch + build Klaxon's third-party dependencies into deps/.
#
#   Skia  @ 8643b1d64cff21b5e6f8d65ca98204c6eecb0098   (Graphite + Ganesh + raster)
#   SDL3  @ release-3.2.16
#   WAMR  @ WAMR-2.4.4   (fast-interp; plugin runtime for klaxon-plugin-sdk — the framework does not link it)
#   emsdk @ 4.0.7        (web-wasm only — pinned by Skia's bin/activate-emsdk)
#
# Hosts: macOS arm64 (dev host), Linux x64/arm64 (CI). Idempotent: up-to-date steps are skipped.
#
# Usage:
#   scripts/fetch-deps.sh              # all components
#   scripts/fetch-deps.sh skia sdl3    # selected components
#   scripts/fetch-deps.sh web-wasm     # Phase 3f web target (emsdk + Skia wasm + SDL3 wasm; heavy, ~1-2 GB)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/deps"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 8)"

SKIA_PIN="8643b1d64cff21b5e6f8d65ca98204c6eecb0098"
SDL3_PIN="release-3.2.16"
WAMR_PIN="WAMR-2.4.4"
EMSDK_PIN="4.0.7" # pinned by Skia's bin/activate-emsdk (see MODULE.bazel)

SKIA_URL="https://skia.googlesource.com/skia.git"
SDL3_URL="https://github.com/libsdl-org/SDL.git"
WAMR_URL="https://github.com/bytecodealliance/wasm-micro-runtime.git"
EMSDK_URL="https://github.com/emscripten-core/emsdk.git"

CHROMIUM="https://chromium.googlesource.com"
SKIA_GOOG="https://skia.googlesource.com"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- prerequisites ----------------------------------------------------------

command -v git     >/dev/null || die "git is required"
command -v ninja   >/dev/null || die "ninja is required (brew install ninja / apt install ninja-build)"
command -v cmake   >/dev/null || die "cmake is required (brew install cmake)"
command -v python3 >/dev/null || die "python3 is required (Skia's bin/gn wrapper)"

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS:$ARCH" in
  Darwin:arm64)  TAG="macos-arm64"; SKIA_TARGET_CPU="arm64"; SKIA_TARGET_OS="mac";   WAMR_PLATFORM="darwin"; WAMR_TARGET="AARCH64" ;;
  Linux:x86_64)  TAG="linux-x64";   SKIA_TARGET_CPU="x64";   SKIA_TARGET_OS="linux"; WAMR_PLATFORM="linux";  WAMR_TARGET="X86_64" ;;
  Linux:aarch64) TAG="linux-arm64"; SKIA_TARGET_CPU="arm64"; SKIA_TARGET_OS="linux"; WAMR_PLATFORM="linux";  WAMR_TARGET="AARCH64" ;;
  *) die "unsupported host $OS/$ARCH — add it to scripts/fetch-deps.sh" ;;
esac
if [ "$OS" = "Darwin" ]; then
  xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools required (xcode-select --install)"
fi
if [ "$OS" = "Linux" ]; then
  command -v clang >/dev/null || die "clang is required (Skia args.gn uses clang)"
fi
log "host: $TAG ($JOBS jobs)"

SKIA="$DEPS/skia"

# --- helpers ----------------------------------------------------------------

# git_clone_at <dir> <url> <pin> — shallow fetch of an exact ref/sha. Idempotent via .pin stamp.
git_clone_at() {
  local dir="$1" url="$2" pin="$3"
  if [ -f "$dir/.pin" ] && [ "$(cat "$dir/.pin")" = "$pin" ]; then
    log "$dir already at $pin"
    return 0
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$url"
  log "fetch $(basename "$dir") @ $pin"
  if ! git -C "$dir" fetch -q --depth=1 origin "$pin" 2>/dev/null; then
    log "  shallow fetch failed, retrying full fetch"
    git -C "$dir" fetch -q origin "$pin"
  fi
  git -C "$dir" checkout -q FETCH_HEAD
  printf '%s\n' "$pin" > "$dir/.pin"
}

# --- Skia -------------------------------------------------------------------

fetch_skia() {
  git_clone_at "$SKIA" "$SKIA_URL" "$SKIA_PIN"

  # Minimal third_party/externals — pins from Skia's DEPS at $SKIA_PIN.
  # Enough for graphite+ganesh+raster; no Dawn (Windows adds its own externals later).
  local ext="$SKIA/third_party/externals"
  git_clone_at "$ext/freetype"        "$CHROMIUM/chromium/src/third_party/freetype2.git"               264b5fbf5b912b39f98d038bf75d39be0a73f21b
  git_clone_at "$ext/harfbuzz"        "$CHROMIUM/external/github.com/harfbuzz/harfbuzz.git"           9cb1fee51069b206effb4736e443b038d230789d
  git_clone_at "$ext/icu"             "$CHROMIUM/chromium/deps/icu.git"                               d578f2e8b7bd5938e21cfb6bf15c079e0aa5b738
  git_clone_at "$ext/libpng"          "$SKIA_GOOG/third_party/libpng.git"                             d5515b5b8be3901aac04e5bd8bd5c89f287bcd33
  git_clone_at "$ext/zlib"            "$CHROMIUM/chromium/src/third_party/zlib"                       646b7f569718921d7d4b5b8e22572ff6c76f2596
  git_clone_at "$ext/jinja2"          "$CHROMIUM/chromium/src/third_party/jinja2"                     c3027d884967773057bf74b957e3fea87e5df4d7
  git_clone_at "$ext/markupsafe"      "$CHROMIUM/chromium/src/third_party/markupsafe"                 4256084ae14175d38a3ff7d739dca83ae49ccec6
  git_clone_at "$ext/partition_alloc" "$CHROMIUM/chromium/src/base/allocator/partition_allocator.git" 03cc513177b4340bee3dbfd46f6dd5fdded43b79
}

write_skia_args() {
  local out="$1"
  case "$TAG" in
    macos-arm64)
      cat > "$out" <<EOF
is_debug = false
is_official_build = true
is_component_build = false
target_cpu = "arm64"
target_os = "mac"

skia_use_metal = true
skia_use_gl = false
skia_use_vulkan = false
skia_use_dawn = false
skia_use_direct3d = false
skia_use_x11 = false
skia_use_egl = false
skia_use_vma = false
skia_enable_ganesh = true
skia_enable_graphite = true
EOF
      ;;
    linux-x64|linux-arm64|windows-x64|windows-arm64)
      # Phase 0: raster-only Skia on Linux — the Linux shim is raster-only
      # (gpu_init returns false). Phase 3a enables graphite-vulkan + ganesh-gl
      # (fetch the vma + vulkan-headers externals from DEPS, apt libgl-dev on CI).
      cat > "$out" <<EOF
is_debug = false
is_official_build = true
is_component_build = false
target_cpu = "$SKIA_TARGET_CPU"
target_os = "linux"
cc = "clang"
cxx = "clang++"

skia_use_gl = false
skia_use_egl = false
skia_use_x11 = false
skia_use_vulkan = false
skia_use_dawn = false
skia_use_metal = false
skia_use_direct3d = false
skia_use_vma = false
skia_enable_ganesh = false
skia_enable_graphite = false
EOF
      ;;
  esac
  write_skia_args_common "$out"
}

# Shared tail (icu/harfbuzz/freetype/png/zlib + module toggles) — identical
# for the native and wasm builds.
write_skia_args_common() {
  local out="$1"
  cat >> "$out" <<'EOF'

skia_use_icu = true
skia_use_client_icu = false
skia_use_icu4x = false
skia_use_libgrapheme = false
skia_use_system_icu = false
skia_use_harfbuzz = true
skia_use_system_harfbuzz = false
skia_use_freetype = true
skia_use_system_freetype2 = false
skia_use_libpng = true
skia_use_system_libpng = false
skia_use_zlib = true
skia_use_system_zlib = false
skia_use_libjpeg_turbo = false
skia_use_libjpeg_turbo_decode = false
skia_use_libjpeg_turbo_encode = false
skia_use_dng_sdk = false
skia_use_libwebp = false
skia_use_libwebp_decode = false
skia_use_libwebp_encode = false
skia_use_no_webp_encode = true
skia_use_wuffs = false
skia_use_expat = false
skia_use_fontconfig = false
skia_use_partition_alloc = false

skia_enable_skottie = false
skia_enable_skshaper = true
skia_enable_skparagraph = true
skia_enable_pdf = false
skia_enable_tools = false

extra_cflags = [ "-Wno-error" ]
# Linux: compile Skia against libc++ to match zig's bundled libc++ at link time
# (CI installs libc++-dev). macOS + wasm: libc++ is the default anyway.
extra_cflags_cc = [ "-Wno-error", "-stdlib=libc++" ]
EOF
}

# Phase 3f wasm args (target_cpu = "wasm" implies target_os = "wasm",
# gn/BUILDCONFIG.gn). Ganesh WebGL2 only — no Graphite/Dawn (Phase 3g). The
# wasm toolchain compiles with emcc/em++ from skia_emsdk_dir and emits
# lib<name>.wasm.a (gn/toolchain/BUILD.gn).
write_skia_args_wasm() {
  local out="$1"
  cat > "$out" <<EOF
is_debug = false
is_official_build = true
is_component_build = false
target_cpu = "wasm"

skia_emsdk_dir = "$DEPS/emsdk"

skia_use_webgl = true
skia_use_webgpu = false
skia_use_vulkan = false
skia_use_metal = false
skia_use_dawn = false
skia_use_direct3d = false
skia_use_x11 = false
skia_use_egl = false
skia_use_vma = false
skia_enable_ganesh = true
skia_enable_graphite = false
skia_enable_fontmgr_custom_embedded = true
skia_enable_fontmgr_custom_directory = true
EOF
  write_skia_args_common "$out"
}

build_skia() {
  local out="$SKIA/out/$TAG"
  if [ -f "$out/libskia.a" ]; then
    log "skia already built for $TAG"
    return 0
  fi
  fetch_skia
  mkdir -p "$out"
  write_skia_args "$out/args.gn"
  if [ ! -x "$SKIA/bin/gn" ]; then
    log "fetch gn binary (bin/fetch-gn)"
    (cd "$SKIA" && python3 bin/fetch-gn)
  fi
  log "gn gen out/$TAG"
  (cd "$SKIA" && ./bin/gn gen "out/$TAG")
  log "ninja ($JOBS jobs) — the long step, ~15-45 min on first run"
  ninja -C "$out" skia modules/skparagraph:skparagraph modules/skshaper:skshaper
  ls -la "$out"/*.a
}

# --- SDL3 -------------------------------------------------------------------

build_sdl3() {
  local src="$DEPS/SDL"
  local build="$src/build-$TAG"
  git_clone_at "$src" "$SDL3_URL" "$SDL3_PIN"
  log "cmake SDL3 ($TAG, static, trimmed)"
  # Trimmed: camera/sensors are V2 platform services, SDL_GPU is unused (Skia renders).
  # Audio + haptics stay ON (v1 platform services, ADR-0005).
  cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Release \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON \
    -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_TESTS=OFF \
    -DSDL_CAMERA=OFF -DSDL_SENSOR=OFF \
    -DSDL_GPU=OFF -DSDL_RENDER_GPU=OFF -DSDL_RENDER_VULKAN=OFF
  cmake --build "$build" --parallel "$JOBS"
  ls -la "$build"/libSDL3.a
}

# --- WAMR -------------------------------------------------------------------
# fast-interp only: no JIT, no AOT (iOS-compatible), instruction metering on.
# Plugin runtime for klaxon-plugin-sdk — the framework itself does not link it.

build_wamr() {
  local src="$DEPS/wamr"
  local build="$src/build-$TAG"
  git_clone_at "$src" "$WAMR_URL" "$WAMR_PIN"
  log "cmake WAMR ($TAG, fast-interp)"
  cmake -S "$src/product-mini/platforms/$WAMR_PLATFORM" -B "$build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DWAMR_BUILD_TARGET="$WAMR_TARGET" \
    -DWAMR_BUILD_INTERP=1 -DWAMR_BUILD_FAST_INTERP=1 \
    -DWAMR_BUILD_JIT=0 -DWAMR_BUILD_AOT=0 \
    -DWAMR_BUILD_LIBC_BUILTIN=0 -DWAMR_BUILD_LIBC_WASI=0 \
    -DWAMR_BUILD_SIMD=0 -DWAMR_BUILD_BULK_MEMORY=1 -DWAMR_BUILD_REF_TYPES=1 \
    -DWAMR_BUILD_INSTRUCTION_METERING=1
  cmake --build "$build" --parallel "$JOBS"
  # The vmlib target is renamed on output (set_target_properties OUTPUT_NAME iwasm).
  find "$build" -maxdepth 1 -name 'lib*.a' -exec ls -la {} +
}

# --- web-wasm (Phase 3f) ----------------------------------------------------
# Heavy (~1-2 GB): NOT a default component. One emsdk, pinned to Skia's
# bin/activate-emsdk version — Skia's wasm objects and the app's emcc link
# (build.zig, `web` step) must use the same toolchain (plan §2).

build_emsdk() {
  local dir="$DEPS/emsdk"
  if [ -f "$dir/.emsdk-pin" ] && [ "$(cat "$dir/.emsdk-pin")" = "$EMSDK_PIN" ] \
    && [ -x "$dir/upstream/emscripten/emcc" ]; then
    log "emsdk already installed ($EMSDK_PIN)"
    return 0
  fi
  git_clone_at "$dir" "$EMSDK_URL" "$EMSDK_PIN"
  log "emsdk install + activate $EMSDK_PIN (large download)"
  (cd "$dir" && ./emsdk install "$EMSDK_PIN" && ./emsdk activate "$EMSDK_PIN")
  printf '%s\n' "$EMSDK_PIN" > "$dir/.emsdk-pin"
}

build_skia_wasm() {
  local out="$SKIA/out/web-wasm"
  if [ -f "$out/libskia.wasm.a" ]; then
    log "skia wasm already built (out/web-wasm)"
    return 0
  fi
  build_emsdk
  fetch_skia
  # bin/activate-emsdk drives third_party/externals/emsdk — symlink it at the
  # single repo-level emsdk (one toolchain for Skia objects + the app link).
  local emsdk_ext="$SKIA/third_party/externals/emsdk"
  if [ -d "$emsdk_ext" ] && [ ! -L "$emsdk_ext" ]; then
    die "$emsdk_ext exists — remove it so the build uses the single emsdk at $DEPS/emsdk"
  fi
  mkdir -p "$SKIA/third_party/externals"
  ln -sfn "$DEPS/emsdk" "$emsdk_ext"
  mkdir -p "$out"
  write_skia_args_wasm "$out/args.gn"
  if [ ! -x "$SKIA/bin/gn" ]; then
    log "fetch gn binary (bin/fetch-gn)"
    (cd "$SKIA" && python3 bin/fetch-gn)
  fi
  log "activate emsdk for skia (bin/activate-emsdk)"
  (cd "$SKIA" && python3 bin/activate-emsdk)
  log "gn gen out/web-wasm"
  (cd "$SKIA" && ./bin/gn gen out/web-wasm)
  log "ninja ($JOBS jobs) — the long step, ~15-45 min on first run"
  ninja -C "$out" skia modules/skparagraph:skparagraph modules/skshaper:skshaper
  ls -la "$out"/*.wasm.a
}

build_sdl3_wasm() {
  local src="$DEPS/SDL"
  local build="$src/build-web-wasm"
  if [ -f "$build/libSDL3.a" ]; then
    log "SDL3 wasm already built (build-web-wasm)"
    return 0
  fi
  build_emsdk
  git_clone_at "$src" "$SDL3_URL" "$SDL3_PIN"
  log "emcmake SDL3 (web-wasm, static, trimmed, no pthreads)"
  # emcmake/emmake come from the activated emsdk.
  (
    export EMSDK="$DEPS/emsdk"
    export PATH="$DEPS/emsdk/upstream/emscripten:$DEPS/emsdk:$PATH"
    # Trimmed like the native build + SDL_PTHREADS=OFF (single-threaded wasm).
    emcmake cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Release \
      -DSDL_SHARED=OFF -DSDL_STATIC=ON \
      -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_TESTS=OFF \
      -DSDL_CAMERA=OFF -DSDL_SENSOR=OFF \
      -DSDL_GPU=OFF -DSDL_RENDER_GPU=OFF -DSDL_RENDER_VULKAN=OFF \
      -DSDL_PTHREADS=OFF
    emmake cmake --build "$build" --parallel "$JOBS"
  )
  ls -la "$build"/libSDL3.a
}

# --- web-wasm: embedded default font ----------------------------------------
# Generates kx_skia/src/kx_font_wasm.h — DejaVu Sans embedded in the wasm
# binary so text renders in the browser (Devin issue #3 on PR #45). The header
# is generated, NOT committed (gitignored). Contract with
# kx_skia/src/kx_skia_wasm.cpp (picked up via __has_include, same directory):
#   static const unsigned char kKxDefaultFontData[] = { ...ttf bytes... };
#   static const size_t kKxDefaultFontSize = sizeof(kKxDefaultFontData);

FONT_ZIP_URL="https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.zip"
FONT_ZIP_MEMBER="dejavu-fonts-ttf-2.37/ttf/DejaVuSans.ttf"

generate_font_header() {
  local out="$ROOT/kx_skia/src/kx_font_wasm.h"
  if [ -f "$out" ]; then
    log "kx_font_wasm.h already generated"
    return 0
  fi
  local font_dir="$DEPS/fonts"
  local ttf="$font_dir/DejaVuSans.ttf"
  mkdir -p "$font_dir"
  if [ ! -f "$ttf" ]; then
    # DejaVu Sans 2.37 (Bitstream Vera license / public domain — embeddable).
    # The upstream git repo ships no raw ttf (source-only); the release zip
    # does. Extraction uses python3's zipfile — unzip is not a prerequisite.
    local zip="$font_dir/dejavu-fonts-ttf-2.37.zip"
    if [ ! -f "$zip" ]; then
      log "download DejaVu Sans 2.37 release zip (~5 MB)"
      curl -fsSL -o "$zip" "$FONT_ZIP_URL" || die "failed to download DejaVuSans.ttf"
    fi
    log "extract $(basename "$ttf") from release zip"
    python3 - "$zip" "$FONT_ZIP_MEMBER" "$ttf" <<'PYEOF'
import sys, zipfile
zip_path, member, dst = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(zip_path) as z:
    with z.open(member) as src, open(dst, "wb") as out:
        out.write(src.read())
PYEOF
  fi
  log "generate kx_font_wasm.h from $(basename "$ttf") ($(wc -c < "$ttf") bytes)"
  # Atomic write: generate to a temp file then move — an interrupted run
  # must not leave a partial header that the idempotence check would skip.
  local tmp_out="$out.tmp"
  python3 - "$ttf" "$tmp_out" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    data = f.read()
with open(dst, "w") as f:
    f.write("// kx_font_wasm.h — generated by scripts/fetch-deps.sh (web-wasm)\n")
    f.write("// Embedded default font (DejaVu Sans 2.37) for the WASM Skia backend.\n")
    f.write("// Regenerate: rm kx_skia/src/kx_font_wasm.h && scripts/fetch-deps.sh web-wasm\n")
    f.write("#pragma once\n")
    f.write("#include <cstddef>\n")
    f.write("#include <cstdint>\n\n")
    f.write("static const unsigned char kKxDefaultFontData[] = {\n")
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        f.write("    " + ",".join(f"0x{b:02x}" for b in chunk) + ",\n")
    f.write("};\n")
    f.write("static const size_t kKxDefaultFontSize = sizeof(kKxDefaultFontData);\n")
PYEOF
  mv "$tmp_out" "$out"
  ls -la "$out"
}

build_web_wasm() {
  build_emsdk
  build_skia_wasm
  build_sdl3_wasm
  generate_font_header
}

# --- main -------------------------------------------------------------------

# Guard: sourcing this script (e.g. to call generate_font_header in a test)
# must not run the component build.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  COMPONENTS=("$@")
  if [ "${#COMPONENTS[@]}" -eq 0 ]; then
    COMPONENTS=(skia sdl3 wamr)
  fi

  mkdir -p "$DEPS"

  for component in "${COMPONENTS[@]}"; do
    case "$component" in
      skia) build_skia ;;
      sdl3) build_sdl3 ;;
      wamr) build_wamr ;;
      web-wasm) build_web_wasm ;;
      *) die "unknown component '$component' (expected: skia | sdl3 | wamr | web-wasm)" ;;
    esac
  done

  log "done — artifacts in $DEPS ($TAG)"
  du -sh "$DEPS" 2>/dev/null || true
fi
