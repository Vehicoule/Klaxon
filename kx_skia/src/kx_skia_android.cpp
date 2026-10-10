// kx_skia_android.cpp — Android platform implementation: Ganesh GLES (EGL)
// onscreen backend (FBO-0 pattern, mirror of kx_skia_wasm.cpp with EGL instead
// of WebGL2) + Android NDK font manager. Implements kx_skia_platform.h for
// aarch64-linux-android.
//
// Build (Phase 3d): CMake/NDK compiles this TU — Zig only builds the app
// static library (addAndroidLib in build.zig); the Gradle/CMake project links
// shim .o + libSDL3.so + libskia*.a into lib<app>.so. NDK clang++, flags
// -std=c++20 -fno-exceptions -fno-rtti -DSK_GANESH -DSK_GL
// -DSK_FORCE_8_BYTE_ALIGNMENT. Include roots: deps/skia, deps/skia/include,
// deps/SDL/include (this file's own directory provides kx_skia_platform.h).
//
// Raster is unavailable on Android (SDL's Android video backend does not
// implement SDL_CreateWindowFramebuffer), so Ganesh GLES is the only onscreen
// backend. The app (host.zig) requests an ES 3.0 context
// (SDL_GL_CONTEXT_PROFILE_ES, major 3, 8-bit stencil, double-buffered) and
// makes it current BEFORE kx_create. gpu_end_frame submits +
// SDL_GL_SwapWindow — eglSwapBuffers on SDL's EGLSurface presents the frame.
//
// GrGLMakeNativeInterface() is the EGL variant on Android: Skia's BUILD.gn
// compiles src/gpu/ganesh/gl/egl/GrGLMakeNativeInterface_egl.cpp for
// target_os="android", which resolves GL entry points through
// eglGetProcAddress (GrGLInterfaces::MakeEGL). GLES declarations come from
// the NDK sysroot (<GLES3/gl3.h>) — EGL itself declares no GL symbols.
#include "kx_skia_platform.h"

#include <SDL3/SDL.h>

#include <android/api-level.h>     // android_get_device_api_level (NDK builtin)
#include <android/native_window.h> // ANativeWindow

#include <GLES3/gl3.h> // NDK sysroot GLES3 header; glBindFramebuffer, GL_FRAMEBUFFER

#include "include/core/SkColorSpace.h"
#include "include/core/SkFontScanner.h"           // complete type for SkFontMgr_New_AndroidNDK's unique_ptr param
#include "include/core/SkImageInfo.h"
#include "include/core/SkSurface.h"
#include "include/gpu/ganesh/GrBackendSurface.h"    // GrBackendRenderTarget (complete type; GrGLBackendSurface.h only fwd-declares it)
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/GrTypes.h"              // kBottomLeft_GrSurfaceOrigin, k*_GrGLBackendState, GrSyncCpu
#include "include/gpu/ganesh/SkSurfaceGanesh.h"      // SkSurfaces::WrapBackendRenderTarget
#include "include/gpu/ganesh/gl/GrGLBackendSurface.h" // GrBackendRenderTargets::MakeGL
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"  // GrDirectContexts::MakeGL
#include "include/gpu/ganesh/gl/GrGLInterface.h"      // GrGLMakeNativeInterface (EGL variant on Android)
#include "include/gpu/ganesh/gl/GrGLTypes.h"          // GrGLFramebufferInfo
#include "src/gpu/ganesh/gl/GrGLDefines.h"            // GR_GL_RGBA8 (same private include as the wasm shim)
#include "include/ports/SkFontMgr_android_ndk.h"      // SkFontMgr_New_AndroidNDK (API >= 29)
#include "include/ports/SkFontMgr_directory.h"        // SkFontMgr_New_Custom_Directory
#include "include/ports/SkFontMgr_empty.h"            // SkFontMgr_New_Custom_Empty

#include <cstddef>
#include <cstdint>

namespace kx {

struct GpuState {
    SDL_Window* window = nullptr;
    sk_sp<GrDirectContext> dctx;
    sk_sp<SkSurface> frame_surface;
    int width = 0;
    int height = 0;
};

bool gpu_init(GpuState** out, void* sdl_window, int width, int height) {
    if (!out || !sdl_window) return false;
    auto* window = static_cast<SDL_Window*>(sdl_window);
    // The caller (host, android path) creates an ES 3.0 context on the SDL
    // window and makes it current BEFORE kx_create. Ganesh binds to whatever
    // EGL context is current — GrGLMakeNativeInterface resolves GL entry
    // points via eglGetProcAddress — so the context must already be current.
    // (SDL_GLContext is the EGLContext on Android.)
    if (!SDL_GL_GetCurrentContext()) return false;
    // The ANativeWindow backs SDL's EGLSurface (the FBO-0 target we render
    // into). SDL exposes it on the window properties; this SDL pin has no
    // SDL_GetWindowProperty(window, name) convenience wrapper, so go through
    // SDL_GetWindowProperties + SDL_GetPointerProperty.
    auto* native_window = static_cast<ANativeWindow*>(SDL_GetPointerProperty(
        SDL_GetWindowProperties(window), SDL_PROP_WINDOW_ANDROID_WINDOW_POINTER, nullptr));
    if (!native_window) return false;

    sk_sp<const GrGLInterface> interface = GrGLMakeNativeInterface();
    if (!interface) return false;
    sk_sp<GrDirectContext> dctx = GrDirectContexts::MakeGL(std::move(interface));
    if (!dctx) return false;

    auto* state = new GpuState();
    state->window = window;
    state->dctx = std::move(dctx);
    state->width = width;
    state->height = height;
    *out = state;
    return true;
}

void gpu_shutdown(GpuState* state) {
    if (!state) return;
    state->frame_surface = nullptr;
    if (state->dctx) {
        // Wait for in-flight GPU work before tearing the context down.
        state->dctx->flushAndSubmit(GrSyncCpu::kYes);
        state->dctx = nullptr;
    }
    delete state;
}

void gpu_resize(GpuState* state, int width, int height) {
    if (!state) return;
    // The onscreen target wraps FBO 0 and is re-created from these dimensions
    // on the next gpu_begin_frame.
    state->width = width;
    state->height = height;
}

SkCanvas* gpu_begin_frame(GpuState* state) {
    if (!state || !state->dctx || state->width <= 0 || state->height <= 0) return nullptr;

    // The onscreen canvas is FBO 0 (SDL's EGLSurface on the ANativeWindow).
    // Make it current and tell Skia its GL state is unknown (first frame /
    // context loss / EGLSurface re-created after a window resize).
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    state->dctx->resetContext(kRenderTarget_GrGLBackendState | kMisc_GrGLBackendState);

    // Wrap FBO 0 in a Skia backend render target (CanvasKit pattern, same as
    // the wasm shim). The GLES window surface is RGBA8 with an 8-bit stencil
    // (the context attributes requested in host.zig).
    GrGLFramebufferInfo info;
    info.fFBOID = 0;
    info.fFormat = GR_GL_RGBA8;
    const GrBackendRenderTarget target = GrBackendRenderTargets::MakeGL(
        state->width, state->height, /*sampleCnt=*/0, /*stencilBits=*/8, info);
    state->frame_surface = SkSurfaces::WrapBackendRenderTarget(
        state->dctx.get(), target, kBottomLeft_GrSurfaceOrigin,
        kRGBA_8888_SkColorType, SkColorSpace::MakeSRGB(), nullptr);
    if (!state->frame_surface) return nullptr;
    return state->frame_surface->getCanvas();
}

void gpu_end_frame(GpuState* state) {
    if (!state || !state->dctx) return;
    state->dctx->flushAndSubmit();
    // Release the wrapped target before present: eglSwapBuffers (via
    // SDL_GL_SwapWindow) composites SDL's EGLSurface onto the ANativeWindow.
    state->frame_surface = nullptr;
    if (state->window) SDL_GL_SwapWindow(state->window);
}

sk_sp<SkFontMgr> platform_font_mgr() {
    // AFontMgr over the NDK font API — requires API >= 29 (the Skia android
    // build targets ndk_api=29); returns nullptr on older devices.
    if (sk_sp<SkFontMgr> mgr = SkFontMgr_New_AndroidNDK(false, nullptr)) {
        return mgr;
    }
    // Fallback: FreeType over the system font directory.
    if (sk_sp<SkFontMgr> mgr = SkFontMgr_New_Custom_Directory("/system/fonts")) {
        return mgr;
    }
    // Last resort: metrics work, no glyphs.
    return SkFontMgr_New_Custom_Empty();
}

} // namespace kx

// Exported for the Zig side's backend selection (Graphite Vulkan on API >= 33,
// Ganesh GLES below). NDK builtin — reads the device API level at runtime.
// (NDK r26+ renamed __android_get_device_api_level to android_get_device_api_level;
// fetch-deps.sh selects the newest NDK, so the new name is the one that links.)
extern "C" int kx_android_api_level() {
    return android_get_device_api_level();
}
