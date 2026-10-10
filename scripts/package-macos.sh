#!/bin/bash
# package-macos.sh — build + package a Klaxon app into a .app bundle (macOS arm64).
#
# Usage: scripts/package-macos.sh [app-name] [output-dir] [--dmg]
#   app-name   — one of: hello, gallery, navigator, i18n, a11y (default: gallery)
#   output-dir — where to place the .app (default: ./dist)
#   --dmg      — also wrap the .app in a drag-and-drop .dmg (Phase 3b.3)
#
# Produces: <output-dir>/Klaxon-<app>.app
#           <output-dir>/Klaxon-<app>.dmg   (only with --dmg)
# The .app is a standard macOS bundle: Contents/{Info.plist, MacOS/<exe>, Resources/}
set -euo pipefail

APP_NAME="${1:-gallery}"
OUTPUT_DIR="${2:-./dist}"
WITH_DMG=false
if [ "${3:-}" = "--dmg" ]; then WITH_DMG=true; fi
BUNDLE_NAME="Klaxon-${APP_NAME}.app"
BUNDLE_PATH="${OUTPUT_DIR}/${BUNDLE_NAME}"

# Map app name → build step + executable name.
case "${APP_NAME}" in
    hello)     BUILD_STEP="" ;;           # zig build (default = hello)
    gallery)   BUILD_STEP="gallery" ;;
    navigator) BUILD_STEP="navigator" ;;
    i18n)      BUILD_STEP="i18n" ;;
    a11y)      BUILD_STEP="a11y" ;;
    *) echo "Unknown app: ${APP_NAME}"; echo "Valid: hello, gallery, navigator, i18n, a11y"; exit 1 ;;
esac

EXE_NAME="${APP_NAME}"
[ "${APP_NAME}" = "hello" ] && EXE_NAME="hello"

# create_dmg <bundle-path> — wrap the .app in a drag-and-drop .dmg:
# the .app on the left, a symlink to /Applications on the right.
# Uses hdiutil (macOS system tool, works headless).
create_dmg() {
    local bundle_path="$1"
    local vol_name="Klaxon Gallery"
    local dmg="${OUTPUT_DIR}/Klaxon-${APP_NAME}.dmg"
    local tmp_dmg="${OUTPUT_DIR}/.klaxon-tmp.dmg"

    rm -f "$tmp_dmg" "$dmg"
    echo "==> Creating DMG (read-write temp)..."
    hdiutil create -srcfolder "$bundle_path" -volname "$vol_name" \
        -fs HFS+ -fsargs "-c c=64,a=16,e=16" -format UDRW -size 200m "$tmp_dmg"

    # Mount, add the /Applications symlink, unmount.
    # Detach first in case a stale mount from a previous run is still there.
    local mount_point="/Volumes/${vol_name}"
    hdiutil detach "$mount_point" -quiet 2>/dev/null || true
    hdiutil attach "$tmp_dmg" -mountpoint "$mount_point" -nobrowse -quiet
    ln -sfn /Applications "$mount_point/Applications"
    hdiutil detach "$mount_point" -quiet

    # Compress to the final read-only .dmg (UDZO = zlib).
    echo "==> Compressing DMG..."
    hdiutil convert "$tmp_dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg"
    rm -f "$tmp_dmg"
    echo "==> Done: ${dmg}"
    ls -lh "$dmg"
}

echo "==> Building ${APP_NAME} (ReleaseSmall)..."
if [ -n "${BUILD_STEP}" ]; then
    zig build "${BUILD_STEP}" -Doptimize=ReleaseSmall
else
    zig build -Doptimize=ReleaseSmall
fi

EXE_SRC="zig-out/bin/${EXE_NAME}"
if [ ! -f "${EXE_SRC}" ]; then
    echo "Error: executable not found at ${EXE_SRC}"
    exit 1
fi

EXE_SIZE=$(du -h "${EXE_SRC}" | cut -f1)
echo "==> Executable: ${EXE_SRC} (${EXE_SIZE})"

echo "==> Creating bundle structure..."
rm -rf "${BUNDLE_PATH}"
mkdir -p "${BUNDLE_PATH}/Contents/MacOS"
mkdir -p "${BUNDLE_PATH}/Contents/Resources"
mkdir -p "${OUTPUT_DIR}"

# Copy the executable.
cp "${EXE_SRC}" "${BUNDLE_PATH}/Contents/MacOS/klaxon"
chmod +x "${BUNDLE_PATH}/Contents/MacOS/klaxon"

# Copy Info.plist.
cp assets/Info.plist "${BUNDLE_PATH}/Contents/Info.plist"

# Code-sign (ad-hoc) so Gatekeeper doesn't block it.
echo "==> Ad-hoc code signing..."
codesign --force --deep --sign - "${BUNDLE_PATH}" 2>/dev/null || {
    echo "Warning: code signing failed (continuing without it)"
}

BUNDLE_SIZE=$(du -sh "${BUNDLE_PATH}" | cut -f1)
echo ""
echo "==> Done: ${BUNDLE_PATH} (${BUNDLE_SIZE})"
echo "    Run with: open \"${BUNDLE_PATH}\""
echo "    Or:       \"${BUNDLE_PATH}/Contents/MacOS/klaxon\" metal"

if [ "$WITH_DMG" = true ]; then
    echo ""
    create_dmg "${BUNDLE_PATH}"
    echo "    Install: open the .dmg and drag the app into /Applications."
fi
