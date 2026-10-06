// Klaxon — hello world (Phase 0.2).
// Opens a window and renders animated frames through SDL3.
// Quits on window close or after `max_frames` frames (self-terminating smoke test).
const std = @import("std");
const sdl = @import("sdl.zig");

const max_frames: u32 = 600;

pub fn main() !void {
    std.debug.print("klaxon hello (SDL3)\n", .{});

    if (!sdl.c.SDL_Init(sdl.c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{sdl.c.SDL_GetError()});
        return error.SdlInit;
    }
    defer sdl.c.SDL_Quit();

    const window = sdl.c.SDL_CreateWindow("klaxon hello", 640, 480, 0) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{sdl.c.SDL_GetError()});
        return error.SdlWindow;
    };
    defer sdl.c.SDL_DestroyWindow(window);

    const renderer = sdl.c.SDL_CreateRenderer(window, null) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{sdl.c.SDL_GetError()});
        return error.SdlRenderer;
    };
    defer sdl.c.SDL_DestroyRenderer(renderer);

    var frame: u32 = 0;
    var quit = false;
    while (!quit and frame < max_frames) : (frame += 1) {
        var event: sdl.c.SDL_Event = undefined;
        while (sdl.c.SDL_PollEvent(&event)) {
            if (event.type == sdl.c.SDL_EVENT_QUIT) quit = true;
        }
        // Slow pulse so the window is visibly alive.
        const pulse: u8 = @intCast(frame % 200);
        _ = sdl.c.SDL_SetRenderDrawColor(renderer, 24, 24, 40 + pulse / 8, 255);
        _ = sdl.c.SDL_RenderClear(renderer);
        _ = sdl.c.SDL_RenderPresent(renderer);
        sdl.c.SDL_Delay(16);
    }

    std.debug.print("rendered {d} frames, done\n", .{frame});
}

test "smoke" {
    try std.testing.expectEqual(@as(u32, 600), max_frames);
}
