// kx_skia_macos.mm — macOS platform implementation: Graphite (Metal) onscreen
// backend + CoreText font manager. arm64 only (no x64).
#include "kx_skia_platform.h"

#include <SDL3/SDL.h>
#include <SDL3/SDL_metal.h>

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "include/core/SkImageInfo.h"
#include "include/core/SkSurface.h"
#include "include/gpu/graphite/Context.h"
#include "include/gpu/graphite/ContextOptions.h"
#include "include/gpu/graphite/GraphiteTypes.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Recording.h"
#include "include/gpu/graphite/Surface.h"
#include "include/gpu/graphite/mtl/MtlBackendContext.h"
#include "include/gpu/graphite/mtl/MtlGraphiteTypes_cpp.h"
#include "include/ports/SkCFObject.h"
#include "include/ports/SkFontMgr_mac_ct.h"

#include <memory>

namespace kx {

struct GpuState {
    std::unique_ptr<skgpu::graphite::Context> context;
    std::unique_ptr<skgpu::graphite::Recorder> recorder;
    sk_sp<SkSurface> frame_surface;
    CAMetalLayer* layer = nil;
    SDL_MetalView metal_view = nullptr;
    id<CAMetalDrawable> drawable = nil;
    int width = 0;
    int height = 0;
};

bool gpu_init(GpuState** out, void* sdl_window, int width, int height) {
    if (!sdl_window || !out) return false;
    auto* state = new GpuState();
    state->width = width;
    state->height = height;

    state->metal_view = SDL_Metal_CreateView(static_cast<SDL_Window*>(sdl_window));
    if (!state->metal_view) { delete state; return false; }
    state->layer = (__bridge CAMetalLayer*)SDL_Metal_GetLayer(state->metal_view);
    if (!state->layer) { SDL_Metal_DestroyView(state->metal_view); delete state; return false; }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { SDL_Metal_DestroyView(state->metal_view); delete state; return false; }
    state->layer.device = device;
    state->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    state->layer.framebufferOnly = YES;
    state->layer.drawableSize = CGSizeMake(width, height);

    id<MTLCommandQueue> queue = [device newCommandQueue];

    skgpu::graphite::MtlBackendContext mtl_ctx;
    // No ARC: CFRetain produces the +1 reference that sk_cfp adopts (and releases).
    mtl_ctx.fDevice = sk_cfp<CFTypeRef>((CFTypeRef)CFRetain((__bridge CFTypeRef)device));
    mtl_ctx.fQueue = sk_cfp<CFTypeRef>((CFTypeRef)CFRetain((__bridge CFTypeRef)queue));
    state->context = skgpu::graphite::ContextFactory::MakeMetal(mtl_ctx, skgpu::graphite::ContextOptions{});
    if (!state->context) { SDL_Metal_DestroyView(state->metal_view); delete state; return false; }

    *out = state;
    return true;
}

void gpu_shutdown(GpuState* state) {
    if (!state) return;
    state->frame_surface = nullptr;
    state->recorder.reset();
    if (state->context) {
        state->context->submit(skgpu::graphite::SyncToCpu::kYes);
        state->context.reset();
    }
    if (state->metal_view) SDL_Metal_DestroyView(state->metal_view);
    delete state;
}

void gpu_resize(GpuState* state, int width, int height) {
    if (!state || !state->layer) return;
    state->width = width;
    state->height = height;
    state->layer.drawableSize = CGSizeMake(width, height);
}

SkCanvas* gpu_begin_frame(GpuState* state) {
    if (!state || !state->context || !state->layer) return nullptr;
    state->drawable = [state->layer nextDrawable];
    if (!state->drawable) return nullptr;
    state->recorder = state->context->makeRecorder();
    if (!state->recorder) return nullptr;
    const skgpu::graphite::BackendTexture backend_tex = skgpu::graphite::BackendTextures::MakeMetal(
        SkISize::Make(state->width, state->height),
        (__bridge CFTypeRef)state->drawable.texture);
    state->frame_surface = SkSurfaces::WrapBackendTexture(
        state->recorder.get(), backend_tex, kBGRA_8888_SkColorType, nullptr, nullptr);
    if (!state->frame_surface) return nullptr;
    return state->frame_surface->getCanvas();
}

void gpu_end_frame(GpuState* state) {
    if (!state || !state->context) return;
    if (state->recorder) {
        std::unique_ptr<skgpu::graphite::Recording> recording = state->recorder->snap();
        if (recording) {
            skgpu::graphite::InsertRecordingInfo info;
            info.fRecording = recording.get();
            info.fTargetSurface = state->frame_surface.get();
            state->context->insertRecording(info);
        }
        state->recorder.reset();
    }
    state->context->submit();
    if (state->drawable) {
        [state->drawable present];
        state->drawable = nil;
    }
    state->frame_surface = nullptr;
}

sk_sp<SkFontMgr> platform_font_mgr() {
    return SkFontMgr_New_CoreText(nullptr);
}

} // namespace kx
