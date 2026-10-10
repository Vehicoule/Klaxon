// Klaxon — hello world (Phase 0.5/0.6).
// Builds a widget tree (demo.zig), lays it out, runs it through the Host
// (window + dirty-flag event loop). Backend: raster by default, `metal` for
// Graphite-Metal (wasm: ganesh-webgl2 by default — Phase 3f).
// `--ppm=<path>` dumps frame 30 (seed of golden-test tooling).
const std = @import("std");
const builtin = @import("builtin");
const kx = @import("kx.zig");
const ui = @import("ui.zig");
const input_mod = @import("ui/input.zig");
const demo_mod = @import("demo.zig");
const host_mod = @import("host.zig");

// Phase 3f: on emscripten the browser owns the main thread — main() installs
// the rAF loop (platform_wasm.runWasm) instead of the blocking host.run().
const platform_wasm = if (builtin.os.tag == .emscripten) @import("platform_wasm.zig") else struct {};

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
    // Default backend: raster (native) / Ganesh WebGL2 (wasm, Phase 3f) —
    // the browser has no Metal/Vulkan; WebGL2 is the GPU path, raster stays
    // the always-available fallback.
    var backend: kx.c.kx_backend = if (builtin.os.tag == .emscripten)
        kx.c.KX_BACKEND_GANESH_WEBGL2
    else
        kx.c.KX_BACKEND_RASTER;
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
    if (builtin.os.tag == .emscripten) {
        // Wasm (Phase 3f): the browser owns the main thread — runWasm installs
        // the rAF loop with simulate_infinite_loop = 1, which unwinds main()'s
        // stack (defers never run). Host and Demo therefore live in stable
        // storage (page_allocator, intentional leak: the page lives as long as
        // the tab) so the rAF callback never reuses a dangling stack pointer
        // (Devin issue #2).
        const stable = std.heap.page_allocator;
        // No argv parsing on emscripten: hardcoded Ganesh WebGL2 backend.
        const host_ptr = try stable.create(host_mod.Host);
        host_ptr.* = try host_mod.Host.init(stable, width, height, kx.c.KX_BACKEND_GANESH_WEBGL2, null);
        // No defer host.deinit(): the host lives as long as the page.
        input_mod.setCurrent(&host_ptr.input); // the router is process-global (single-window P0)
        ui.anim.setCurrent(&host_ptr.timeline); // the animation timeline, same pattern
        host_ptr.cursors = true; // pointer cursors (Phase 2d-0.5): hand over the button
        // the focus ring follows the theme's platform tokens (Phase 2d-0.5)
        if (ui.semantics.currentFocus()) |fm| {
            fm.ring_width = @import("theme.zig").light.platform.focus_ring_width;
            fm.ring_offset = @import("theme.zig").light.platform.focus_ring_offset;
        }

        const demo_ptr = try stable.create(demo_mod.Demo);
        demo_ptr.* = try demo_mod.buildTree(stable);
        // No defer demo.deinit(): same stable-storage rationale as the host.
        const root = demo_ptr.root;

        root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) });

        std.debug.print("klaxon hello (Skia {s}) — widget tree: {d} nodes, reactive bg\n", .{ host_ptr.stats.backend, countNodes(root) });
        // Installs the rAF main loop — one runIteration per animation frame,
        // never blocking. demo_ptr.bg is a *Signal(u32) owned by the
        // heap-allocated Demo: stable for the lifetime of the page.
        platform_wasm.runWasm(host_ptr, root, max_frames, animate, demo_ptr.bg);
        return; // unreachable with simulate_infinite_loop = 1
    }

    const opts = optsFromArgs(init.args);

    var debug_alloc = std.heap.DebugAllocator(.{}){};
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    var host = try host_mod.Host.init(allocator, width, height, opts.backend, opts.ppm);
    defer host.deinit();
    input_mod.setCurrent(&host.input); // the router is process-global (single-window P0)
    ui.anim.setCurrent(&host.timeline); // the animation timeline, same pattern
    host.cursors = true; // pointer cursors (Phase 2d-0.5): hand over the button
    // the focus ring follows the theme's platform tokens (Phase 2d-0.5)
    if (ui.semantics.currentFocus()) |fm| {
        fm.ring_width = @import("theme.zig").light.platform.focus_ring_width;
        fm.ring_offset = @import("theme.zig").light.platform.focus_ring_offset;
    }

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
    inline for (.{ widgets.layout, widgets.text, widgets.icon, widgets.image, widgets.container, widgets.divider, widgets.input, widgets.gestures, widgets.anim, widgets.list_view, widgets.grid_view, widgets.scroll_view, widgets.scrollbar, widgets.navigator, widgets.i18n, widgets.app_bar, widgets.nav_bar, widgets.drawer, widgets.tabs, widgets.progress, widgets.badge, widgets.tooltip, widgets.bottom_sheet, widgets.dialog, widgets.snackbar }) |mod| {
        std.testing.refAllDecls(mod);
    }
    std.testing.refAllDecls(ui.anim);
    std.testing.refAllDecls(ui.scroll);
    std.testing.refAllDecls(ui.navigator);
    std.testing.refAllDecls(ui.i18n);
    std.testing.refAllDecls(ui.semantics);
    std.testing.refAllDecls(ui.node);
    std.testing.refAllDecls(ui.state);
    std.testing.refAllDecls(ui.input);
    std.testing.refAllDecls(ui.layout);
    std.testing.refAllDecls(ui.gestures);
    std.testing.refAllDecls(ui.value);
    std.testing.refAllDecls(@import("registry.zig"));
}

test "gallery" {
    std.testing.refAllDecls(@import("theme.zig"));
    std.testing.refAllDecls(@import("gallery.zig"));
}

test "navigator demo" {
    std.testing.refAllDecls(@import("navigator_main.zig"));
}

test "i18n demo" {
    std.testing.refAllDecls(@import("i18n_main.zig"));
}

test "a11y demo" {
    std.testing.refAllDecls(@import("a11y_main.zig"));
}
