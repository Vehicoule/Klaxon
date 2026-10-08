// Klaxon i18n demo (Phase 2b) — entry point: locale switching at runtime,
// interpolation, ARB plurals, number/date formatting, and the RTL layout flip.
//
//   zig build i18n                — run the demo
//   zig build i18n -- metal       — Graphite-Metal backend
//
// Headless smoke (CI): SDL_VIDEODRIVER=dummy runs 600 frames; the app tick
// switches locale (en → fr → ar → ja → en) so the re-render and the RTL
// layout flip are exercised.
const std = @import("std");
const kx = @import("kx.zig");
const ui = @import("ui.zig");
const widgets = @import("widgets.zig");
const input_mod = @import("ui/input.zig");
const i18n_mod = @import("ui/i18n.zig");
const host_mod = @import("host.zig");

const width: c_int = 640;
const height: c_int = 480;
const max_frames: u64 = 600;

const Node = ui.node.Node;
const Color = ui.paint.Color;

// --- theme (fixed dark) ---
const bg: Color = 0x14141EFF;
const fg: Color = 0xF0F0F5FF;
const fg_dim: Color = 0xA0A0B0FF;
const box_red: Color = 0xE03131FF;
const box_blue: Color = 0x1C7ED6FF;

/// The demo date (fixed — the smoke stays deterministic).
const demo_date = i18n_mod.Date{ .year = 2026, .month = 10, .day = 7 };

const LocaleCtx = struct {
    i18n: *i18n_mod.I18n,
    tag: []const u8,
};

const App = struct {
    allocator: std.mem.Allocator,
    i18n: *i18n_mod.I18n,
    root: ?*Node = null,
    count_sig: *ui.state.Signal(i64),
    num_sig: *ui.state.Signal([]const u8),
    date_sig: *ui.state.Signal([]const u8),
    dir_sig: *ui.state.Signal([]const u8),
    ctxs: std.array_list.Managed(*LocaleCtx), // freed at app teardown
};

fn setLocaleCb(userdata: ?*anyopaque) void {
    const ctx: *LocaleCtx = @ptrCast(@alignCast(userdata.?));
    ctx.i18n.setLocale(ctx.tag) catch |e| std.debug.print("setLocale failed: {s}\n", .{@errorName(e)});
}

fn incCount(userdata: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(userdata.?));
    app.count_sig.set(app.count_sig.peek() + 1);
}

fn decCount(userdata: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(userdata.?));
    app.count_sig.set(app.count_sig.peek() - 1);
}

/// BoundText fmt for []const u8 signals: copy into the provided buffer.
fn copyFmt(s: []const u8, buf: []u8) []const u8 {
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// Recompute the locale-dependent display strings (number, date, direction).
/// The signals own their current string: the previous one is released.
fn recompute(userdata: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(userdata.?));
    const loc = app.i18n.locale() orelse return;
    const a = app.allocator;
    const num = loc.formatNumber(a, 1234567.891, .{ .decimals = 2 }) catch @panic("klaxon: out of memory");
    const date = loc.formatDate(a, demo_date, .medium) catch @panic("klaxon: out of memory");
    a.free(app.num_sig.peek());
    app.num_sig.set(num);
    a.free(app.date_sig.peek());
    app.date_sig.set(date);
    app.dir_sig.set(if (loc.direction == .rtl) "RTL" else "LTR");
}

/// A direction flip re-mirrors the layout: mark the root layout-dirty.
fn onDirectionChanged(userdata: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(userdata.?));
    if (app.root) |root| {
        root.markLayoutDirty();
        root.markDirty();
    }
}

fn localeButton(app: *App, tag: []const u8) !*Node {
    const ctx = try app.allocator.create(LocaleCtx);
    ctx.* = .{ .i18n = app.i18n, .tag = tag };
    try app.ctxs.append(ctx);
    const btn = try widgets.input.button(app.allocator, .{ .fn_ptr = setLocaleCb, .userdata = ctx }, .{});
    btn.add(try widgets.text.text(app.allocator, tag, .{ .color = fg, .bold = true }));
    return btn;
}

/// A label/value row: the label is localized, the value follows a signal.
fn kvRow(app: *App, label_key: []const u8, sig: *ui.state.Signal([]const u8)) !*Node {
    const a = app.allocator;
    const row = try widgets.layout.row(a, .{ .gap = 12 });
    const w = try widgets.layout.expanded(a, 1);
    w.add(try widgets.i18n.l10nText(a, app.i18n, label_key, .{ .color = fg_dim }));
    row.add(w);
    row.add(try widgets.text.BoundText([]const u8).text(a, sig, copyFmt, .{ .color = fg }));
    return row;
}

fn buildTree(app: *App) !*Node {
    const a = app.allocator;
    const col = try widgets.layout.column(a, .{ .gap = 12 });
    col.add(try widgets.i18n.l10nText(a, app.i18n, "app_title", .{ .size = 26, .bold = true, .color = fg }));
    col.add(try widgets.i18n.L10nText(struct { name: []const u8 }).text(a, app.i18n, "greeting", .{ .name = "Léa" }, .{ .size = 18, .color = fg }));

    // plural demo: value + count buttons
    const plural_row = try widgets.layout.row(a, .{ .gap = 8 });
    plural_row.add(try widgets.i18n.l10nPluralSig(a, app.i18n, "items", app.count_sig, .{ .color = fg }));
    const minus = try widgets.input.button(a, .{ .fn_ptr = decCount, .userdata = app }, .{});
    minus.add(try widgets.text.text(a, "-", .{ .color = fg, .bold = true }));
    plural_row.add(minus);
    const plus = try widgets.input.button(a, .{ .fn_ptr = incCount, .userdata = app }, .{});
    plus.add(try widgets.text.text(a, "+", .{ .color = fg, .bold = true }));
    plural_row.add(plus);
    col.add(plural_row);

    col.add(try kvRow(app, "number_label", app.num_sig));
    col.add(try kvRow(app, "date_label", app.date_sig));
    col.add(try kvRow(app, "direction_label", app.dir_sig));

    // locale switcher
    const sw = try widgets.layout.row(a, .{ .gap = 8 });
    inline for (.{ "en", "fr", "ja", "ar" }) |tag| {
        sw.add(try localeButton(app, tag));
    }
    col.add(sw);

    // the mirror demo: two colored boxes (flips with the direction)
    const boxes = try widgets.layout.row(a, .{ .gap = 8 });
    inline for (.{ box_red, box_blue }) |c| {
        const fix = try widgets.layout.constrainedBox(a, .{ .min_w = 48, .min_h = 24, .max_w = 48, .max_h = 24 });
        fix.add(try widgets.container.container(a, .{ .color = c, .radius = 6 }));
        boxes.add(fix);
    }
    col.add(boxes);

    col.add(try widgets.i18n.l10nText(a, app.i18n, "rtl_hint", .{ .size = 12, .color = fg_dim }));

    const pad = try widgets.layout.paddingDir(a, .{ .start = 24, .end = 24, .top = 24, .bottom = 24 });
    pad.add(col);
    const root = try widgets.container.container(a, .{ .color = bg });
    root.add(pad);
    return root;
}

/// App tick (the headless smoke script): cycle the locales so the re-render
/// and the RTL flip are exercised.
fn onFrame(ctx: ?*anyopaque, frame: u64) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    switch (frame) {
        30 => app.i18n.setLocale("fr") catch |e| std.debug.print("setLocale: {s}\n", .{@errorName(e)}),
        150 => app.i18n.setLocale("ar") catch |e| std.debug.print("setLocale: {s}\n", .{@errorName(e)}),
        300 => app.i18n.setLocale("ja") catch |e| std.debug.print("setLocale: {s}\n", .{@errorName(e)}),
        450 => app.i18n.setLocale("en") catch |e| std.debug.print("setLocale: {s}\n", .{@errorName(e)}),
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

    var i18n = try i18n_mod.I18n.init(allocator, "en");
    defer i18n.deinit();
    try i18n.addArb("en", @embedFile("locales/en.arb"), .ltr);
    try i18n.addArb("fr", @embedFile("locales/fr.arb"), .ltr);
    try i18n.addArb("ja", @embedFile("locales/ja.arb"), .ltr);
    try i18n.addArb("ar", @embedFile("locales/ar.arb"), .rtl);
    i18n_mod.setCurrent(i18n); // process-global: the layout reads the direction
    defer i18n_mod.setCurrent(null);
    try i18n.setLocale("en");

    var app = App{
        .allocator = allocator,
        .i18n = i18n,
        .count_sig = try ui.state.Signal(i64).init(allocator, 1),
        .num_sig = try ui.state.Signal([]const u8).init(allocator, try allocator.dupe(u8, "")),
        .date_sig = try ui.state.Signal([]const u8).init(allocator, try allocator.dupe(u8, "")),
        .dir_sig = try ui.state.Signal([]const u8).init(allocator, "LTR"),
        .ctxs = std.array_list.Managed(*LocaleCtx).init(allocator),
    };
    defer {
        allocator.free(app.num_sig.peek());
        allocator.free(app.date_sig.peek());
        app.count_sig.deinit();
        app.num_sig.deinit();
        app.date_sig.deinit();
        app.dir_sig.deinit();
        for (app.ctxs.items) |c| allocator.destroy(c);
        app.ctxs.deinit();
    }

    const root = try buildTree(&app);
    defer root.deinit(); // LIFO: the tree dies before the i18n's strings
    app.root = root;
    i18n.on_direction_changed = .{ .fn_ptr = onDirectionChanged, .userdata = &app };
    i18n.locale_sig.subscribe(.{ .callback = .{ .fn_ptr = recompute, .userdata = &app } });
    recompute(&app); // initial display strings

    root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) });

    std.debug.print("klaxon i18n (Skia {s}) — 4 locales (en/fr/ja/ar), {d}x{d}\n", .{ host.stats.backend, width, height });
    try host.run(root, max_frames, onFrame, &app);
    std.debug.print("rendered {d} frames, last frame {d:.2} ms, done\n", .{ host.stats.frames, host.stats.frame_time_ms });
}

test "demo: the tree lays out and survives locale switches (incl. RTL flip)" {
    var i18n = try i18n_mod.I18n.init(std.testing.allocator, "en");
    defer i18n.deinit();
    try i18n.addArb("en", @embedFile("locales/en.arb"), .ltr);
    try i18n.addArb("fr", @embedFile("locales/fr.arb"), .ltr);
    try i18n.addArb("ja", @embedFile("locales/ja.arb"), .ltr);
    try i18n.addArb("ar", @embedFile("locales/ar.arb"), .rtl);
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    try i18n.setLocale("en");
    var app = App{
        .allocator = std.testing.allocator,
        .i18n = i18n,
        .count_sig = try ui.state.Signal(i64).init(std.testing.allocator, 1),
        .num_sig = try ui.state.Signal([]const u8).init(std.testing.allocator, try std.testing.allocator.dupe(u8, "")),
        .date_sig = try ui.state.Signal([]const u8).init(std.testing.allocator, try std.testing.allocator.dupe(u8, "")),
        .dir_sig = try ui.state.Signal([]const u8).init(std.testing.allocator, "LTR"),
        .ctxs = std.array_list.Managed(*LocaleCtx).init(std.testing.allocator),
    };
    defer {
        std.testing.allocator.free(app.num_sig.peek());
        std.testing.allocator.free(app.date_sig.peek());
        app.count_sig.deinit();
        app.num_sig.deinit();
        app.date_sig.deinit();
        app.dir_sig.deinit();
        for (app.ctxs.items) |c| std.testing.allocator.destroy(c);
        app.ctxs.deinit();
    }
    const root = try buildTree(&app);
    defer root.deinit();
    app.root = root;
    i18n.on_direction_changed = .{ .fn_ptr = onDirectionChanged, .userdata = &app };
    i18n.locale_sig.subscribe(.{ .callback = .{ .fn_ptr = recompute, .userdata = &app } });
    recompute(&app);
    root.layout(.{ .x = 0, .y = 0, .w = 640, .h = 480 });
    // cycle the locales (incl. the RTL flip) and re-layout each time
    inline for (.{ "fr", "ar", "ja", "en" }) |tag| {
        try i18n.setLocale(tag);
        root.layout(.{ .x = 0, .y = 0, .w = 640, .h = 480 });
    }
    try std.testing.expectEqual(i18n_mod.Direction.ltr, i18n.direction());
    try i18n.setLocale("ar");
    try std.testing.expectEqual(i18n_mod.Direction.rtl, i18n.direction());
    root.layout(.{ .x = 0, .y = 0, .w = 640, .h = 480 });
}
