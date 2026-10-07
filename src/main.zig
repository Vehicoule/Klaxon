// Klaxon — hello world (Phase 0.5/0.6).
// Builds a widget tree (demo.zig), lays it out, runs it through the Host
// (window + dirty-flag event loop). Backend: raster by default, `metal` for
// Graphite-Metal. `--ppm=<path>` dumps frame 30 (seed of golden-test tooling).
const std = @import("std");
const kx = @import("kx.zig");
const ui = @import("ui.zig");
const demo_mod = @import("demo.zig");
const host_mod = @import("host.zig");

const width: c_int = 640;
const height: c_int = 480;
const max_frames: u64 = 600;

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

/// App tick: set the background signal → subscribers fire → root.markDirty →
/// the host renders a frame (fine-grained reactivity, Phase 1a).
fn animate(ctx: ?*anyopaque, frame: u64) void {
    const bg: *ui.state.Signal(u32) = @ptrCast(@alignCast(ctx.?));
    const pulse: u32 = @intCast(frame % 200);
    bg.set(0x181828FF + (pulse << 24));
}

pub fn main(init: std.process.Init.Minimal) !void {
    const opts = optsFromArgs(init.args);

    var debug_alloc = std.heap.DebugAllocator(.{}){};
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    var host = try host_mod.Host.init(allocator, width, height, opts.backend, opts.ppm);
    defer host.deinit();

    var demo = try demo_mod.buildTree(allocator);
    defer demo.deinit();
    const root = demo.root;

    root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) });

    std.debug.print("klaxon hello (Skia {s}) — widget tree: {d} nodes, reactive bg\n", .{ host.stats.backend, countNodes(root) });
    try host.run(root, max_frames, animate, demo.bg);
    std.debug.print("rendered {d} frames, last frame {d:.2} ms, done\n", .{ host.stats.frames, host.stats.frame_time_ms });
}

fn countNodes(node: *ui.node.Node) u64 {
    var n: u64 = 1;
    for (node.children.items) |child| n += countNodes(child);
    return n;
}

test "smoke" {
    try std.testing.expectEqual(@as(u64, 600), max_frames);
}

// Pull the widget library's tests into the test build (test discovery follows
// referenced decls; refAllDecls on each module makes it deterministic).
test "widgets" {
    const widgets = @import("widgets.zig");
    std.testing.refAllDecls(widgets);
    inline for (.{ widgets.layout, widgets.text, widgets.icon, widgets.image, widgets.container, widgets.divider }) |mod| {
        std.testing.refAllDecls(mod);
    }
}
