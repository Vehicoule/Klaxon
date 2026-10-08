// App bar widget (Phase 2d.1, M3E batch 1) — small top app bar.
//
// Spec: m3.material.io/components/top-app-bar (M3E) + Compose
// AppBarSmallTokens / matraic m3e-app-bar:
//   - container height 64, container color surface (elevation 0 — the
//     scroll-aware scrim/elevation is a later refinement; v1 keeps the bar
//     fixed, no collapse),
//   - title type style title_large,
//   - horizontal padding 4 (TopAppBarHorizontalPadding); leading icon slot
//     48x48 at start+4; the title starts at 16 without a leading slot and at
//     56 with one (4 + 48 + 4); trailing actions end-inset 4.
//
// The bar owns no interaction: the leading/title/actions slots are ordinary
// widgets (icon buttons, text) with their own semantics. The widget is a
// pure chrome container: measure/layout/paint + a group semantic.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

/// M3E measurement tokens used by the small app bar (Compose
/// TopAppBarHorizontalPadding = 4, TopAppBarTitleInset = 16 - 4 = 12).
const padding_h: f32 = 4;
const title_inset_without_leading: f32 = 12;
const slot_size: f32 = 48;

pub const AppBarOptions = struct {
    theme: Theme = theme_mod.light,
    height: f32 = 64, // M3E small top app bar container height
    leading: ?*Node = null, // 48x48 slot (navigation icon button)
    title: ?*Node = null, // title_large content
    actions: ?*Node = null, // trailing content (a row of icon buttons)
};

const AppBarState = struct { opts: AppBarOptions };

fn stateOf(n: *Node) *AppBarState {
    return @ptrCast(@alignCast(n.state.?));
}

fn appBarMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const loose = c.loosen();
    var content_w: f32 = padding_h * 2;
    if (s.opts.leading) |leading| content_w += @min(slot_size, leading.measure(loose).w);
    if (s.opts.title) |title| content_w += title.measure(loose).w;
    if (s.opts.actions) |actions| content_w += actions.measure(loose).w;
    if (s.opts.leading != null) content_w += padding_h; // gap after the leading slot
    const w = if (std.math.isFinite(c.max_w)) c.max_w else content_w;
    return c.constrain(.{ .w = w, .h = s.opts.height });
}

fn appBarLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    const b = bounds;
    const loose: Constraints = .{ .max_w = b.w, .max_h = b.h };
    var x = b.x + padding_h;
    // Leading slot: 48x48, vertically centered.
    if (s.opts.leading) |leading| {
        const cs = leading.measure(loose);
        const w = @min(slot_size, cs.w);
        const h = @min(slot_size, cs.h);
        leading.layout(.{ .x = x, .y = b.y + (b.h - h) / 2, .w = w, .h = h });
        x += slot_size + padding_h;
    } else {
        x += title_inset_without_leading;
    }
    // Trailing actions: measured width, end-inset 4, vertically centered.
    var actions_w: f32 = 0;
    if (s.opts.actions) |actions| {
        const cs = actions.measure(loose);
        actions_w = cs.w;
        actions.layout(.{ .x = b.x + b.w - padding_h - cs.w, .y = b.y + (b.h - cs.h) / 2, .w = cs.w, .h = cs.h });
    }
    // Title: takes the remaining width, vertically centered.
    if (s.opts.title) |title| {
        const cs = title.measure(loose);
        const w = @max(0, b.x + b.w - padding_h - actions_w - x);
        title.layout(.{ .x = x, .y = b.y + (b.h - cs.h) / 2, .w = w, .h = cs.h });
    }
}

fn appBarPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, s.opts.theme.colors.surface);
}

fn appBarDeinit(n: *Node) void {
    n.allocator.destroy(stateOf(n));
}

const app_bar_vtable = ui.node.VTable{
    .measure = appBarMeasure,
    .layout = appBarLayout,
    .paint = appBarPaint,
    .deinit = appBarDeinit,
};

/// Small top app bar (M3E). Slots: `leading` (navigation icon), `title`,
/// `actions` (trailing). Ownership: the slots are attached as children —
/// the tree owns them.
pub fn appBar(allocator: std.mem.Allocator, opts: AppBarOptions) !*Node {
    const node = try Node.create(allocator, &app_bar_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(AppBarState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts };
    node.state = s;
    if (opts.leading) |leading| node.add(leading);
    if (opts.title) |title| node.add(title);
    if (opts.actions) |actions| node.add(actions);
    ui.semantics.attach(node, .{ .role = .group, .label = "App bar" }); // Phase 2c
    return node;
}

// --- tests ---

test "app_bar: measure fills the width and reports the M3E height" {
    const bar = try appBar(std.testing.allocator, .{});
    defer bar.deinit();
    const m = bar.measure(.{ .max_w = 480, .max_h = 600 });
    try std.testing.expectEqual(@as(f32, 480), m.w);
    try std.testing.expectEqual(@as(f32, 64), m.h);
}

test "app_bar: layout places leading/title/actions per the M3E insets" {
    const text_w = @import("text.zig");
    const leading = try golden.solidBox(std.testing.allocator, 48, 48, 0xFF0000FF);
    const title = try text_w.text(std.testing.allocator, "Title", .{});
    const actions = try golden.solidBox(std.testing.allocator, 96, 48, 0x00FF00FF);
    const bar = try appBar(std.testing.allocator, .{ .leading = leading, .title = title, .actions = actions });
    defer bar.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 480, .h = 64 });
    // leading at start+4, 48x48, vertically centered
    try std.testing.expectEqual(@as(f32, 4), leading.bounds.x);
    try std.testing.expectEqual(@as(f32, 8), leading.bounds.y);
    try std.testing.expectEqual(@as(f32, 48), leading.bounds.w);
    // title at 4 + 48 + 4 = 56
    try std.testing.expectEqual(@as(f32, 56), title.bounds.x);
    // actions end-inset 4: x = 480 - 4 - 96 = 380
    try std.testing.expectEqual(@as(f32, 380), actions.bounds.x);
    try std.testing.expectEqual(@as(f32, 8), actions.bounds.y);
}

test "app_bar: layout without leading insets the title by 16" {
    const text_w = @import("text.zig");
    const title = try text_w.text(std.testing.allocator, "Title", .{});
    const bar = try appBar(std.testing.allocator, .{ .title = title });
    defer bar.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 480, .h = 64 });
    try std.testing.expectEqual(@as(f32, 16), title.bounds.x);
}

test "golden: app_bar paints the M3 surface container" {
    const text_w = @import("text.zig");
    const bar = try appBar(std.testing.allocator, .{ .title = try text_w.text(std.testing.allocator, "Hello", .{ .color = theme_mod.light.colors.on_surface }) });
    defer bar.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 128, 64);
    defer r.deinit();
    bar.layout(.{ .x = 0, .y = 0, .w = 128, .h = 64 });
    r.paint(bar, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const surface = theme_mod.light.colors.surface;
    // the whole bar is the surface color except the text ink
    try std.testing.expect(f.countColor(surface) > 128 * 64 - 800);
    try std.testing.expect(f.countNot(surface) > 0); // the title's ink
}
