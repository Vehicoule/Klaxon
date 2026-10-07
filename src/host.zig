// Host — window, event loop (dirty-flag, 0-frame idle), stats (Phase 0.6).
// Converts SDL platform events into ui/input events and routes them into
// the widget tree (Phase 1c). Phase 1e: owns the animation Timeline (ticked
// every loop iteration), repaints clipped to the damage region (dirty-rect,
// the surface is retained between frames), and paces rendering to the
// 8.3 ms frame budget (~120 fps).
const std = @import("std");
const sdl = @import("sdl.zig");
const kx = @import("kx.zig");
const ui = @import("ui.zig");
const input_mod = @import("ui/input.zig");
const anim = @import("ui/anim.zig");

const Node = ui.node.Node;

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
    input: input_mod.InputRouter,
    timeline: anim.Timeline,
    frame_start_ns: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        width: c_int,
        height: c_int,
        backend: kx.c.kx_backend,
        ppm_path: ?[:0]const u8,
    ) !Host {
        if (!sdl.c.SDL_Init(sdl.c.SDL_INIT_VIDEO)) {
            std.debug.print("SDL_Init failed: {s}\n", .{sdl.c.SDL_GetError()});
            return error.SdlInit;
        }
        errdefer sdl.c.SDL_Quit();

        const window = sdl.c.SDL_CreateWindow("klaxon hello", width, height, 0) orelse {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{sdl.c.SDL_GetError()});
            return error.SdlWindow;
        };
        errdefer sdl.c.SDL_DestroyWindow(window);

        // Text input events flow from window creation (TextField focus is
        // managed by the input router; refine per-platform later).
        _ = sdl.c.SDL_StartTextInput(window);

        const ctx = kx.create(@ptrCast(window), width, height, backend) orelse {
            std.debug.print("kx_create failed (backend {s})\n", .{kx.c.kx_backend_name(backend)});
            return error.KxCreate;
        };
        errdefer kx.c.kx_destroy(ctx);

        // Raster presents through an SDL streaming texture; GPU backends present
        // inside the shim (onscreen surface attached to the window).
        const renderer = if (backend == kx.c.KX_BACKEND_RASTER)
            sdl.c.SDL_CreateRenderer(window, null) orelse return error.SdlRenderer
        else
            null;
        errdefer {
            if (renderer) |r| sdl.c.SDL_DestroyRenderer(r);
        }

        const texture = if (renderer) |r|
            sdl.c.SDL_CreateTexture(r, sdl.c.SDL_PIXELFORMAT_ABGR8888, sdl.c.SDL_TEXTUREACCESS_STREAMING, width, height) orelse return error.SdlTexture
        else
            null;
        errdefer {
            if (texture) |t| sdl.c.SDL_DestroyTexture(t);
        }

        const pixels = try allocator.alloc(u8, @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4);
        errdefer allocator.free(pixels);

        const backend_name: [*:0]const u8 = kx.c.kx_backend_name(backend) orelse "unknown";

        return .{
            .allocator = allocator,
            .window = window,
            .ctx = ctx,
            .renderer = renderer,
            .texture = texture,
            .pixels = pixels,
            .width = width,
            .height = height,
            .ppm_path = ppm_path,
            .stats = .{ .backend = backend_name },
            .input = .{},
            .timeline = anim.Timeline.init(allocator),
        };
    }

    pub fn deinit(host: *Host) void {
        host.timeline.deinit();
        if (host.texture) |t| sdl.c.SDL_DestroyTexture(t);
        if (host.renderer) |r| sdl.c.SDL_DestroyRenderer(r);
        kx.c.kx_destroy(host.ctx);
        sdl.c.SDL_DestroyWindow(host.window);
        sdl.c.SDL_Quit();
        host.allocator.free(host.pixels);
    }

    /// Frame loop. Renders only when the tree is dirty; at idle it blocks on
    /// SDL_WaitEvent — 0 frames, 0 wakeups. `on_frame` is the app tick (it may
    /// mark nodes dirty). The animation timeline is ticked every iteration:
    /// active animations update signals → nodes mark dirty → the frame
    /// renders below (time-based values — the tick rate is the loop rate,
    /// ~120 Hz while animating).
    pub fn run(host: *Host, root: *Node, max_frames: u64, on_frame: ?OnFrame, on_frame_ctx: ?*anyopaque) !void {
        var quit = false;
        while (!quit and host.stats.frames < max_frames) {
            const iter_start_ns = sdl.c.SDL_GetTicksNS();
            // Animations (1e): advance the timeline — active animations update
            // signals → nodes mark dirty → the frame renders below.
            host.timeline.tick(sdl.c.SDL_GetTicks());
            var event: sdl.c.SDL_Event = undefined;
            if (root.dirty) {
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
            } else {
                // True idle: block until an event arrives (0 wakeups).
                if (sdl.c.SDL_WaitEvent(&event)) {
                    if (host.handleEvent(root, &event)) quit = true;
                    while (sdl.c.SDL_PollEvent(&event)) {
                        if (host.handleEvent(root, &event)) quit = true;
                    }
                }
            }
            // App tick every iteration (may mark nodes dirty).
            if (on_frame) |f| f(on_frame_ctx, host.stats.frames);
            // Render only when the tree is dirty.
            if (!quit and root.dirty) host.renderFrame(root);
            // Pace the whole iteration to the frame budget (~120 fps active).
            host.paceIteration(iter_start_ns);
        }
    }

    fn renderFrame(host: *Host, root: *Node) void {
        // Layout pass (Phase 1e): re-layout when sizes/structure changed.
        // Layout moves content, so the frame repaints fully.
        if (root.layout_dirty) {
            root.layout(root.bounds);
            root.dirty = true;
            root.clearDamage();
        }
        host.frame_start_ns = sdl.c.SDL_GetTicksNS();
        kx.c.kx_begin_frame(host.ctx);
        if (root.damage_valid) {
            // Dirty-rect (Phase 1e): repaint the tree clipped to the damaged
            // region — the surface is retained, untouched pixels stay.
            const d = root.damage;
            kx.c.kx_clip_rect(host.ctx, d.x, d.y, d.w, d.h);
            root.paint(host.ctx);
            kx.c.kx_clip_reset(host.ctx);
        } else {
            root.paint(host.ctx);
        }
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

    /// Pace one loop iteration to the frame budget: delay only the remainder
    /// of the 8.3 ms budget (slow iterations run unthrottled).
    fn paceIteration(host: *Host, iter_start_ns: u64) void {
        _ = host;
        const elapsed = sdl.c.SDL_GetTicksNS() - iter_start_ns;
        if (elapsed < FRAME_BUDGET_NS) {
            const remaining_ms: u32 = @intCast((FRAME_BUDGET_NS - elapsed) / 1_000_000);
            if (remaining_ms > 0) sdl.c.SDL_Delay(remaining_ms);
        }
    }

    /// Returns true if the event requests quit.
    fn handleEvent(host: *Host, root: *Node, event: *sdl.c.SDL_Event) bool {
        if (event.type == sdl.c.SDL_EVENT_QUIT) return true;
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
            sdl.c.SDL_EVENT_MOUSE_MOTION => host.input.dispatchPointer(root, .{
                .phase = .move,
                .x = event.motion.x,
                .y = event.motion.y,
                .pointer = event.motion.which,
                .time_ms = time_ms,
            }),
            sdl.c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (event.button.button == sdl.c.SDL_BUTTON_LEFT) {
                    host.input.dispatchPointer(root, .{
                        .phase = .down,
                        .x = event.button.x,
                        .y = event.button.y,
                        .pointer = event.button.which,
                        .time_ms = time_ms,
                    });
                }
            },
            sdl.c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == sdl.c.SDL_BUTTON_LEFT) {
                    host.input.dispatchPointer(root, .{
                        .phase = .up,
                        .x = event.button.x,
                        .y = event.button.y,
                        .pointer = event.button.which,
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
            sdl.c.SDL_EVENT_TEXT_INPUT => host.input.dispatchKey(.{
                .kind = .text_input,
                .text = std.mem.span(event.text.text),
            }),
            sdl.c.SDL_EVENT_KEY_DOWN => host.input.dispatchKey(.{
                .kind = .key_down,
                .key = sdlKeyToKey(event.key.key),
            }),
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
            else => .unknown,
        };
    }

    fn resize(host: *Host, w: c_int, h: c_int) void {
        host.width = w;
        host.height = h;
        kx.c.kx_resize(host.ctx, w, h);
        host.allocator.free(host.pixels);
        host.pixels = host.allocator.alloc(u8, @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4) catch @panic("klaxon: out of memory");
        if (host.texture) |t| {
            sdl.c.SDL_DestroyTexture(t);
            host.texture = sdl.c.SDL_CreateTexture(host.renderer.?, sdl.c.SDL_PIXELFORMAT_ABGR8888, sdl.c.SDL_TEXTUREACCESS_STREAMING, w, h);
        }
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
