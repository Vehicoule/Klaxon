// Accessibility demo (Phase 2c) — semantic tree, keyboard focus, live regions.
//
//   zig build a11y                — run the demo
//   zig build a11y -- metal       — Graphite-Metal backend
//
// Headless smoke (CI): SDL_VIDEODRIVER=dummy runs 600 frames; the app tick
// scripts the keyboard (Tab / Enter / Space / arrows) so the focus order,
// the focus ring and a live-region announcement are exercised.
const std = @import("std");
const kx = @import("kx.zig");
const ui = @import("ui.zig");
const widgets = @import("widgets.zig");
const input_mod = @import("ui/input.zig");
const host_mod = @import("host.zig");

const width: c_int = 640;
const height: c_int = 480;
const max_frames: u64 = 600;

const Node = ui.node.Node;
const Color = ui.paint.Color;

// --- theme (fixed dark) ---
const bg: Color = 0x14141EFF;
const fg: Color = 0xF0F0F5FF;

const App = struct {
    allocator: std.mem.Allocator,
    toggle_sig: *ui.state.Signal(bool),
    slider_sig: *ui.state.Signal(f32),
    submitted: u32 = 0,
};

fn submitCb(userdata: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(userdata.?));
    app.submitted += 1;
    ui.semantics.announce("Submitted", .polite); // live region
}

fn buildTree(app: *App) !*Node {
    const a = app.allocator;
    const col = try widgets.layout.column(a, .{ .gap = 12 });
    const title = try widgets.text.text(a, "Klaxon a11y demo", .{ .size = 24, .bold = true, .color = fg });
    ui.semantics.attach(title, .{ .role = .heading }); // override the default .text role
    col.add(title);

    const form = try widgets.layout.row(a, .{ .gap = 8 });
    form.add(try widgets.input.textField(a, .{ .placeholder = "Your name", .color = fg }, null, null));
    const submit = try widgets.input.button(a, .{ .fn_ptr = submitCb, .userdata = app }, .{});
    submit.add(try widgets.text.text(a, "Submit", .{ .color = 0xFFFFFFFF }));
    form.add(submit);
    col.add(form);

    const notif = try widgets.layout.row(a, .{ .gap = 8 });
    notif.add(try widgets.input.toggle(a, app.toggle_sig, null, .{}));
    notif.add(try widgets.text.text(a, "Notifications", .{ .color = fg }));
    col.add(notif);

    const vol = try widgets.layout.row(a, .{ .gap = 8 });
    vol.add(try widgets.input.slider(a, app.slider_sig, null, .{}));
    vol.add(try widgets.text.text(a, "Volume", .{ .color = fg }));
    col.add(vol);

    const pad = try widgets.layout.padding(a, .{ .left = 24, .top = 24, .right = 24, .bottom = 24 });
    pad.add(col);
    const root = try widgets.container.container(a, .{ .color = bg });
    root.add(pad);
    return root;
}

/// App tick (the headless smoke script): exercise the focus order, keyboard
/// activation and a live-region announcement.
fn onFrame(ctx: ?*anyopaque, frame: u64) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    _ = app;
    const fm = ui.semantics.currentFocus().?;
    switch (frame) {
        30 => fm.focusNext(), // → TextField
        60 => fm.focusNext(), // → Submit
        90 => _ = fm.handleKey(.{ .kind = .key_down, .key = .enter }), // press Submit
        120 => fm.focusNext(), // → Toggle
        150 => _ = fm.handleKey(.{ .kind = .key_down, .key = .space }), // flip the toggle
        180 => fm.focusNext(), // → Slider
        210 => { // arrow key → the slider's on_key (routed to the focused node)
            if (input_mod.current()) |r| _ = r.dispatchKey(.{ .kind = .key_down, .key = .left });
        },
        240 => ui.semantics.announce("3 items added", .polite),
        else => {},
    }
}

const Options = struct {
    backend: kx.c.kx_backend,
};

fn optsFromArgs(args: std.process.Args) Options {
    var it = std.process.Args.Iterator.init(args);
    _ = it.next(); // exe name
    var backend: kx.c.kx_backend = kx.c.KX_BACKEND_RASTER;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "metal")) backend = kx.c.KX_BACKEND_GRAPHITE_METAL;
    }
    return .{ .backend = backend };
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

    const fm = try ui.semantics.FocusManager.init(allocator);
    defer fm.deinit();
    ui.semantics.setCurrentFocus(fm); // the host paints the focus ring + routes Tab
    defer ui.semantics.setCurrentFocus(null);
    const lb = try ui.semantics.LogBridge.init(allocator);
    defer lb.deinit();
    ui.semantics.setBridge(lb.bridge());
    defer ui.semantics.setBridge(null);

    var app = App{
        .allocator = allocator,
        .toggle_sig = try ui.state.Signal(bool).init(allocator, false),
        .slider_sig = try ui.state.Signal(f32).init(allocator, 0.5),
    };
    defer {
        app.toggle_sig.deinit();
        app.slider_sig.deinit();
    }

    const root = try buildTree(&app);
    defer root.deinit(); // LIFO: the tree dies before the focus manager's nodes
    fm.setRoot(root);
    root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) });

    std.debug.print("klaxon a11y (Skia {s}) — semantic tree, focus ring, live regions\n", .{host.stats.backend});
    try host.run(root, max_frames, onFrame, &app);
    std.debug.print("rendered {d} frames, last frame {d:.2} ms, done — {d} submissions, {d} a11y events\n", .{ host.stats.frames, host.stats.frame_time_ms, app.submitted, lb.events.items.len });
}

// --- tests ---

test "demo: focus order, keyboard activation, announcements" {
    const a = std.testing.allocator;
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    const lb = try ui.semantics.LogBridge.init(a);
    defer lb.deinit();
    ui.semantics.setBridge(lb.bridge());
    defer ui.semantics.setBridge(null);
    const fm = try ui.semantics.FocusManager.init(a);
    defer fm.deinit();
    ui.semantics.setCurrentFocus(fm);
    defer ui.semantics.setCurrentFocus(null);

    var app = App{
        .allocator = a,
        .toggle_sig = try ui.state.Signal(bool).init(a, false),
        .slider_sig = try ui.state.Signal(f32).init(a, 0.5),
    };
    defer {
        app.toggle_sig.deinit();
        app.slider_sig.deinit();
    }
    const root = try buildTree(&app);
    defer root.deinit();
    fm.setRoot(root);
    root.layout(.{ .x = 0, .y = 0, .w = 640, .h = 480 });

    // Focus order = semantic-tree order: TextField, Submit, Toggle, Slider.
    const order = try fm.focusOrder(a);
    defer a.free(order);
    try std.testing.expectEqual(@as(usize, 4), order.len);

    fm.focusNext(); // → TextField
    const field = router.focused.?;
    try std.testing.expectEqual(ui.semantics.Role.text_field, field.semantics.?.role);
    fm.focusNext(); // → Submit
    const submit = router.focused.?;
    try std.testing.expectEqual(ui.semantics.Role.button, submit.semantics.?.role);
    try std.testing.expect(fm.handleKey(.{ .kind = .key_down, .key = .enter }));
    try std.testing.expectEqual(@as(u32, 1), app.submitted);
    fm.focusNext(); // → Toggle
    const toggle = router.focused.?;
    try std.testing.expectEqual(ui.semantics.Role.toggle, toggle.semantics.?.role);
    try std.testing.expect(fm.handleKey(.{ .kind = .key_down, .key = .space }));
    try std.testing.expect(app.toggle_sig.peek());
    try std.testing.expectEqual(@as(?bool, true), toggle.semantics.?.checked); // synced
    fm.focusNext(); // → Slider
    const slider = router.focused.?;
    try std.testing.expectEqual(ui.semantics.Role.slider, slider.semantics.?.role);
    // Arrow key → the slider's on_key (routed to the focused node).
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .left }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), app.slider_sig.peek(), 0.001);
    try std.testing.expectEqualStrings("45%", slider.semantics.?.value); // synced

    // Live region.
    ui.semantics.announce("3 items added", .polite);

    // LogBridge saw: 4 focus_changed + 2 announces (submit + this one).
    var focus_events: u32 = 0;
    var announces: u32 = 0;
    for (lb.events.items) |e| {
        switch (e.kind) {
            .focus_changed => focus_events += 1,
            .announce => announces += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(u32, 4), focus_events);
    try std.testing.expectEqual(@as(u32, 2), announces);
}
