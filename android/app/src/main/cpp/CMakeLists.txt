# Klaxon gallery — native glue for the Android APK (Phase 3d).
#
# Produces libmain.so: the kx_skia C++ shim + the Zig app (libgallery.a,
# built by `zig build -Dtarget=aarch64-linux-android android-lib`) linked
# against prebuilt Skia (deps/skia/out/android-arm64) and SDL3
# (deps/SDL/build-android-arm64/libSDL3.so — both from
# `scripts/fetch-deps.sh android-arm64`, requires the Android NDK).
#
# SDLActivity (Java) loads "SDL3" then "main" and runs the exported
# SDL_main() (src/gallery_main.zig) on SDL's main thread.
cmake_minimum_required(VERSION 3.22.1)
project(klaxon_gallery CXX)

# android/app/src/main/cpp -> repo root.
get_filename_component(KLAXON_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)

# --- Zig app: libgallery.a ------------------------------------------------
# b.installArtifact() in build.zig lands it in zig-out/lib (not zig-out/android).
add_library(kx_gallery STATIC IMPORTED)
set_target_properties(kx_gallery PROPERTIES
    IMPORTED_LOCATION "${KLAXON_ROOT}/zig-out/lib/libgallery.a")

# --- SDL3: shared lib, shipped inside the APK next to libmain.so ----------
add_library(SDL3 SHARED IMPORTED)
set_target_properties(SDL3 PROPERTIES
    IMPORTED_LOCATION "${KLAXON_ROOT}/deps/SDL/build-android-arm64/libSDL3.so")

# --- Skia: static libs -----------------------------------------------------
# Same list as linkRuntime() in build.zig — update both together.
set(KX_SKIA_LIBS
    freetype2 harfbuzz icu png skcms
    skia skparagraph skshaper skunicode_core skunicode_icu zlib)
foreach(lib IN LISTS KX_SKIA_LIBS)
    add_library(kx_skia_${lib} STATIC IMPORTED)
    set_target_properties(kx_skia_${lib} PROPERTIES
        IMPORTED_LOCATION "${KLAXON_ROOT}/deps/skia/out/android-arm64/lib${lib}.a")
endforeach()

# --- libmain.so: shim + app ------------------------------------------------
# OUTPUT_NAME main -> libmain.so (loaded by SDLActivity as "main").
add_library(main SHARED
    "${KLAXON_ROOT}/kx_skia/src/kx_skia_common.cpp"
    "${KLAXON_ROOT}/kx_skia/src/kx_skia_android.cpp")
set_target_properties(main PROPERTIES OUTPUT_NAME "main")

target_include_directories(main PRIVATE
    "${KLAXON_ROOT}/kx_skia/include"
    "${KLAXON_ROOT}/deps/skia"
    "${KLAXON_ROOT}/deps/skia/include"
    "${KLAXON_ROOT}/deps/SDL/include")

# Same flags as the Zig-built shim (shim_flags in build.zig).
target_compile_options(main PRIVATE
    -std=c++20 -fno-exceptions -fno-rtti
    -DSK_GANESH -DSK_GRAPHITE -DSK_GL -DNDEBUG)

# --whole-archive: SDL_main is exported but referenced by nobody at link
# time — without it the linker would drop the archive member defining it.
# --start-group: the Skia static libs reference each other circularly.
target_link_libraries(main PRIVATE
    "-Wl,--whole-archive"
    kx_gallery
    "-Wl,--no-whole-archive"
    SDL3
    "-Wl,--start-group"
    kx_skia_freetype2 kx_skia_harfbuzz kx_skia_icu kx_skia_png kx_skia_skcms
    kx_skia_skia kx_skia_skparagraph kx_skia_skshaper
    kx_skia_skunicode_core kx_skia_skunicode_icu kx_skia_zlib
    "-Wl,--end-group"
    log EGL GLESv2 android)

# AGP packages every .so found in the CMake output dir into lib/<abi>/ —
# IMPORTED libraries are not copied automatically, so stage libSDL3.so
# next to libmain.so.
add_custom_command(TARGET main POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${KLAXON_ROOT}/deps/SDL/build-android-arm64/libSDL3.so"
        "$<TARGET_FILE_DIR:main>/libSDL3.so"
    COMMENT "Staging libSDL3.so next to libmain.so")
