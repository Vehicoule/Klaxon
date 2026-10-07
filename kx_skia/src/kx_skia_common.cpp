// kx_skia_common.cpp — backend-independent implementation of the kx_skia ABI:
// raster surfaces, drawing helpers, readback. GPU backends plug in through
// kx_skia_platform.h.
#include "kx_skia.h"
#include "kx_skia_platform.h"

#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkFontMetrics.h"
#include "include/core/SkFontStyle.h"
#include "include/core/SkImage.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkRect.h"
#include "include/core/SkSamplingOptions.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTypeface.h"

#include <cstring>
#include <unordered_map>

struct kx_ctx {
    int width = 0;
    int height = 0;
    kx_backend backend = KX_BACKEND_RASTER;
    sk_sp<SkSurface> raster;     // raster backend
    kx::GpuState* gpu = nullptr; // GPU backends
    SkCanvas* canvas = nullptr;  // current frame
    // Image registry (per-ctx; images are plain pixel data, shared by all draws).
    std::unordered_map<uint64_t, sk_sp<SkImage>> images;
    uint64_t next_image_id = 1;
};

// Font manager is process-global: text metrics are needed at layout time,
// before/without a kx_ctx. Initialized once (thread-confined afterwards).
static sk_sp<SkFontMgr>& kx_fonts() {
    static sk_sp<SkFontMgr> mgr = kx::platform_font_mgr();
    return mgr;
}

static SkFont kx_make_font(float size, bool bold) {
    SkFont font;
    if (kx_fonts()) {
        font.setTypeface(kx_fonts()->legacyMakeTypeface(nullptr, bold ? SkFontStyle::Bold() : SkFontStyle::Normal()));
    }
    font.setSize(size);
    return font;
}

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

void kx_draw_text(kx_ctx* ctx, const char* text, float x, float y, float size, bool bold, uint32_t rgba) {
    if (!ctx || !ctx->canvas || !text) return;
    SkFont font = kx_make_font(size, bold);
    SkPaint paint;
    paint.setColor(kx_to_skcolor(rgba));
    paint.setAntiAlias(true);
    ctx->canvas->drawSimpleText(text, std::strlen(text), SkTextEncoding::kUTF8, x, y, font, paint);
}

kx_text_metrics kx_measure_text(const char* text, float size, bool bold) {
    kx_text_metrics m = {0, 0, 0, 0};
    if (!text) return m;
    const SkFont font = kx_make_font(size, bold);
    SkFontMetrics fm;
    font.getMetrics(&fm);
    m.ascent = -fm.fAscent; // fAscent is negative (above the baseline)
    m.descent = fm.fDescent;
    m.height = m.ascent + m.descent;
    if (font.getTypeface()) {
        m.width = font.measureText(text, std::strlen(text), SkTextEncoding::kUTF8);
    }
    return m;
}

uint64_t kx_image_create(kx_ctx* ctx, const uint8_t* rgba, int32_t w, int32_t h) {
    if (!ctx || !rgba || w <= 0 || h <= 0) return 0;
    const size_t bytes = static_cast<size_t>(w) * static_cast<size_t>(h) * 4;
    sk_sp<SkData> data = SkData::MakeWithCopy(rgba, bytes);
    if (!data) return 0;
    sk_sp<SkImage> img = SkImages::RasterFromData(
        SkImageInfo::Make(w, h, kRGBA_8888_SkColorType, kUnpremul_SkAlphaType),
        std::move(data), static_cast<size_t>(w) * 4);
    if (!img) return 0;
    const uint64_t id = ctx->next_image_id++;
    ctx->images.emplace(id, std::move(img));
    return id;
}

void kx_image_destroy(kx_ctx* ctx, uint64_t image) {
    if (ctx && image) ctx->images.erase(image);
}

void kx_draw_image(kx_ctx* ctx, uint64_t image, float x, float y, float w, float h) {
    if (!ctx || !ctx->canvas || !image || w <= 0 || h <= 0) return;
    auto it = ctx->images.find(image);
    if (it == ctx->images.end()) return;
    const SkImage* img = it->second.get();
    ctx->canvas->drawImageRect(img, SkRect::MakeIWH(img->width(), img->height()),
                               SkRect::MakeXYWH(x, y, w, h), SkSamplingOptions(), nullptr,
                               SkCanvas::kStrict_SrcRectConstraint);
}

void kx_fill_rect(kx_ctx* ctx, float x, float y, float w, float h, uint32_t rgba) {
    if (!ctx || !ctx->canvas) return;
    SkPaint paint;
    paint.setColor(kx_to_skcolor(rgba));
    paint.setAntiAlias(true);
    ctx->canvas->drawRect(SkRect::MakeXYWH(x, y, w, h), paint);
}

void kx_fill_rrect(kx_ctx* ctx, float x, float y, float w, float h, float radius, uint32_t rgba) {
    if (!ctx || !ctx->canvas) return;
    SkPaint paint;
    paint.setColor(kx_to_skcolor(rgba));
    paint.setAntiAlias(true);
    ctx->canvas->drawRoundRect(SkRect::MakeXYWH(x, y, w, h), radius, radius, paint);
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

const char* kx_abi_version(void) {
    return "0.2.0";
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
