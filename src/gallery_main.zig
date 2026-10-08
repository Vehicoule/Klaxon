// Klaxon gallery (Phase 1g) — entry point: host + event loop.
// Builds the gallery tree, runs it through the Host (window + dirty-flag
// event loop). Backend: raster by default, `metal` for Graphite-Metal.
const std = @import("std");
const kx = @import("kx.zig");
const ui = @import("ui.zig");
const input_mod = @import("ui/input.zig");
const host_mod = @import("host.zig");
const gallery_mod = @import("gallery.zig");

const width: c_int = gallery_mod.WINDOW_W;
const height: c_int = gallery_mod.WINDOW_H;
const max_frames: u64 = 600;

const Options = struct {
    backend: kx.c.kx_backend,
};

fn optsFromArgs(args: std.process.Args) Options {
    var it = std.process.Args.Iterator.init(args);
    _ = it.next(); // exe name
    var backend: kx.c.kx_backend = kx.c.KX_BACKEND_RASTER;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "metal")) {
            backend = kx.c.KX_BACKEND_GRAPHITE_METAL;
        }
    }
    return .{ .backend = backend };
}

fn lerpChannel(a: u32, b: u32, shift: u5, t: f32) u32 {
    const x = @as(f32, @floatFromInt((a >> shift) & 0xFF));
    const y = @as(f32, @floatFromInt((b >> shift) & 0xFF));
    return @as(u32, @intFromFloat(x + (y - x) * t)) << shift;
}

fn lerpColor(a: u32, b: u32, t: f32) u32 {
    return lerpChannel(a, b, 24, t) | lerpChannel(a, b, 16, t) | lerpChannel(a, b, 8, t) | 0xFF;
}

/// App tick: pulse the Animations section's accent box — exercises the
/// timeline, the signals and the dirty-rect path on every frame.
fn onFrame(ctx: ?*anyopaque, frame: u64) void {
    const g: *gallery_mod.Gallery = @ptrCast(@alignCast(ctx.?));
    const t = @as(f32, @floatFromInt(frame % 240)) / 240.0;
    const s = (@sin(t * 2 * std.math.pi) + 1) / 2;
    const theme = g.currentTheme();
    // M3 state layer: the pulse rides the hover opacity (0..8% on_primary).
    g.pulse_sig.set(lerpColor(theme.colors.primary, theme.colors.on_primary, theme.state.hover * s));
}

pub fn main(init: std.process.Init.Minimal) !void {
    const opts = optsFromArgs(init.args);

    var debug_alloc = std.heap.DebugAllocator(.{}){};
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    var host = try host_mod.Host.init(allocator, width, height, opts.backend, null);
    defer host.deinit();
    input_mod.setCurrent(&host.input); // the router is process-global (single-window P0)
    ui.anim.setCurrent(&host.timeline); // the animation timeline, same pattern

    const g = try gallery_mod.Gallery.init(allocator);
    defer g.deinit();

    // the focus ring follows the theme's platform tokens (Phase 2d-0.5);
    // themeToggleCb re-syncs them on every density/theme switch
    if (ui.semantics.currentFocus()) |fm| {
        fm.ring_width = g.currentTheme().platform.focus_ring_width;
        fm.ring_offset = g.currentTheme().platform.focus_ring_offset;
    }
    // Pointer cursors follow the theme's platform layer (Phase 2d-0.5):
    // hand/ibeam over controls when the desktop preset is active.
    host.cursors = g.currentTheme().platform.cursors;
    var platform_ctx = struct { host: *host_mod.Host, gallery: *gallery_mod.Gallery }{ .host = &host, .gallery = g };
    g.on_platform_changed = .{ .fn_ptr = struct {
        fn cb(ud: ?*anyopaque) void {
            const ctx: *@TypeOf(platform_ctx) = @ptrCast(@alignCast(ud.?));
            ctx.host.cursors = ctx.gallery.currentTheme().platform.cursors;
        }
    }.cb, .userdata = &platform_ctx };

    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) });

    std.debug.print("klaxon gallery (Skia {s}) — widget tree: {d} nodes, {d}x{d}\n", .{ host.stats.backend, countNodes(g.root), width, height });
    try host.run(g.root, max_frames, onFrame, g);
    std.debug.print("rendered {d} frames, last frame {d:.2} ms, done\n", .{ host.stats.frames, host.stats.frame_time_ms });
}

fn countNodes(node: *ui.node.Node) u64 {
    var n: u64 = 1;
    for (node.children.items) |child| n += countNodes(child);
    return n;
}
