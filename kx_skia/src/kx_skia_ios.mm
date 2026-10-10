// kx_skia_ios.mm — iOS platform implementation: Graphite (Metal) onscreen
// backend + CoreText font manager. Same backend as macOS; the difference is
// DPR handling: the host passes window sizes in PIXELS (SDL_GetWindowSizeInPixels)
// while the widget layout works in points (dp), so the frame canvas is scaled
// by pixels/points at the start of every frame (crisp on Retina).
#include "kx_skia_platform.h"

#include <SDL3/SDL.h>
#include <SDL3/SDL_metal.h>

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>

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
    int width = 0;      // pixels (host passes SDL_GetWindowSizeInPixels)
    int height = 0;     // pixels
    float scale = 1.0f; // device pixel ratio: pixels per point
};

// Device pixel ratio: stored pixel width over the view's live point bounds.
// Falls back to 1.0 until the view has a valid size.
static float layer_scale(const GpuState* state) {
    const CGSize bounds = state->layer.bounds.size;
    if (bounds.width <= 0.0f || bounds.height <= 0.0f) return 1.0f;
    return static_cast<float>(state->width) / static_cast<float>(bounds.width);
}

// Keep the layer consistent with the host's pixel sizes: drawableSize in
// pixels and contentsScale = pixels/points, so SDL's own layoutSubviews
// (SDL_uikitmetalview -updateDrawableSize) recomputes the same drawable size
// instead of clobbering it back to points.
static void sync_layer(GpuState* state) {
    state->scale = layer_scale(state);
    state->layer.contentsScale = state->scale;
    state->layer.drawableSize = CGSizeMake(state->width, state->height);
}

bool gpu_init(GpuState** out, void* sdl_window, int width, int height) {
    if (!sdl_window || !out) return false;
    auto* state = new GpuState();
    state->width = width;
    state->height = height;

    state->metal_view = SDL_Metal_CreateView(static_cast<SDL_Window*>(sdl_window));
    if (!state->metal_view) { delete state; return false; }
    state->layer = (__bridge CAMetalLayer*)SDL_Metal_GetLayer(state->metal_view);
    if (!state->layer) { SDL_Metal_DestroyView(state->metal_view); delete state; return false; }

    // SDL's UIKit backend — unlike the Cocoa backend — does not attach the
    // metal view to the window; without this the layer would never be
    // onscreen. Insert at the back of the root view so SDL's text input
    // field (added on top by the view controller) keeps working, and let the
    // view track rotations (SDL's iOS metal view sets no autoresizing mask).
    SDL_PropertiesID props = SDL_GetWindowProperties(static_cast<SDL_Window*>(sdl_window));
    UIWindow* uiwindow = (__bridge UIWindow*)SDL_GetPointerProperty(props, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
    UIView* metal_view = (__bridge UIView*)state->metal_view;
    UIView* root = uiwindow ? uiwindow.rootViewController.view : nil;
    if (root && metal_view.superview == nil) {
        metal_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [root insertSubview:metal_view atIndex:0];
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { SDL_Metal_DestroyView(state->metal_view); delete state; return false; }
    state->layer.device = device;
    state->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    state->layer.framebufferOnly = YES;
    sync_layer(state);

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
    sync_layer(state); // drawableSize in pixels, contentsScale = pixels/points
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
    // Layout is in points, the drawable is in pixels: scale the canvas so
    // point-space drawing lands 1:1 on the pixel grid. Recomputed per frame
    // from the live view bounds (tracks rotation / display changes).
    state->scale = layer_scale(state);
    SkCanvas* canvas = state->frame_surface->getCanvas();
    canvas->scale(state->scale, state->scale);
    return canvas;
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
