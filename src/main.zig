// Klaxon — hello world (Phase 0.3).
// Renders text through Skia and presents it in an SDL3 window.
// Backend: raster by default, pass `metal` for Graphite-Metal (macOS GPU).
// Debug: `--ppm=<path>` dumps frame 30 as a PPM (seed of golden-test tooling).
// Quits on window close or after `max_frames` frames (self-terminating smoke test).
const std = @import("std");
const sdl = @import("sdl.zig");
const kx = @import("kx.zig");

const width: c_int = 640;
const height: c_int = 480;
const max_frames: u32 = 600;

var pixels: [width * height * 4]u8 = undefined;

const Options = struct {
    backend: kx.c.kx_backend,
    ppm: ?[:0]const u8,
};

fn optsFromArgs(args: std.process.Args) Options {
    var it = std.process.Args.Iterator.init(args);
    _ = it.next(); // exe name
    var backend: kx.c.kx_backend = kx.c.KX_BACKEND_RASTER;
    var ppm: ?[:0]const u8 = null;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "metal")) {
            backend = kx.c.KX_BACKEND_GRAPHITE_METAL;
        } else if (std.mem.startsWith(u8, arg, "--ppm=")) {
            ppm = arg["--ppm=".len..];
        }
    }
    return .{ .backend = backend, .ppm = ppm };
}

// Minimal PPM (P6) writer via libc stdio — avoids pulling in an image encoder.
fn writePpm(path: [:0]const u8, rgba: []const u8, w: usize, h: usize) void {
    const f = std.c.fopen(path, "wb") orelse return;
    defer _ = std.c.fclose(f);
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrintSentinel(&header_buf, "P6\n{d} {d}\n255\n", .{ w, h }, 0) catch return;
    _ = std.c.fwrite(header.ptr, 1, header.len, f);
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        _ = std.c.fwrite(rgba.ptr + i, 1, 3, f); // RGBA → RGB
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const opts = optsFromArgs(init.args);
    const backend = opts.backend;
    std.debug.print("klaxon hello (Skia {s})\n", .{kx.c.kx_backend_name(backend)});

    if (!sdl.c.SDL_Init(sdl.c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{sdl.c.SDL_GetError()});
        return error.SdlInit;
    }
    defer sdl.c.SDL_Quit();

    const window = sdl.c.SDL_CreateWindow("klaxon hello", width, height, 0) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{sdl.c.SDL_GetError()});
        return error.SdlWindow;
    };
    defer sdl.c.SDL_DestroyWindow(window);

    const ctx = kx.create(@ptrCast(window), width, height, backend) orelse {
        std.debug.print("kx_create failed (backend {s})\n", .{kx.c.kx_backend_name(backend)});
        return error.KxCreate;
    };
    defer kx.c.kx_destroy(ctx);

    // Raster presents through an SDL streaming texture; GPU backends present
    // inside the shim (onscreen surface attached to the window).
    const renderer = if (backend == kx.c.KX_BACKEND_RASTER)
        sdl.c.SDL_CreateRenderer(window, null) orelse {
            std.debug.print("SDL_CreateRenderer failed: {s}\n", .{sdl.c.SDL_GetError()});
            return error.SdlRenderer;
        }
    else
        null;
    defer {
        if (renderer) |r| sdl.c.SDL_DestroyRenderer(r);
    }

    const texture = if (renderer) |r|
        sdl.c.SDL_CreateTexture(r, sdl.c.SDL_PIXELFORMAT_ABGR8888, sdl.c.SDL_TEXTUREACCESS_STREAMING, width, height) orelse {
            std.debug.print("SDL_CreateTexture failed: {s}\n", .{sdl.c.SDL_GetError()});
            return error.SdlTexture;
        }
    else
        null;
    defer {
        if (texture) |t| sdl.c.SDL_DestroyTexture(t);
    }

    var frame: u32 = 0;
    var quit = false;
    while (!quit and frame < max_frames) : (frame += 1) {
        var event: sdl.c.SDL_Event = undefined;
        while (sdl.c.SDL_PollEvent(&event)) {
            if (event.type == sdl.c.SDL_EVENT_QUIT) quit = true;
        }

        kx.c.kx_begin_frame(ctx);
        const pulse: u32 = frame % 200;
        kx.c.kx_clear(ctx, 0x181828FF + (pulse << 24)); // animated background
        kx.c.kx_draw_text(ctx, "Hello from Klaxon — rendered by Skia", 24, 60, 28, 0xFFFFFFFF);
        kx.c.kx_draw_text(ctx, kx.c.kx_backend_name(backend), 24, 100, 16, 0xFFAAAAAA);
        kx.c.kx_end_frame(ctx);

        if (texture) |t| {
            var w: c_int = 0;
            var h: c_int = 0;
            if (kx.c.kx_readback_rgba(ctx, &pixels, pixels.len, &w, &h)) {
                if (frame == 30 and opts.ppm != null) {
                    writePpm(opts.ppm.?, &pixels, @intCast(w), @intCast(h));
                }
                _ = sdl.c.SDL_UpdateTexture(t, null, &pixels, width * 4);
                if (renderer) |r| {
                    _ = sdl.c.SDL_RenderTexture(r, t, null, null);
                    _ = sdl.c.SDL_RenderPresent(r);
                }
            }
        }
        sdl.c.SDL_Delay(16);
    }

    std.debug.print("rendered {d} frames via {s}, done\n", .{ frame, kx.c.kx_backend_name(backend) });
}

test "smoke" {
    try std.testing.expectEqual(@as(u32, 600), max_frames);
}
