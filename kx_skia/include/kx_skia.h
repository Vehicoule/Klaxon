// kx_skia.h — Klaxon's C ABI over Skia. No C++ type crosses this boundary:
// Zig sees only opaque handles and C functions.
//
// Conventions:
//   - Colors are 0xRRGGBBAA (R in the high byte, alpha in the low byte).
//   - Coordinates are in pixels, origin top-left, y down.
//   - All functions are thread-confined to the caller's thread (no internal locking).
#ifndef KX_SKIA_H
#define KX_SKIA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum kx_backend {
    KX_BACKEND_RASTER = 0,           // CPU raster — always available, headless-capable
    KX_BACKEND_GRAPHITE_METAL = 1,   // macOS / iOS
    KX_BACKEND_GRAPHITE_VULKAN = 2,  // Linux / Android (API >= 33)
    KX_BACKEND_GANESH_GLES = 3,      // Android fallback (API < 33)
    KX_BACKEND_GANESH_GL = 4,        // Linux / Windows fallback
    KX_BACKEND_GRAPHITE_DAWN = 5,    // Windows (D3D12)
    KX_BACKEND_GRAPHITE_WEBGPU = 6,  // Web
    KX_BACKEND_GANESH_WEBGL2 = 7,    // Web fallback
} kx_backend;

typedef struct kx_ctx kx_ctx;

// Create a rendering context.
//   sdl_window — SDL_Window* (opaque). Required for GPU backends (the shim attaches
//                an onscreen surface to it). May be NULL for KX_BACKEND_RASTER.
//   width/height — target size in pixels.
// Returns NULL on failure (e.g. GPU backend unavailable).
kx_ctx* kx_create(void* sdl_window, int width, int height, kx_backend backend);
void kx_destroy(kx_ctx* ctx);
void kx_resize(kx_ctx* ctx, int width, int height);

// Frame lifecycle.
void kx_begin_frame(kx_ctx* ctx);
void kx_end_frame(kx_ctx* ctx); // GPU backends: submit + present. Raster: flush.

// Drawing (current frame canvas; call between begin/end_frame).
void kx_clear(kx_ctx* ctx, uint32_t rgba);
// Simple unshaped text (hello / debug). Shaped text (SkParagraph) comes in Phase 1.
void kx_draw_text(kx_ctx* ctx, const char* text, float x, float y, float size, uint32_t rgba);

// Readback — raster backend only. Copies the frame as RGBA (memory order R,G,B,A)
// into dst. dst_size must be >= width*height*4. Returns false on GPU backends
// (async readback lands in Phase 1) or on failure.
bool kx_readback_rgba(kx_ctx* ctx, void* dst, size_t dst_size, int* out_width, int* out_height);

// Introspection.
kx_backend kx_backend_of(const kx_ctx* ctx);
const char* kx_backend_name(kx_backend backend);

#ifdef __cplusplus
}
#endif

#endif // KX_SKIA_H
