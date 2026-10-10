#!/bin/bash
# package-macos.sh — build + package a Klaxon app into a .app bundle (macOS arm64).
#
# Usage: scripts/package-macos.sh [app-name] [output-dir]
#   app-name   — one of: hello, gallery, navigator, i18n, a11y (default: gallery)
#   output-dir — where to place the .app (default: ./dist)
#
# Produces: <output-dir>/Klaxon-<app>.app
# The .app is a standard macOS bundle: Contents/{Info.plist, MacOS/<exe>, Resources/}
set -euo pipefail

APP_NAME="${1:-gallery}"
OUTPUT_DIR="${2:-./dist}"
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
