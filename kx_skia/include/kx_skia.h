// kx_skia.h — Klaxon's C ABI over Skia. No C++ type crosses this boundary:
// Zig sees only opaque handles and C functions.
//
// Conventions:
//   - Colors are 0xRRGGBBAA (R in the high byte, alpha in the low byte).
//   - Coordinates are in pixels, origin top-left, y down.
//   - All functions are thread-confined to the caller's thread (no internal
//     locking). Exception: the font manager is process-global (lazily
//     initialized once) because text metrics are needed before/without a ctx.
//
// Version history:
//   0.1.0 — Phase 0: raster, clear, text, rect, rrect, readback.
//   0.2.0 — Phase 1b: + kx_draw_text_styled (bold-aware text), + kx_measure_text
//           (text metrics for widget layout), + image registry (create once,
//           draw many — no per-frame allocation). Purely additive: the 0.1.0
//           entry points keep their signatures (ADR-0009: breaking changes
//           bump the major version; additive changes bump the minor).
//   0.3.0 — Phase 1e: + canvas state (kx_save/kx_restore), transforms
//           (kx_translate/kx_scale) for paint-time animated offsets/scales,
//           + clipping (kx_clip_rect/kx_clip_reset) for dirty-rect repaints.
//   0.4.0 — Phase 2a: + kx_layer_alpha (saveLayer with alpha) for fade
//           transitions. Restored with kx_restore, like kx_save.
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
// Simple unshaped text, y = baseline. Shaped text (SkParagraph) comes later.
void kx_draw_text(kx_ctx* ctx, const char* text, float x, float y, float size, uint32_t rgba);
// Bold-aware text variant (added in 0.2.0; kx_draw_text is unchanged for ABI
// stability — it delegates with bold=false).
void kx_draw_text_styled(kx_ctx* ctx, const char* text, float x, float y, float size, bool bold, uint32_t rgba);
// Fill an axis-aligned rectangle with a solid color.
void kx_fill_rect(kx_ctx* ctx, float x, float y, float w, float h, uint32_t rgba);
// Fill a rounded rectangle with a solid color.
void kx_fill_rrect(kx_ctx* ctx, float x, float y, float w, float h, float radius, uint32_t rgba);

// Canvas state + transforms (added in 0.3.0). save/restore must be balanced
// within a frame; a wrapper widget wraps its children's paint in a pair.
void kx_save(kx_ctx* ctx);
void kx_restore(kx_ctx* ctx);
void kx_translate(kx_ctx* ctx, float dx, float dy);
void kx_scale(kx_ctx* ctx, float sx, float sy);
// Clip the current frame to a rect (intersect with the existing clip).
// kx_clip_rect saves the canvas state; kx_clip_reset restores it. The surface
// is retained between frames: repainting the tree clipped to the damaged
// region is the dirty-rect path (Phase 1e).
void kx_clip_rect(kx_ctx* ctx, float x, float y, float w, float h);
void kx_clip_reset(kx_ctx* ctx);
// Push an alpha layer: everything drawn until the matching kx_restore
// composites at `alpha` opacity (fade transitions, Phase 2a). Alpha is
// clamped to [0,1].
void kx_layer_alpha(kx_ctx* ctx, float alpha);
// Stroke a polyline (added in 0.5.0): moveTo/lineTo through the `count`
// points with a solid color. round_cap selects round line caps (progress
// indicators). Arcs and wavy indicators are polylines generated in Zig —
// no path type crosses this boundary.
void kx_stroke_polyline(kx_ctx* ctx, const float* xs, const float* ys, int count, float stroke_w, bool round_cap, uint32_t rgba);

// Text metrics for widget layout. Ctx-independent: fonts are process-global.
//   width   — advance width in pixels
//   height  — ascent + descent
//   ascent  — line top → baseline (positive)
//   descent — baseline → line bottom (positive)
typedef struct kx_text_metrics {
    float width;
    float height;
    float ascent;
    float descent;
} kx_text_metrics;
kx_text_metrics kx_measure_text(const char* text, float size, bool bold);

// Images (per-ctx registry). Create once from RGBA pixels (memory order
// R,G,B,A, unpremultiplied), draw many times — no per-frame allocation.
// Returns 0 on failure. Destroy when the owner is done.
uint64_t kx_image_create(kx_ctx* ctx, const uint8_t* rgba, int32_t width, int32_t height);
void kx_image_destroy(kx_ctx* ctx, uint64_t image);
// Draw an image stretched into the destination rect (nearest sampling).
void kx_draw_image(kx_ctx* ctx, uint64_t image, float x, float y, float w, float h);

// Readback — raster backend only. Copies the frame as RGBA (memory order R,G,B,A)
// into dst. dst_size must be >= width*height*4. Returns false on GPU backends
// (async readback lands in Phase 1) or on failure.
bool kx_readback_rgba(kx_ctx* ctx, void* dst, size_t dst_size, int* out_width, int* out_height);

// Introspection.
kx_backend kx_backend_of(const kx_ctx* ctx);
const char* kx_backend_name(kx_backend backend);
// ABI version (semver). Breaking changes bump the major version. (ADR-0009)
const char* kx_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif // KX_SKIA_H
