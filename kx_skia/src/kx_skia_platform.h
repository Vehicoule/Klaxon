// kx_skia_platform.h — platform interface for the GPU backends.
// Implemented per OS (kx_skia_macos.mm, kx_skia_linux.cpp, ...). C++ only —
// this header never crosses the Zig ABI.
#pragma once

#include "include/core/SkCanvas.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkRefCnt.h"

namespace kx {

// Opaque per-platform GPU state (defined in the platform implementation).
struct GpuState;

// Create the GPU context and attach an onscreen surface to sdl_window (SDL_Window*).
bool gpu_init(GpuState** out, void* sdl_window, int width, int height);
void gpu_shutdown(GpuState* state);
void gpu_resize(GpuState* state, int width, int height);

// Begin a frame: acquire the onscreen target, return the canvas to draw into.
SkCanvas* gpu_begin_frame(GpuState* state);
// End a frame: snap the recording, submit, present.
void gpu_end_frame(GpuState* state);

// Platform font manager (macOS: CoreText, Linux: custom directory, ...).
sk_sp<SkFontMgr> platform_font_mgr();

} // namespace kx
