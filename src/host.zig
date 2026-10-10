// Host — window, event loop (dirty-flag, 0-frame idle), stats (Phase 0.6).
// Converts SDL platform events into ui/input events and routes them into
// the widget tree (Phase 1c). Phase 1e: owns the animation Timeline (ticked
// every loop iteration), repaints clipped to the damage region (dirty-rect,
// the surface is retained between frames), and paces rendering to the
// 8.3 ms frame budget (~120 fps).
// Phase 3f (wasm): the loop body is extracted into runIteration() — one
// pass of drain/tick/render. Native run() keeps its blocking waits
// (SDL_WaitEvent / SDL_WaitEventTimeout); on emscripten run() delegates to
// the rAF main loop in platform_wasm.zig — the browser owns the main
// thread, so nothing in the loop may block (SDL_WaitEvent/SDL_Delay
// busy-poll without Asyncify and freeze the tab).
const std = @import("std");
const builtin = @import("builtin");

// Force-link the a11y bridge C exports (consumed by kx_a11y_macos.mm).
comptime {
    _ = @import("a11y_bridge.zig");
}
const sdl = @import("sdl.zig");
const kx = @import("kx.zig");
const ui = @import("ui.zig");
const input_mod = @import("ui/input.zig");
const semantics_mod = @import("ui/semantics.zig");
const anim = @import("ui/anim.zig");
const devtools_mod = @import("devtools.zig");
const inspector_mod = @import("inspector.zig");

const Node = ui.node.Node;

/// Emscripten target (wasm32-emscripten). The rAF main loop paces the frame
/// loop (platform_wasm.zig); every blocking wait and the SDL_Delay pacing
/// are compiled out under this flag.
pub const is_emscripten = builtin.os.tag == .emscripten;

/// Android target (aarch64-linux-android, Phase 3d) and iOS target
/// (aarch64-ios, Phase 3e). is_mobile gates every mobile branch: the GL
/// context created before kx_create, the pixel-size/DPR handling, the
/// lifecycle events, and the SDL_Log-based log() below.
pub const is_android = builtin.os.tag == .linux and builtin.abi == .android;
pub const is_ios = builtin.os.tag == .ios;
pub const is_mobile = is_android or is_ios;

const platform_wasm = if (is_emscripten) @import("platform_wasm.zig") else struct {};

/// Logging (Phase 3d/3e). std.debug.print and @panic route through
/// std.Options.debug_io → std.Io.Threaded, whose Darwin spawn path reads
/// NullFile.fd — a field that does not exist on iOS (Zig 0.17 std bug), so
/// any reachable std.debug.print / @panic fails the iOS compile. On mobile,
/// log through SDL_Log (stderr / OSLog, no std.Io); on native keep
/// std.debug.print. The untaken branch is comptime-pruned, so std.debug is
/// never analyzed for mobile targets.
fn log(comptime fmt: []const u8, args: anytype) void {
    if (is_mobile) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
        sdl.c.SDL_Log("%s", msg.ptr);
    } else {
        std.debug.print(fmt ++ "\n", args);
    }
}

/// Mobile: the layout-to-canvas factor (pixels per layout unit), derived
/// from the real window sizes. SDL_GetWindowDisplayScale is the display
/// density on Android, not this factor (on iOS the two coincide: the Retina
/// DPR, because the window carries SDL_WINDOW_HIGH_PIXEL_DENSITY).
fn displayScaleOf(window: *sdl.c.SDL_Window, layout_w: c_int, pixel_w: c_int) f32 {
    if (layout_w > 0 and pixel_w > 0)
        return @as(f32, @floatFromInt(pixel_w)) / @as(f32, @floatFromInt(layout_w));
    return sdl.c.SDL_GetWindowDisplayScale(window);
}

/// Frame budget: 8.33 ms → 120 fps target (the metrics gate). The whole loop
/// iteration is paced to the budget (slow iterations run unthrottled and flag
/// the timeline's frame_overrun — low-priority animations pause).
const FRAME_BUDGET_NS: u64 = 8_333_333;
const FRAME_BUDGET_MS: f32 = 8.333;
const FRAME_BUDGET_WAIT_MS: u32 = 8; // integer wait granularity for the budget

pub const Stats = struct {
    frames: u64 = 0,
    frame_time_ms: f32 = 0, // begin_frame → present (total frame)
    paint_time_ms: f32 = 0, // begin_frame → end_frame (drives frame_overrun)
    backend: [*:0]const u8 = "unknown",
};

pub const OnFrame = *const fn (ctx: ?*anyopaque, frame: u64) void;

fn sdlSystemCursor(c: input_mod.PointerCursor) sdl.c.SDL_SystemCursor {
    const id: c_int = switch (c) {
        .default => sdl.c.SDL_SYSTEM_CURSOR_DEFAULT,
        .hand => sdl.c.SDL_SYSTEM_CURSOR_POINTER,
        .ibeam => sdl.c.SDL_SYSTEM_CURSOR_TEXT,
        .move => sdl.c.SDL_SYSTEM_CURSOR_MOVE,
        .wait => sdl.c.SDL_SYSTEM_CURSOR_WAIT,
    };
    return @intCast(id);
}

pub const Host = struct {
    allocator: std.mem.Allocator,
    window: *sdl.c.SDL_Window,
    ctx: *kx.Ctx,
    renderer: ?*sdl.c.SDL_Renderer,
    texture: ?*sdl.c.SDL_Texture,
    pixels: []u8,
    width: c_int,
    height: c_int,
    ppm_path: ?[:0]const u8,
    stats: Stats,
    /// DevTools overlay (Phase 4a): disabled by default — F12 (handleEvent)
    /// or --devtools (main) enables it. Zero cost when off.
    devtools: devtools_mod.DevTools = .{},
    /// Inspector panel (Phase 4a.2): disabled by default — F11 (handleEvent)
    /// or --inspector (main) enables it. Zero cost when off.
    inspector: inspector_mod.Inspector,
    input: input_mod.InputRouter,
    timeline: anim.Timeline,
    frame_start_ns: u64 = 0,
    /// Pointer cursors (Phase 2d-0.5, desktop): the app sets this from the
    /// theme's platform tokens (theme.platform.cursors).
    cursors: bool = false,
    cursors_unavailable: bool = false, // headless / no driver: fail-soft
    current_cursor: input_mod.PointerCursor = .default,
    cursor_cache: [5]?*sdl.c.SDL_Cursor = .{ null, null, null, null, null },
    /// Emscripten (wasm): the WebGL2 context created before kx.create — the
    /// GPU shim (kx_skia_wasm.cpp) requires a current GL context at init.
    /// Null on native. SDL_GLContext is already an optional pointer in the
    /// Zig translation.
    gl_ctx: sdl.c.SDL_GLContext = null,
    /// Mobile (Phase 3d/3e): lifecycle gate — false while the app is
    /// backgrounded (WILL/DID_ENTER_BACKGROUND); runIteration skips
    /// rendering while inactive.
    active: bool = true,
    /// Mobile: window size in pixels (SDL_GetWindowSizeInPixels). The kx
    /// canvas is pixel-sized; width/height stay in points (dp) — the
    /// layout space.
    pixel_width: c_int = 0,
    pixel_height: c_int = 0,
    /// Mobile: pixels per layout unit (Retina DPR on iOS, 1.0 on Android
    /// where the window size is already in pixels). renderFrame scales the
    /// point-space paint onto the pixel canvas by this factor.
    display_scale: f32 = 1.0,

    pub fn init(
        allocator: std.mem.Allocator,
        width: c_int,
        height: c_int,
        backend: kx.c.kx_backend,
        ppm_path: ?[:0]const u8,
    ) !Host {
        if (!sdl.c.SDL_Init(sdl.c.SDL_INIT_VIDEO)) {
            log("SDL_Init failed: {s}", .{sdl.c.SDL_GetError()});
            return error.SdlInit;
        }
        errdefer sdl.c.SDL_Quit();

        // Emscripten (wasm) + mobile (Android/iOS): request a GLES (ES 3.0)
        // context before window creation — the GPU shims (kx_skia_wasm.cpp,
        // kx_skia_android.cpp) need a current GL context when kx.create
        // runs. Double-buffered, no depth buffer, 8-bit stencil.
        if (is_emscripten or is_mobile) {
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_MAJOR_VERSION), 3);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_MINOR_VERSION), 0);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_CONTEXT_PROFILE_MASK), sdl.c.SDL_GL_CONTEXT_PROFILE_ES);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_DOUBLEBUFFER), 1);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_DEPTH_SIZE), 0);
            _ = sdl.c.SDL_GL_SetAttribute(@intCast(sdl.c.SDL_GL_STENCIL_SIZE), 8);
        }
        const window_flags: u64 = if (is_emscripten)
            sdl.c.SDL_WINDOW_OPENGL
        else if (is_android)
            sdl.c.SDL_WINDOW_FULLSCREEN | sdl.c.SDL_WINDOW_OPENGL
        else if (is_ios)
            // HIGH_PIXEL_DENSITY: without it SDL_GetWindowSizeInPixels
            // reports points on iOS — the DPR model needs real pixels.
            sdl.c.SDL_WINDOW_OPENGL | sdl.c.SDL_WINDOW_HIGH_PIXEL_DENSITY
        else
            0;
        const window = sdl.c.SDL_CreateWindow("klaxon hello", width, height, window_flags) orelse {
            log("SDL_CreateWindow failed: {s}", .{sdl.c.SDL_GetError()});
            return error.SdlWindow;
        };
        errdefer sdl.c.SDL_DestroyWindow(window);

        // Emscripten (wasm) + mobile: create the GL context and make it
        // current BEFORE kx.create — gpu_init checks SDL_GL_GetCurrentContext.
        var gl_ctx: sdl.c.SDL_GLContext = null;
        if (is_emscripten or is_mobile) {
            gl_ctx = sdl.c.SDL_GL_CreateContext(window);
            if (gl_ctx == null) {
                log("SDL_GL_CreateContext failed: {s}", .{sdl.c.SDL_GetError()});
                return error.SdlGlContext;
            }
            _ = sdl.c.SDL_GL_MakeCurrent(window, gl_ctx);
            _ = sdl.c.SDL_GL_SetSwapInterval(0); // the platform paces the loop (rAF / CADisplayLink / vsync)
        }
        errdefer {
            if (gl_ctx) |ctx| _ = sdl.c.SDL_GL_DestroyContext(ctx);
        }

        // Text input events flow from window creation (TextField focus is
        // managed by the input router; refine per-platform later). Mobile:
        // the soft keyboard is driven by the platform text-input path —
        // SDL_StartTextInput is a no-op there.
        if (!is_mobile) _ = sdl.c.SDL_StartTextInput(window);

        // Mobile: the real window size comes from SDL after creation (the
        // caller may pass 0x0 — iOS ignores the requested size and goes
        // fullscreen): points → width/height (the layout space), pixels →
        // pixel_width/pixel_height (the kx canvas is pixel-sized).
        var win_w = width;
        var win_h = height;
        var pixel_w: c_int = width;
        var pixel_h: c_int = height;
        var display_scale: f32 = 1.0;
        if (is_mobile) {
            _ = sdl.c.SDL_GetWindowSize(window, &win_w, &win_h);
            _ = sdl.c.SDL_GetWindowSizeInPixels(window, &pixel_w, &pixel_h);
            display_scale = displayScaleOf(window, win_w, pixel_w);
        }

        const ctx = kx.create(@ptrCast(window), pixel_w, pixel_h, backend) orelse {
            log("kx_create failed (backend {s})", .{kx.c.kx_backend_name(backend)});
            return error.KxCreate;
        };
        errdefer kx.c.kx_destroy(ctx);

        // Raster presents through an SDL streaming texture; GPU backends present
        // inside the shim (onscreen surface attached to the window). Mobile:
        // no SDL renderer/texture — the GPU shim presents (Metal / EGL swap).
        const renderer = if (!is_mobile and backend == kx.c.KX_BACKEND_RASTER)
            sdl.c.SDL_CreateRenderer(window, null) orelse return error.SdlRenderer
        else
            null;
        errdefer {
            if (renderer) |r| sdl.c.SDL_DestroyRenderer(r);
        }

        const texture = if (is_mobile)
            null
        else if (renderer) |r|
            sdl.c.SDL_CreateTexture(r, sdl.c.SDL_PIXELFORMAT_ABGR8888, sdl.c.SDL_TEXTUREACCESS_STREAMING, width, height) orelse return error.SdlTexture
        else
            null;
        errdefer {
            if (texture) |t| sdl.c.SDL_DestroyTexture(t);
        }

        // Mobile: no CPU pixel buffer (the GPU shim owns presentation).
        const pixels: []u8 = if (is_mobile)
            &[_]u8{}
        else
            try allocator.alloc(u8, @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4);
        errdefer allocator.free(pixels);

        const backend_name: [*:0]const u8 = kx.c.kx_backend_name(backend) orelse "unknown";

        const inspector = try inspector_mod.Inspector.init(allocator);
        errdefer inspector.deinit();

        return .{
            .allocator = allocator,
            .window = window,
            .ctx = ctx,
            .gl_ctx = gl_ctx,
            .renderer = renderer,
            .texture = texture,
            .pixels = pixels,
            .width = win_w,
            .height = win_h,
            .pixel_width = pixel_w,
            .pixel_height = pixel_h,
            .display_scale = display_scale,
            .ppm_path = ppm_path,
            .stats = .{ .backend = backend_name },
            .inspector = inspector,
            .input = .{},
            .timeline = anim.Timeline.init(allocator),
        };
    }

    /// Pointer cursors (Phase 2d-0.5, desktop): map the hovered node to a
    /// system cursor. Fail-soft: without a video driver the creation returns
    /// null and cursors are simply never set.
    fn updateCursor(host: *Host) void {
        if (host.cursors_unavailable) return;
        if (!host.cursors) {
            // disabled (mobile preset): restore the default arrow once
            if (host.current_cursor != .default) {
                const cur = host.cursorFor(.default) orelse return;
                if (!sdl.c.SDL_SetCursor(cur)) return;
                host.current_cursor = .default;
            }
            return;
        }
        const want = input_mod.cursorForNode(host.input.hoveredNode());
        if (want == host.current_cursor) return;
        const cur = host.cursorFor(want) orelse return;
        if (!sdl.c.SDL_SetCursor(cur)) return;
        host.current_cursor = want;
    }

    /// The SDL cursor for a shape (created lazily, cached).
    fn cursorFor(host: *Host, c: input_mod.PointerCursor) ?*sdl.c.SDL_Cursor {
        const idx: usize = @backingInt(c);
        if (host.cursor_cache[idx]) |cur| return cur;
        const created = sdl.c.SDL_CreateSystemCursor(sdlSystemCursor(c)) orelse {
            host.cursors_unavailable = true; // headless: no cursors
            return null;
        };
        host.cursor_cache[idx] = created;
        return created;
    }

    pub fn deinit(host: *Host) void {
        host.inspector.deinit();
        host.timeline.deinit();
        for (host.cursor_cache) |c| {
            if (c) |cur| sdl.c.SDL_DestroyCursor(cur);
        }
        if (host.texture) |t| sdl.c.SDL_DestroyTexture(t);
        if (host.renderer) |r| sdl.c.SDL_DestroyRenderer(r);
        kx.c.kx_destroy(host.ctx);
        if (host.gl_ctx) |ctx| _ = sdl.c.SDL_GL_DestroyContext(ctx);
        sdl.c.SDL_DestroyWindow(host.window);
        sdl.c.SDL_Quit();
        host.allocator.free(host.pixels);
    }

    /// Frame loop (native). Renders only when the tree is dirty; at idle it
    /// blocks on SDL_WaitEvent — 0 frames, 0 wakeups. `on_frame` is the app
    /// tick (it may mark nodes dirty). The animation timeline is ticked every
    /// iteration: active animations update signals → nodes mark dirty → the
    /// frame renders below (time-based values — the tick rate is the loop
    /// rate, ~120 Hz while animating).
    ///
    /// On emscripten this delegates to platform_wasm.runWasm: the browser
    /// owns the main thread and paces the loop with rAF (never blocks).
    pub fn run(host: *Host, root: *Node, max_frames: u64, on_frame: ?OnFrame, on_frame_ctx: ?*anyopaque) !void {
        if (is_emscripten) {
            platform_wasm.runWasm(host, root, max_frames, on_frame, on_frame_ctx);
            return;
        }
        // macOS: initialize the NSAccessibility bridge.
        if (builtin.os.tag == .macos) {
            kx.a11yInit(@ptrCast(root));
            defer kx.a11yShutdown();
        }
        var quit = false;
        while (!quit and host.stats.frames < max_frames) {
            quit = try host.runIteration(root, on_frame, on_frame_ctx);
        }
    }

    /// One pass of the frame loop (Phase 3f extraction): tick the animation
    /// timeline, drain pending events, run the app tick, render when the tree
    /// is dirty, pace the iteration. Returns true when the app requested quit.
    ///
    /// Native: the event wait blocks per the loop's state — dirty (drain,
    /// non-blocking), app ticking (wait out the rest of the frame budget),
    /// timed work pending (wake at the timeline's granularity, ~240 Hz),
    /// true idle (block on SDL_WaitEvent: 0 wakeups). The iteration is paced
    /// to the frame budget (~120 fps active).
    ///
    /// Emscripten: NEVER blocks. SDL_WaitEvent / SDL_WaitEventTimeout /
    /// SDL_Delay busy-poll without Asyncify and freeze the tab; the rAF main
    /// loop (platform_wasm.zig) paces the iteration, so only a non-blocking
    /// SDL_PollEvent drain runs and the pacing delay is compiled out.
    pub fn runIteration(host: *Host, root: *Node, on_frame: ?OnFrame, on_frame_ctx: ?*anyopaque) !bool {
        const iter_start_ns = sdl.c.SDL_GetTicksNS();
        // Animations (1e): advance the timeline — active animations update
        // signals → nodes mark dirty → the frame renders below. The clock
        // never runs past a queued event: a release stamped before a
        // long-press deadline is processed before the deadline fires.
        const now = sdl.c.SDL_GetTicks();
        var peek: sdl.c.SDL_Event = undefined;
        const tick_time: u64 = if (sdl.c.SDL_PeepEvents(&peek, 1, @intCast(sdl.c.SDL_PEEKEVENT), @intCast(sdl.c.SDL_EVENT_FIRST), @intCast(sdl.c.SDL_EVENT_LAST)) > 0)
            @min(now, peek.common.timestamp / 1_000_000)
        else
            now;
        host.timeline.tick(tick_time);
        var event: sdl.c.SDL_Event = undefined;
        var quit = false;
        if (is_emscripten) {
            // Wasm: non-blocking drain only — SDL's emscripten backend fills
            // the queue from its JS event handlers; the rAF callback paces
            // the loop. Blocking here would freeze the tab.
            while (sdl.c.SDL_PollEvent(&event)) {
                if (host.handleEvent(root, &event)) quit = true;
            }
        } else if (is_ios) {
            // iOS: no drain here — SDL_AppEvent (platform_ios.zig) dispatches
            // every event as SDL pumps them (SDL_main_callbacks also routes
            // the watch-only lifecycle events to the app callback).
            _ = &event; // no event drain on iOS — keep the slot referenced
        } else if (is_android) {
            // Android: non-blocking drain — SDL_main runs this loop on SDL's
            // main thread; the platform paces the iteration (no blocking
            // waits on mobile).
            while (sdl.c.SDL_PollEvent(&event)) {
                if (host.handleEvent(root, &event)) quit = true;
            }
        } else if (root.dirty) {
            // Active: drain events without blocking.
            while (sdl.c.SDL_PollEvent(&event)) {
                if (host.handleEvent(root, &event)) quit = true;
            }
        } else if (on_frame != null) {
            // Clean but the app ticks: wait out the rest of the frame
            // budget (the app may mark nodes dirty → rendered below).
            const elapsed_ms = (sdl.c.SDL_GetTicksNS() - iter_start_ns) / 1_000_000;
            if (elapsed_ms < FRAME_BUDGET_WAIT_MS) {
                const wait_ms = FRAME_BUDGET_WAIT_MS - @as(u32, @intCast(elapsed_ms));
                if (sdl.c.SDL_WaitEventTimeout(&event, @intCast(wait_ms))) {
                    if (host.handleEvent(root, &event)) quit = true;
                    while (sdl.c.SDL_PollEvent(&event)) {
                        if (host.handleEvent(root, &event)) quit = true;
                    }
                }
            }
        } else if (host.timeline.hasTimedWork()) {
            // Timed work pending (running animation / held pointer waiting
            // for a long-press deadline): wake at the timeline's
            // granularity (~240 Hz) instead of blocking indefinitely.
            if (sdl.c.SDL_WaitEventTimeout(&event, 4)) {
                if (host.handleEvent(root, &event)) quit = true;
                while (sdl.c.SDL_PollEvent(&event)) {
                    if (host.handleEvent(root, &event)) quit = true;
                }
            }
        } else {
            // True idle: block until an event arrives (0 wakeups).
            if (sdl.c.SDL_WaitEvent(&event)) {
                if (host.handleEvent(root, &event)) quit = true;
                while (sdl.c.SDL_PollEvent(&event)) {
                    if (host.handleEvent(root, &event)) quit = true;
                }
            }
        }
        // App tick every iteration (may mark nodes dirty). An app tick
        // means the app drives a continuous animation: render EVERY
        // iteration — a tick that changes nothing (e.g. an animation
        // value quantized to the same integer) must not stall the loop
        // (frames < max_frames with frames frozen = infinite loop).
        if (on_frame) |f| f(on_frame_ctx, host.stats.frames);
        // Render when the tree is dirty (or the app ticks: continuous) and
        // the app is active (mobile: skip while backgrounded).
        if (!quit and host.active and (root.dirty or on_frame != null)) host.renderFrame(root);
        // Pointer cursor follows the hovered node (desktop, Phase 2d-0.5).
        host.updateCursor();
        // Pace the whole iteration to the frame budget (~120 fps active).
        host.paceIteration(iter_start_ns);
        return quit;
    }

    fn renderFrame(host: *Host, root: *Node) void {
        // Layout pass (Phase 1e): re-layout when sizes/structure changed.
        // Layout moves content, so the frame repaints fully.
        if (root.layout_dirty) {
            root.layout(root.bounds);
            root.dirty = true;
            root.clearDamage();
            semantics_mod.notifyTreeDirty(); // the semantic tree may have changed
            // content moved under a stationary pointer: refresh hover (cursors)
            host.input.refreshHover(root);
        }
        host.frame_start_ns = sdl.c.SDL_GetTicksNS();
        kx.c.kx_begin_frame(host.ctx);
        // Mobile (Phase 3d/3e): the canvas is pixel-sized (kx_create got
        // pixel_width/pixel_height) while the tree lays out in points —
        // scale the point-space paint onto the pixel canvas (crisp on
        // Retina; a no-op at display_scale == 1.0, e.g. Android).
        if (is_mobile) {
            kx.c.kx_save(host.ctx);
            kx.c.kx_scale(host.ctx, host.display_scale, host.display_scale);
        }
        // Dirty-rect is raster-only: the raster surface is retained between
        // frames; GPU backends acquire a fresh drawable each frame (no
        // retained pixels) → full repaint until retained composition lands.
        const raster = kx.c.kx_backend_of(host.ctx) == kx.c.KX_BACKEND_RASTER;
        const focus = semantics_mod.currentFocus();
        // The DevTools overlay paints translucent pixels over the whole panel
        // area; a dirty-rect partial repaint would blend the new overlay over
        // retained old overlay pixels (ghosting). Force a full repaint when
        // the overlay (or the inspector panel) is enabled so the panel area
        // is cleared first.
        if (raster and root.damage_valid and !host.devtools.enabled and !host.inspector.enabled) {
            // Repaint the tree clipped to the damaged region — and clear the
            // clip first (SkCanvas::clear is clip-aware): vacated pixels
            // (moving widgets) are erased, not trailed. The focus ring paints
            // INSIDE the clip (a focus change damages its ring regions), so
            // unrelated repaints never redraw it.
            const d = root.damage;
            kx.c.kx_clip_rect(host.ctx, d.x, d.y, d.w, d.h);
            kx.c.kx_clear(host.ctx, 0);
            root.paint(host.ctx);
            host.paintPopupOverlay(); // above the tree (a popup overflows its anchor), below the ring
            if (focus) |fm| fm.paintRing(host.ctx);
            kx.c.kx_clip_reset(host.ctx);
        } else {
            root.paint(host.ctx);
            host.paintPopupOverlay();
            if (focus) |fm| fm.paintRing(host.ctx); // full repaint: ring included
        }
        // Inspector (Phase 4a.2): the bounds highlight paints after the focus
        // ring (over the tree, under the panel), the panel paints after that —
        // above everything, always unclipped (like the DevTools overlay).
        if (host.inspector.enabled) {
            // Rebuild FIRST: a selected node destroyed since the last frame
            // (e.g. a virtualized list scrolled) must be dropped before the
            // highlight paint dereferences it (use-after-free). paint()
            // rebuilds again — idempotent, same tree.
            host.inspector.rebuildRows(root);
            host.inspector.paintHighlight(host.ctx);
            host.inspector.paint(host.ctx, root, host.width, host.height);
        }
        // DevTools overlay (Phase 4a): painted after the tree and the focus
        // ring, outside the damage clip — above everything, always unclipped.
        // The stats still hold the PREVIOUS frame's times here (they update
        // after present, below): recordFrame + paint show last frame's numbers.
        if (host.devtools.enabled) {
            host.devtools.recordFrame(host.stats.frame_time_ms);
            host.devtools.paint(host.ctx, host.width, host.height, &host.stats);
        }
        if (is_mobile) kx.c.kx_restore(host.ctx);
        kx.c.kx_end_frame(host.ctx);
        const t_paint = sdl.c.SDL_GetTicksNS();
        root.clearDamage();
        host.present();
        const t1 = sdl.c.SDL_GetTicksNS();
        host.stats.frames += 1;
        host.stats.frame_time_ms = @as(f32, @floatFromInt(t1 - host.frame_start_ns)) / 1e6;
        host.stats.paint_time_ms = @as(f32, @floatFromInt(t_paint - host.frame_start_ns)) / 1e6;
        // Frame budget signal (1e.7): low-priority animations pause on overrun.
        host.timeline.frame_overrun = host.stats.paint_time_ms > FRAME_BUDGET_MS;
        if (host.ppm_path != null and host.stats.frames == 30) host.dumpPpm();
    }

    /// Paint the open popup's overlay pass: popup content overflows its
    /// anchor (a menu panel over later siblings), so it paints after the
    /// whole tree — above everything except the focus ring. Inside the
    /// damage clip: the popup's dirty marks already cover its overflow.
    fn paintPopupOverlay(host: *Host) void {
        if (host.input.open_popup) |popup| {
            if (popup.vtable.paint_overlay) |po| po(popup, host.ctx);
        }
    }

    /// Pace one loop iteration to the frame budget: delay only the remainder
    /// of the 8.3 ms budget (slow iterations run unthrottled). Compiled out
    /// on emscripten — the rAF main loop paces the iteration; SDL_Delay
    /// would busy-poll and freeze the tab. Also compiled out on mobile —
    /// the platform paces the iteration (CADisplayLink on iOS,
    /// eglSwapBuffers/vsync on Android).
    fn paceIteration(host: *Host, iter_start_ns: u64) void {
        if (is_emscripten or is_mobile) return;
        _ = host;
        const elapsed = sdl.c.SDL_GetTicksNS() - iter_start_ns;
        if (elapsed < FRAME_BUDGET_NS) {
            const remaining_ms: u32 = @intCast((FRAME_BUDGET_NS - elapsed) / 1_000_000);
            if (remaining_ms > 0) sdl.c.SDL_Delay(remaining_ms);
        }
    }

    /// Returns true if the event requests quit. Pub: platform_ios.zig calls
    /// it from SDL_AppEvent (iOS dispatches events through the SDL main
    /// callbacks, not through this loop's drain).
    pub fn handleEvent(host: *Host, root: *Node, event: *sdl.c.SDL_Event) bool {
        if (event.type == sdl.c.SDL_EVENT_QUIT) return true;
        // Mobile lifecycle (Phase 3d/3e): background/foreground gating plus
        // the low-memory / terminating notifications. On iOS these arrive
        // through SDL_AppEvent (SDL_main_callbacks dispatches the watch-only
        // app events immediately); on Android they are never queued, so the
        // branch is a no-op there.
        if (is_mobile) {
            switch (event.type) {
                sdl.c.SDL_EVENT_WILL_ENTER_BACKGROUND, sdl.c.SDL_EVENT_DID_ENTER_BACKGROUND => {
                    host.active = false;
                    return false;
                },
                sdl.c.SDL_EVENT_WILL_ENTER_FOREGROUND, sdl.c.SDL_EVENT_DID_ENTER_FOREGROUND => {
                    // The surface may have been lost while backgrounded:
                    // full repaint on resume (no dirty-rect).
                    host.active = true;
                    root.dirty = true;
                    root.clearDamage();
                    return false;
                },
                sdl.c.SDL_EVENT_LOW_MEMORY => {
                    log("klaxon: low memory warning", .{});
                    return false;
                },
                sdl.c.SDL_EVENT_TERMINATING => return true,
                else => {},
            }
        }
        // DevTools (Phase 4a): F12 toggles the overlay — checked before any
        // other key handling so it works regardless of the focused node.
        // Key-repeat events are ignored (holding F12 would toggle per repeat).
        if (event.type == sdl.c.SDL_EVENT_KEY_DOWN and event.key.key == sdl.c.SDLK_F12 and !event.key.repeat) {
            host.devtools.toggle();
            root.dirty = true; // force a repaint to show/hide the overlay
            return false;
        }
        // Inspector (Phase 4a.2): F11 toggles the panel — independent of F12.
        if (event.type == sdl.c.SDL_EVENT_KEY_DOWN and event.key.key == sdl.c.SDLK_F11 and !event.key.repeat) {
            host.inspector.toggle();
            root.dirty = true; // force a repaint to show/hide the panel
            // Invalidate the damage too: closing the panel re-enables the
            // dirty-rect path, and a widget-sized clip would leave the old
            // panel/highlight pixels outside it on the retained surface.
            root.clearDamage();
            return false;
        }
        if (event.type == sdl.c.SDL_EVENT_WINDOW_RESIZED) {
            const w: c_int = @intCast(event.window.data1);
            const h: c_int = @intCast(event.window.data2);
            if (w > 0 and h > 0) {
                host.resize(w, h);
                // The surface is recreated (garbage pixels) and the tree is
                // laid out at the new size: full repaint, no dirty-rect.
                root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) });
                root.dirty = true;
                root.clearDamage();
            }
        }
        // Input routing (Phase 1c/1d): platform events → router → widget tree.
        // Every pointer event carries its pointer id (mouse = which, touch =
        // finger id) and a timestamp (gesture timing). The event's own
        // timestamp (ns since SDL_Init, same epoch as SDL_GetTicks) is used —
        // not the handling time — so queued events keep their real clock.
        const time_ms: u64 = event.common.timestamp / 1_000_000;
        switch (event.type) {
            // The mouse is the primary pointer: normalized to ID 0 (hover
            // tracks pointer 0 only). Touches keep their own IDs (multi-touch).
            sdl.c.SDL_EVENT_MOUSE_MOTION => {
                // Inspector (Phase 4a.2): motion over the panel clears hover
                // and skips widget routing (the pointer is over the panel) —
                // unless a widget holds the pointer capture (an active drag):
                // the captured node keeps receiving moves even outside its
                // bounds, and dropping them would leave a stale drag whose
                // release lands later as an accidental click.
                const has_capture = host.input.capturedNode(0) != null;
                if (host.inspector.enabled and !has_capture and host.inspector.hitZone(event.motion.x, event.motion.y, host.width, host.height) != .none) {
                    host.input.clearHover();
                    return false; // skip routing
                }
                // Mobile: mouse coordinates arrive in pixels — convert to
                // the point (dp) layout space via the display scale.
                const sx = if (is_mobile) event.motion.x / host.display_scale else event.motion.x;
                const sy = if (is_mobile) event.motion.y / host.display_scale else event.motion.y;
                host.input.dispatchPointer(root, .{
                    .phase = .move,
                    .x = sx,
                    .y = sy,
                    .pointer = 0,
                    .time_ms = time_ms,
                });
            },
            sdl.c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                // Inspector (Phase 4a.2): a click in the panel is consumed
                // (tree: select/expand, props: no-op); a click on the canvas
                // passively selects the hit node (routing continues normally).
                if (host.inspector.enabled) {
                    const z = host.inspector.hitZone(event.button.x, event.button.y, host.width, host.height);
                    if (z != .none) {
                        host.inspector.clickAt(root, event.button.x, event.button.y, host.width, host.height);
                        root.dirty = true;
                        return false; // consume the panel click
                    }
                    host.inspector.pickAt(root, event.button.x, event.button.y); // passive selection
                }
                if (event.button.button == sdl.c.SDL_BUTTON_LEFT) {
                    // Mobile: pixels → points (layout space), like motion.
                    const sx = if (is_mobile) event.button.x / host.display_scale else event.button.x;
                    const sy = if (is_mobile) event.button.y / host.display_scale else event.button.y;
                    host.input.dispatchPointer(root, .{
                        .phase = .down,
                        .x = sx,
                        .y = sy,
                        .pointer = 0,
                        .time_ms = time_ms,
                    });
                }
            },
            sdl.c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == sdl.c.SDL_BUTTON_LEFT) {
                    const sx = if (is_mobile) event.button.x / host.display_scale else event.button.x;
                    const sy = if (is_mobile) event.button.y / host.display_scale else event.button.y;
                    host.input.dispatchPointer(root, .{
                        .phase = .up,
                        .x = sx,
                        .y = sy,
                        .pointer = 0,
                        .time_ms = time_ms,
                    });
                }
            },
            // Touch: normalized finger coords → window pixels (multi-touch).
            sdl.c.SDL_EVENT_FINGER_DOWN => host.input.dispatchPointer(root, .{
                .phase = .down,
                .x = event.tfinger.x * @as(f32, @floatFromInt(host.width)),
                .y = event.tfinger.y * @as(f32, @floatFromInt(host.height)),
                .pointer = @intCast(event.tfinger.fingerID),
                .time_ms = time_ms,
            }),
            sdl.c.SDL_EVENT_FINGER_MOTION => host.input.dispatchPointer(root, .{
                .phase = .move,
                .x = event.tfinger.x * @as(f32, @floatFromInt(host.width)),
                .y = event.tfinger.y * @as(f32, @floatFromInt(host.height)),
                .pointer = @intCast(event.tfinger.fingerID),
                .time_ms = time_ms,
            }),
            sdl.c.SDL_EVENT_FINGER_UP => host.input.dispatchPointer(root, .{
                .phase = .up,
                .x = event.tfinger.x * @as(f32, @floatFromInt(host.width)),
                .y = event.tfinger.y * @as(f32, @floatFromInt(host.height)),
                .pointer = @intCast(event.tfinger.fingerID),
                .time_ms = time_ms,
            }),
            // Wheel → scroll event (Phase 1f): routed like pointer input.
            // The content may scroll under a stationary pointer: refresh hover.
            sdl.c.SDL_EVENT_MOUSE_WHEEL => {
                // Inspector (Phase 4a.2): wheel over the panel scrolls the
                // tree view (consumed — no widget scroll).
                if (host.inspector.enabled and host.inspector.hitZone(event.wheel.mouse_x, event.wheel.mouse_y, host.width, host.height) != .none) {
                    // SDL3: wheel.y > 0 = scroll up (toward the start),
                    // wheel.y < 0 = scroll down. scrollBy's positive dy grows
                    // scroll_y (content moves down) → negate the event value.
                    host.inspector.scrollBy(-event.wheel.y, host.width, host.height);
                    root.dirty = true;
                    return false; // consume
                }
                // Mobile: pixels → points (layout space), like motion.
                const sx = if (is_mobile) event.wheel.mouse_x / host.display_scale else event.wheel.mouse_x;
                const sy = if (is_mobile) event.wheel.mouse_y / host.display_scale else event.wheel.mouse_y;
                host.input.dispatchScroll(root, .{
                    .x = sx,
                    .y = sy,
                    .delta_x = event.wheel.x,
                    .delta_y = event.wheel.y,
                    .pointer = 0,
                    .time_ms = time_ms,
                });
                host.input.refreshHover(root);
            },
            sdl.c.SDL_EVENT_TEXT_INPUT => {
                _ = host.input.dispatchKey(.{
                    .kind = .text_input,
                    .text = std.mem.span(event.text.text),
                });
            },
            sdl.c.SDL_EVENT_KEY_DOWN => {
                // Inspector (Phase 4a.2): when the tree panel has keyboard
                // focus, arrows/Enter/Escape navigate it — consumed before
                // any widget routing.
                if (host.inspector.enabled and host.inspector.tree_focus and !event.key.repeat) {
                    if (host.inspector.handleKey(event.key.key)) {
                        root.dirty = true;
                        return false; // consumed, no widget routing
                    }
                }
                // Back (Android hardware button / desktop Escape): the
                // focused chain gets the key first, then the navigator pops
                // (Phase 2a back handler).
                if (event.key.key == sdl.c.SDLK_ESCAPE or event.key.key == sdl.c.SDLK_AC_BACK) {
                    _ = host.input.dispatchBack();
                } else {
                    const ev = input_mod.KeyEvent{
                        .kind = .key_down,
                        .key = sdlKeyToKey(event.key.key),
                        .shift = (event.key.mod & (sdl.c.SDL_KMOD_LSHIFT | sdl.c.SDL_KMOD_RSHIFT)) != 0,
                    };
                    // Tab moves the keyboard focus (Phase 2c) — never reaches the tree.
                    if (ev.key == .tab) {
                        if (semantics_mod.currentFocus()) |fm| _ = fm.handleKey(ev);
                    } else if (!host.input.dispatchKey(ev)) {
                        // Unhandled by the focused node: Enter/Space activate it.
                        if (semantics_mod.currentFocus()) |fm| _ = fm.handleKey(ev);
                    }
                }
            },
            else => {},
        }
        return false;
    }

    fn sdlKeyToKey(k: u32) input_mod.Key {
        return switch (k) {
            sdl.c.SDLK_BACKSPACE => .backspace,
            sdl.c.SDLK_DELETE => .delete,
            sdl.c.SDLK_RETURN, sdl.c.SDLK_KP_ENTER => .enter,
            sdl.c.SDLK_ESCAPE => .escape,
            sdl.c.SDLK_LEFT => .left,
            sdl.c.SDLK_RIGHT => .right,
            sdl.c.SDLK_UP => .up,
            sdl.c.SDLK_DOWN => .down,
            sdl.c.SDLK_TAB => .tab,
            sdl.c.SDLK_SPACE => .space,
            else => .unknown,
        };
    }

    fn resize(host: *Host, w: c_int, h: c_int) void {
        host.width = w;
        host.height = h;
        if (is_mobile) {
            // Mobile: the canvas is pixel-sized — re-query the pixel size
            // and DPR (WINDOW_RESIZED carries points). No SDL
            // renderer/texture/pixel buffer on mobile.
            host.refreshPixelSize();
            kx.c.kx_resize(host.ctx, host.pixel_width, host.pixel_height);
            return;
        }
        kx.c.kx_resize(host.ctx, w, h);
        host.allocator.free(host.pixels);
        // Fail-soft on OOM (an @panic here would pull std.debug into the
        // mobile compile — see log()): the next present skips the readback
        // (kx_readback_rgba rejects a short buffer).
        host.pixels = host.allocator.alloc(u8, @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4) catch blk: {
            log("klaxon: out of memory", .{});
            break :blk &[_]u8{};
        };
        if (host.texture) |t| {
            sdl.c.SDL_DestroyTexture(t);
            host.texture = sdl.c.SDL_CreateTexture(host.renderer.?, sdl.c.SDL_PIXELFORMAT_ABGR8888, sdl.c.SDL_TEXTUREACCESS_STREAMING, w, h);
        }
    }

    /// Mobile: refresh the pixel size + display scale from the window (call
    /// on resize — the WINDOW_RESIZED event carries points, the canvas
    /// needs pixels).
    fn refreshPixelSize(host: *Host) void {
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = sdl.c.SDL_GetWindowSizeInPixels(host.window, &pw, &ph);
        if (pw > 0 and ph > 0) {
            host.pixel_width = pw;
            host.pixel_height = ph;
        }
        host.display_scale = displayScaleOf(host.window, host.width, host.pixel_width);
    }

    fn present(host: *Host) void {
        if (host.texture) |t| {
            var w: c_int = 0;
            var h: c_int = 0;
            if (kx.c.kx_readback_rgba(host.ctx, host.pixels.ptr, host.pixels.len, &w, &h)) {
                _ = sdl.c.SDL_UpdateTexture(t, null, host.pixels.ptr, host.width * 4);
                if (host.renderer) |r| {
                    _ = sdl.c.SDL_RenderTexture(r, t, null, null);
                    _ = sdl.c.SDL_RenderPresent(r);
                }
            }
        }
        // GPU backends present inside kx_end_frame (onscreen surface).
    }

    fn dumpPpm(host: *Host) void {
        const path = host.ppm_path orelse return;
        var w: c_int = 0;
        var h: c_int = 0;
        if (!kx.c.kx_readback_rgba(host.ctx, host.pixels.ptr, host.pixels.len, &w, &h)) return;
        const f = std.c.fopen(path, "wb") orelse return;
        defer _ = std.c.fclose(f);
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrintSentinel(&header_buf, "P6\n{d} {d}\n255\n", .{ w, h }, 0) catch return;
        _ = std.c.fwrite(header.ptr, 1, header.len, f);
        var i: usize = 0;
        const n = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
        while (i < n) : (i += 4) {
            _ = std.c.fwrite(host.pixels.ptr + i, 1, 3, f); // RGBA → RGB
        }
    }
};
