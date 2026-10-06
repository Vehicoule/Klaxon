// kx_skia_linux.cpp — Linux platform implementation (Phase 0: raster only).
// GPU backends (EGL + Vulkan) land in Phase 3a; until then gpu_init returns
// false and the framework runs on the raster backend. Font manager: FreeType
// over the system font directories.
#include "kx_skia_platform.h"

#include "include/core/SkFontMgr.h"
#include "include/ports/SkFontMgr_directory.h"
#include "include/ports/SkFontMgr_empty.h"

namespace kx {

struct GpuState {}; // stub — no GPU backend yet (Phase 3a)

bool gpu_init(GpuState** out, void* sdl_window, int width, int height) {
    (void)out;
    (void)sdl_window;
    (void)width;
    (void)height;
    return false; // Phase 3a: EGL + Vulkan
}
void gpu_shutdown(GpuState* state) { (void)state; }
void gpu_resize(GpuState* state, int width, int height) {
    (void)state;
    (void)width;
    (void)height;
}
SkCanvas* gpu_begin_frame(GpuState* state) {
    (void)state;
    return nullptr;
}
void gpu_end_frame(GpuState* state) { (void)state; }

sk_sp<SkFontMgr> platform_font_mgr() {
    // System font directories (DejaVu et al. on CI runners).
    for (const char* dir : {"/usr/share/fonts", "/usr/local/share/fonts"}) {
        if (auto mgr = SkFontMgr_New_Custom_Directory(dir)) return mgr;
    }
    return SkFontMgr_New_Custom_Empty();
}

} // namespace kx
