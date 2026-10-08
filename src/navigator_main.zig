// Klaxon navigator demo (Phase 2a) — entry point: page stack, transitions
// (slide / fade / slide-up), hero flight, deep links, back (Escape / Android
// hardware button).
//
//   zig build navigator                  — run the demo
//   zig build navigator -- metal         — Graphite-Metal backend
//   zig build navigator -- klaxon://detail/42   — cold-start deep link
//
// Headless smoke (CI): SDL_VIDEODRIVER=dummy runs 600 frames; the app tick
// scripts a push/push/pop/push/popToRoot/push sequence so every transition
// is exercised.
const std = @import("std");
const kx = @import("kx.zig");
const ui = @import("ui.zig");
const widgets = @import("widgets.zig");
const input_mod = @import("ui/input.zig");
const nav_mod = @import("ui/navigator.zig");
const host_mod = @import("host.zig");

const width: c_int = 480;
const height: c_int = 800;
const max_frames: u64 = 600;

const Node = ui.node.Node;
const Color = ui.paint.Color;

// --- theme (fixed dark) ---
const bg_home: Color = 0x14141EFF;
const bg_a: Color = 0x1A2238FF;
const bg_b: Color = 0x241A38FF;
const bg_c: Color = 0x1A3824FF;
const bg_detail: Color = 0x38241AFF;
const accent: Color = 0x4C6EF5FF;
const fg: Color = 0xF0F0F5FF;
const fg_dim: Color = 0xA0A0B0FF;

const App = struct {
    allocator: std.mem.Allocator,
    nav: *nav_mod.Navigator,
};

// --- button callbacks (the ctx lives for the app's lifetime: page_allocator) ---

const PushCtx = struct {
    nav: *nav_mod.Navigator,
    pattern: []const u8,
    param: ?nav_mod.Param = null,
};

fn pushCb(userdata: ?*anyopaque) void {
    const ctx: *PushCtx = @ptrCast(@alignCast(userdata.?));
    if (ctx.param) |p| {
        ctx.nav.push(ctx.pattern, &.{p}) catch |e| std.debug.print("nav push failed: {s}\n", .{@errorName(e)});
    } else {
        ctx.nav.push(ctx.pattern, &.{}) catch |e| std.debug.print("nav push failed: {s}\n", .{@errorName(e)});
    }
}

fn popCb(userdata: ?*anyopaque) void {
    const nav: *nav_mod.Navigator = @ptrCast(@alignCast(userdata.?));
    _ = nav.pop();
}

fn pushButton(app: *App, label: []const u8, pattern: []const u8, param: ?nav_mod.Param) *Node {
    const ctx = std.heap.page_allocator.create(PushCtx) catch @panic("klaxon: out of memory");
    ctx.* = .{ .nav = app.nav, .pattern = pattern, .param = param };
    const btn = widgets.input.button(app.allocator, .{ .fn_ptr = pushCb, .userdata = ctx }, .{}) catch @panic("klaxon: out of memory");
    btn.add(widgets.text.text(app.allocator, label, .{ .color = fg }) catch @panic("klaxon: out of memory"));
    return btn;
}

fn backButton(app: *App) *Node {
    const btn = widgets.input.button(app.allocator, .{ .fn_ptr = popCb, .userdata = app.nav }, .{}) catch @panic("klaxon: out of memory");
    btn.add(widgets.text.text(app.allocator, "Back", .{ .color = fg }) catch @panic("klaxon: out of memory"));
    return btn;
}

// --- page scaffold: Container(bg) > Padding(24) > Column(title, body) ---

fn scaffold(allocator: std.mem.Allocator, bg: Color, title: []const u8, body: *Node) *Node {
    const col = widgets.layout.column(allocator, .{ .gap = 16 }) catch @panic("klaxon: out of memory");
    col.add(widgets.text.text(allocator, title, .{ .size = 28, .bold = true, .color = fg }) catch @panic("klaxon: out of memory"));
    col.add(body);
    const pad = widgets.layout.padding(allocator, ui.layout.EdgeInsets.all(24)) catch @panic("klaxon: out of memory");
    pad.add(col);
    const box = widgets.container.container(allocator, .{ .color = bg }) catch @panic("klaxon: out of memory");
    box.add(pad);
    return box;
}

/// A hero cover of a fixed size (the shared element between home and detail).
fn heroCover(allocator: std.mem.Allocator, w: f32, h: f32) *Node {
    const h_node = widgets.navigator.hero(allocator, .{ .tag = "cover" }) catch @panic("klaxon: out of memory");
    const fix = widgets.layout.constrainedBox(allocator, .{ .min_w = w, .min_h = h, .max_w = w, .max_h = h }) catch @panic("klaxon: out of memory");
    fix.add(widgets.container.container(allocator, .{ .color = accent, .radius = 12 }) catch @panic("klaxon: out of memory"));
    h_node.add(fix);
    const c = widgets.layout.center(allocator) catch @panic("klaxon: out of memory");
    c.add(h_node);
    return c;
}

// --- pages ---

fn homePage(userdata: ?*anyopaque, route: nav_mod.Route) *Node {
    _ = route;
    const app: *App = @ptrCast(@alignCast(userdata.?));
    const a = app.allocator;
    const body = widgets.layout.column(a, .{ .gap = 16 }) catch @panic("klaxon: out of memory");
    body.add(widgets.text.text(a, "Page stack, transitions, hero, deep links, back.", .{ .size = 14, .color = fg_dim }) catch @panic("klaxon: out of memory"));
    body.add(heroCover(a, 80, 80));
    body.add(pushButton(app, "Page A (slide)", "page_a", null));
    body.add(pushButton(app, "Page B (fade)", "page_b", null));
    body.add(pushButton(app, "Detail #7 (hero flight)", "detail/{id}", .{ .key = "id", .value = "7" }));
    return scaffold(a, bg_home, "Klaxon Navigator", body);
}

fn pageA(userdata: ?*anyopaque, route: nav_mod.Route) *Node {
    _ = route;
    const app: *App = @ptrCast(@alignCast(userdata.?));
    const a = app.allocator;
    const body = widgets.layout.column(a, .{ .gap = 16 }) catch @panic("klaxon: out of memory");
    body.add(widgets.text.text(a, "Slide transition (iOS-style, with parallax).", .{ .size = 14, .color = fg_dim }) catch @panic("klaxon: out of memory"));
    body.add(backButton(app));
    body.add(pushButton(app, "Page C (slide up)", "page_c", null));
    return scaffold(a, bg_a, "Page A", body);
}

fn pageB(userdata: ?*anyopaque, route: nav_mod.Route) *Node {
    _ = route;
    const app: *App = @ptrCast(@alignCast(userdata.?));
    const a = app.allocator;
    const body = widgets.layout.column(a, .{ .gap = 16 }) catch @panic("klaxon: out of memory");
    body.add(widgets.text.text(a, "Fade transition (cross-fade).", .{ .size = 14, .color = fg_dim }) catch @panic("klaxon: out of memory"));
    body.add(backButton(app));
    return scaffold(a, bg_b, "Page B", body);
}

fn pageC(userdata: ?*anyopaque, route: nav_mod.Route) *Node {
    _ = route;
    const app: *App = @ptrCast(@alignCast(userdata.?));
    const a = app.allocator;
    const body = widgets.layout.column(a, .{ .gap = 16 }) catch @panic("klaxon: out of memory");
    body.add(widgets.text.text(a, "Slide-up transition (sheet-style).", .{ .size = 14, .color = fg_dim }) catch @panic("klaxon: out of memory"));
    body.add(backButton(app));
    return scaffold(a, bg_c, "Page C", body);
}

fn detailPage(userdata: ?*anyopaque, route: nav_mod.Route) *Node {
    const app: *App = @ptrCast(@alignCast(userdata.?));
    const a = app.allocator;
    const id = route.params.get("id") orelse "?";
    var id_buf: [32]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "id = {s}", .{id}) catch "id = ?";
    var path_buf: [128]u8 = undefined;
    const path_str = std.fmt.bufPrint(&path_buf, "path = {s}", .{route.path}) catch "path = ?";
    const body = widgets.layout.column(a, .{ .gap = 16 }) catch @panic("klaxon: out of memory");
    body.add(heroCover(a, 200, 120));
    body.add(widgets.text.text(a, id_str, .{ .size = 16, .color = fg }) catch @panic("klaxon: out of memory"));
    body.add(widgets.text.text(a, path_str, .{ .size = 14, .color = fg_dim }) catch @panic("klaxon: out of memory"));
    body.add(backButton(app));
    return scaffold(a, bg_detail, "Detail", body);
}

// --- app tick (the headless smoke script) ---

fn onFrame(ctx: ?*anyopaque, frame: u64) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    switch (frame) {
        30 => app.nav.push("page_a", &.{}) catch |e| std.debug.print("push page_a: {s}\n", .{@errorName(e)}),
        120 => app.nav.push("detail/{id}", &.{.{ .key = "id", .value = "3" }}) catch |e| std.debug.print("push detail: {s}\n", .{@errorName(e)}),
        240 => _ = app.nav.pop(),
        300 => app.nav.push("page_b", &.{}) catch |e| std.debug.print("push page_b: {s}\n", .{@errorName(e)}),
        400 => app.nav.popToRoot(),
        480 => app.nav.push("detail/{id}", &.{.{ .key = "id", .value = "9" }}) catch |e| std.debug.print("push detail: {s}\n", .{@errorName(e)}),
        else => {},
    }
}

// --- entry point ---

const Options = struct {
    backend: kx.c.kx_backend,
    uri: ?[]const u8,
};

fn optsFromArgs(args: std.process.Args) Options {
    var it = std.process.Args.Iterator.init(args);
    _ = it.next(); // exe name
    var backend: kx.c.kx_backend = kx.c.KX_BACKEND_RASTER;
    var uri: ?[]const u8 = null;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "metal")) {
            backend = kx.c.KX_BACKEND_GRAPHITE_METAL;
        } else if (std.mem.startsWith(u8, arg, "klaxon://")) {
            uri = arg;
        }
    }
    return .{ .backend = backend, .uri = uri };
}

test "demo: the home page lays out" {
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var app = App{ .allocator = std.testing.allocator, .nav = &nav };
    try nav.define("home", .{ .fn_ptr = homePage, .userdata = &app }, .none);
    try nav.define("page_a", .{ .fn_ptr = pageA, .userdata = &app }, .slide);
    try nav.define("detail/{id}", .{ .fn_ptr = detailPage, .userdata = &app }, .slide);
    try nav.push("home", &.{});
    const view = try widgets.navigator.navigatorView(std.testing.allocator, .{ .navigator = &nav });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 480, .h = 800 });
    try std.testing.expectEqual(@as(usize, 1), view.children.items.len);
    // the host re-lays out on resize / after a push (markLayoutDirty)
    view.layout(.{ .x = 0, .y = 0, .w = 480, .h = 800 });
    try nav.push("page_a", &.{});
    view.layout(.{ .x = 0, .y = 0, .w = 480, .h = 800 });
    try std.testing.expectEqual(@as(usize, 2), view.children.items.len);
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

    var nav = nav_mod.Navigator.init(allocator);
    defer nav.deinit();
    var app = App{ .allocator = allocator, .nav = &nav };
    try nav.define("home", .{ .fn_ptr = homePage, .userdata = &app }, .none);
    try nav.define("page_a", .{ .fn_ptr = pageA, .userdata = &app }, .slide);
    try nav.define("page_b", .{ .fn_ptr = pageB, .userdata = &app }, .fade);
    try nav.define("page_c", .{ .fn_ptr = pageC, .userdata = &app }, .slide_up);
    try nav.define("detail/{id}", .{ .fn_ptr = detailPage, .userdata = &app }, .slide);
    try nav.push("home", &.{});
    if (opts.uri) |uri| try nav.navigateTo(uri); // cold-start deep link

    const view = try widgets.navigator.navigatorView(allocator, .{ .navigator = &nav });
    defer view.deinit(); // LIFO: the tree dies before the navigator's strings

    view.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) });

    std.debug.print("klaxon navigator (Skia {s}) — {d} route(s), stack depth {d}, {d}x{d}\n", .{ host.stats.backend, 5, nav.depth(), width, height });
    try host.run(view, max_frames, onFrame, &app);
    std.debug.print("rendered {d} frames, last frame {d:.2} ms, done\n", .{ host.stats.frames, host.stats.frame_time_ms });
}
