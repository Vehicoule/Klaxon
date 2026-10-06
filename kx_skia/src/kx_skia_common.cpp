// kx_skia_common.cpp — backend-independent implementation of the kx_skia ABI:
// raster surfaces, drawing helpers, readback. GPU backends plug in through
// kx_skia_platform.h.
#include "kx_skia.h"
#include "kx_skia_platform.h"

#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkFontStyle.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTypeface.h"

#include <cstring>

struct kx_ctx {
    int width = 0;
    int height = 0;
    kx_backend backend = KX_BACKEND_RASTER;
    sk_sp<SkSurface> raster;     // raster backend
    kx::GpuState* gpu = nullptr; // GPU backends
    sk_sp<SkFontMgr> fonts;
    SkCanvas* canvas = nullptr;  // current frame
};

// kx color: 0xRRGGBBAA → SkColor: 0xAARRGGBB
static SkColor kx_to_skcolor(uint32_t rgba) {
    const uint32_t r = (rgba >> 24) & 0xFF;
    const uint32_t g = (rgba >> 16) & 0xFF;
    const uint32_t b = (rgba >> 8) & 0xFF;
    const uint32_t a = rgba & 0xFF;
    return SkColorSetARGB(a, r, g, b);
}

kx_ctx* kx_create(void* sdl_window, int width, int height, kx_backend backend) {
    if (width <= 0 || height <= 0) return nullptr;
    auto* ctx = new kx_ctx();
    ctx->width = width;
    ctx->height = height;
    ctx->backend = backend;
    ctx->fonts = kx::platform_font_mgr();

    if (backend == KX_BACKEND_RASTER) {
        ctx->raster = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(width, height));
        if (!ctx->raster) { delete ctx; return nullptr; }
    } else {
        if (!kx::gpu_init(&ctx->gpu, sdl_window, width, height)) { delete ctx; return nullptr; }
    }
    return ctx;
}

void kx_destroy(kx_ctx* ctx) {
    if (!ctx) return;
    if (ctx->gpu) kx::gpu_shutdown(ctx->gpu);
    delete ctx;
}

void kx_resize(kx_ctx* ctx, int width, int height) {
    if (!ctx || width <= 0 || height <= 0) return;
    ctx->width = width;
    ctx->height = height;
    if (ctx->raster) {
        ctx->raster = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(width, height));
    } else if (ctx->gpu) {
        kx::gpu_resize(ctx->gpu, width, height);
    }
}

void kx_begin_frame(kx_ctx* ctx) {
    if (!ctx) return;
    if (ctx->raster) {
        ctx->canvas = ctx->raster->getCanvas();
    } else if (ctx->gpu) {
        ctx->canvas = kx::gpu_begin_frame(ctx->gpu);
    }
}

void kx_end_frame(kx_ctx* ctx) {
    if (!ctx) return;
    if (ctx->gpu) {
        kx::gpu_end_frame(ctx->gpu);
    }
    // Raster is synchronous — drawing lands in the pixel buffer immediately,
    // nothing to flush (SkSurface::flush no longer exists at this pin).
    ctx->canvas = nullptr;
}

void kx_clear(kx_ctx* ctx, uint32_t rgba) {
    if (ctx && ctx->canvas) ctx->canvas->clear(kx_to_skcolor(rgba));
}

void kx_draw_text(kx_ctx* ctx, const char* text, float x, float y, float size, uint32_t rgba) {
    if (!ctx || !ctx->canvas || !text) return;
    SkFont font;
    if (ctx->fonts) {
        font.setTypeface(ctx->fonts->legacyMakeTypeface(nullptr, SkFontStyle::Normal()));
    }
    font.setSize(size);
    SkPaint paint;
    paint.setColor(kx_to_skcolor(rgba));
    paint.setAntiAlias(true);
    ctx->canvas->drawSimpleText(text, std::strlen(text), SkTextEncoding::kUTF8, x, y, font, paint);
}

bool kx_readback_rgba(kx_ctx* ctx, void* dst, size_t dst_size, int* out_width, int* out_height) {
    if (!ctx || !ctx->raster || !dst) return false;
    if (out_width) *out_width = ctx->width;
    if (out_height) *out_height = ctx->height;
    const size_t needed = static_cast<size_t>(ctx->width) * static_cast<size_t>(ctx->height) * 4;
    if (dst_size < needed) return false;
    const SkImageInfo dst_info = SkImageInfo::Make(ctx->width, ctx->height,
                                                  kRGBA_8888_SkColorType, kUnpremul_SkAlphaType);
    return ctx->raster->readPixels(dst_info, dst, static_cast<size_t>(ctx->width) * 4, 0, 0);
}

kx_backend kx_backend_of(const kx_ctx* ctx) {
    return ctx ? ctx->backend : KX_BACKEND_RASTER;
}

const char* kx_backend_name(kx_backend backend) {
    switch (backend) {
        case KX_BACKEND_RASTER: return "raster";
        case KX_BACKEND_GRAPHITE_METAL: return "graphite-metal";
        case KX_BACKEND_GRAPHITE_VULKAN: return "graphite-vulkan";
        case KX_BACKEND_GANESH_GLES: return "ganesh-gles";
        case KX_BACKEND_GANESH_GL: return "ganesh-gl";
        case KX_BACKEND_GRAPHITE_DAWN: return "graphite-dawn-d3d12";
        case KX_BACKEND_GRAPHITE_WEBGPU: return "graphite-webgpu";
        case KX_BACKEND_GANESH_WEBGL2: return "ganesh-webgl2";
    }
    return "unknown";
}
