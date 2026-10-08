// Badge (Phase 2d.1 PR B, M3E batch 1) — small dot + large count badge,
// and the BadgedBox that anchors one to a content's top-trailing corner.
//
// Spec: m3.material.io/components/badges + Compose BadgeTokens / Badge.kt:
//   - small badge (no content): 6x6, error color, CornerFull (circle)
//   - large badge (content): error bg, on_error label_small text, CornerFull
//     (pill), min 16x16, horizontal padding 4, max width 34 (max char count)
//   - placement (exact Compose BadgedBox math, RTL-aware via the layout
//     direction): hasContent = badge.w > 6; offsetH = hasContent ? 12 : 6;
//     offsetV = hasContent ? 14 : 6; badgeX = min(anchor.w - offsetH,
//     anchor.w - badge.w); badgeY = max(0, offsetV - badge.h) — the badge
//     overlaps the anchor's top-trailing corner.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const node_mod = ui.node;
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

/// M3E measurement tokens (Compose BadgeTokens + Badge.kt offsets).
const small_size: f32 = 6;
const large_min: f32 = 16;
const large_h_padding: f32 = 4;
const large_max_w: f32 = 34;
const offset_small: f32 = 6; // BadgeOffset
const offset_large_h: f32 = 12; // BadgeWithContentHorizontalOffset
const offset_large_v: f32 = 14; // BadgeWithContentVerticalOffset

pub const BadgeOptions = struct {
    /// null = small dot badge; a label = large pill badge (count).
    label: ?[]const u8 = null,
    theme: Theme = theme_mod.light,
};

const BadgeState = struct {
    opts: BadgeOptions,
};

fn stateOf(n: *Node) *BadgeState {
    return @ptrCast(@alignCast(n.state.?));
}

fn badgeMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    if (s.opts.label == null) return c.constrain(.{ .w = small_size, .h = small_size });
    // large badge: text + horizontal padding, min 16 high (label_small)
    var w: f32 = 0;
    var h: f32 = large_min;
    for (n.children.items) |child| {
        const cs = child.measure(c);
        w = @max(w, cs.w);
        h = @max(h, cs.h);
    }
    w = @min(@max(large_min, w + large_h_padding * 2), large_max_w);
    return c.constrain(.{ .w = w, .h = h });
}

fn badgeLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    if (s.opts.label == null) return; // the dot has no children
    // center the label with the 4dp horizontal padding
    for (n.children.items) |child| {
        const cs = child.measure(.{ .max_w = bounds.w, .max_h = bounds.h });
        child.layout(.{
            .x = bounds.x + (bounds.w - cs.w) / 2,
            .y = bounds.y + (bounds.h - cs.h) / 2,
            .w = cs.w,
            .h = cs.h,
        });
    }
}

fn badgePaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    // CornerFull: radius = half the height (pill / circle)
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, b.h / 2, s.opts.theme.colors.@"error");
}

fn badgeDeinit(n: *Node) void {
    n.allocator.destroy(stateOf(n));
}

const badge_vtable = ui.node.VTable{
    .measure = badgeMeasure,
    .layout = badgeLayout,
    .paint = badgePaint,
    .deinit = badgeDeinit,
};

/// A badge: a 6x6 error dot (label = null) or a large error pill with the
/// label as on_error label_small text.
pub fn badge(allocator: std.mem.Allocator, opts: BadgeOptions) !*Node {
    const node = try Node.create(allocator, &badge_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(BadgeState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts };
    node.state = s;
    if (opts.label) |label| {
        const t = opts.theme;
        node.add(try text_w.text(allocator, label, .{
            .size = t.type_scale.label_small.size,
            .color = t.colors.on_error,
        }));
        ui.semantics.attach(node, .{ .role = .text, .label = label }); // Phase 2c
    }
    return node;
}

// --- BadgedBox ---

pub const BadgedBoxOptions = struct {
    theme: Theme = theme_mod.light,
};

const BadgedBoxState = struct {
    opts: BadgedBoxOptions,
};

fn badgedBoxMeasure(n: *Node, c: Constraints) Size {
    // the box is the content's size — the badge never expands it
    if (n.children.items.len == 0) return c.constrain(.{});
    return n.children.items[0].measure(c);
}

fn badgedBoxLayout(n: *Node, bounds: Rect) void {
    if (n.children.items.len == 0) return;
    const content = n.children.items[0];
    content.layout(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bounds.h });
    if (n.children.items.len < 2) return;
    const b = n.children.items[1];
    const cs = b.measure(.{ .max_w = bounds.w, .max_h = bounds.h });
    const has_content = cs.w > small_size;
    const offset_h: f32 = if (has_content) offset_large_h else offset_small;
    const offset_v: f32 = if (has_content) offset_large_v else offset_small;
    // RTL: the badge anchors to the top-END corner (mirror the LTR x)
    const end = ui.i18n.direction() == .rtl;
    const bx = if (end)
        bounds.x + @max(0, offset_h - cs.w) // leading edge flush on the end side
    else
        bounds.x + @min(bounds.w - offset_h, bounds.w - cs.w);
    const by = bounds.y + @max(0, offset_v - cs.h);
    b.layout(.{ .x = bx, .y = by, .w = cs.w, .h = cs.h });
}

fn badgedBoxDeinit(n: *Node) void {
    n.allocator.destroy(@as(*BadgedBoxState, @ptrCast(@alignCast(n.state.?))));
}

const badged_box_vtable = ui.node.VTable{
    .measure = badgedBoxMeasure,
    .layout = badgedBoxLayout,
    .paint = struct {
        fn p(n: *Node, ctx: *kx.Ctx) void {
            _ = n;
            _ = ctx; // transparent: content + badge children paint
        }
    }.p,
    .deinit = badgedBoxDeinit,
};

/// A box that anchors a badge to its content's top-trailing corner (M3E
/// BadgedBox). `content` is the anchor; `badge_node` is a `badge(...)` node
/// (null = no badge). The badge may paint outside the box's bounds.
pub fn badgedBox(allocator: std.mem.Allocator, content: *Node, badge_node: ?*Node, opts: BadgedBoxOptions) !*Node {
    const node = try Node.create(allocator, &badged_box_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(BadgedBoxState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts };
    node.state = s;
    node.add(content);
    if (badge_node) |b| node.add(b);
    return node;
}

// --- tests ---

const text_w = @import("text.zig");

test "badge: small dot measures 6x6; large pill fits the label + padding" {
    const dot = try badge(std.testing.allocator, .{});
    defer dot.deinit();
    const md = dot.measure(.{ .max_w = 100, .max_h = 100 });
    try std.testing.expectEqual(@as(f32, 6), md.w);
    try std.testing.expectEqual(@as(f32, 6), md.h);
    const big = try badge(std.testing.allocator, .{ .label = "99+" });
    defer big.deinit();
    const mb = big.measure(.{ .max_w = 100, .max_h = 100 });
    try std.testing.expect(mb.w >= large_min);
    try std.testing.expect(mb.h >= large_min);
    try std.testing.expect(mb.w <= large_max_w);
}

test "badged_box: the badge overlaps the content's top-trailing corner" {
    const t = theme_mod.light;
    const content = try golden.solidBox(std.testing.allocator, 24, 24, 0x112233FF);
    const dot = try badge(std.testing.allocator, .{});
    const box = try badgedBox(std.testing.allocator, content, dot, .{});
    defer box.deinit();
    box.layout(.{ .x = 0, .y = 0, .w = 24, .h = 24 });
    // small badge: 6x6 at (24-6, 0) — Compose BadgeOffset math
    try std.testing.expectEqual(@as(f32, 18), dot.bounds.x);
    try std.testing.expectEqual(@as(f32, 0), dot.bounds.y);
    // large badge: trailing edge flush, top flush (16 high)
    const big = try badge(std.testing.allocator, .{ .label = "3" });
    const box2 = try badgedBox(std.testing.allocator, try golden.solidBox(std.testing.allocator, 24, 24, 0x112233FF), big, .{});
    defer box2.deinit();
    box2.layout(.{ .x = 0, .y = 0, .w = 24, .h = 24 });
    try std.testing.expectEqual(@as(f32, 24), big.bounds.x + big.bounds.w); // right edge flush
    try std.testing.expectEqual(@as(f32, 0), big.bounds.y);
    _ = t;
}

test "golden: badge paints the error pill with the on_error label" {
    const t = theme_mod.light;
    const b = try badge(std.testing.allocator, .{ .label = "3", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 40, 24);
    defer r.deinit();
    b.layout(.{ .x = 4, .y = 4, .w = 16, .h = 16 });
    r.paint(b, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the pill is a 16x16 circle (radius = h/2): most of its ~201px is error
    // fill, minus the label ink and the AA edge (loose bound — the ink area
    // is font-dependent; a 6x6 dot would only paint ~28 pure pixels)
    try std.testing.expect(f.countColorIn(.{ .x = 4, .y = 4, .w = 16, .h = 16 }, t.colors.@"error") > 80);
    try std.testing.expectEqual(t.colors.@"error", f.pixelAt(12, 5)); // inside the circle, above the label ink
    // the dot badge is a 6x6 error circle
    const dot = try badge(std.testing.allocator, .{ .theme = t });
    defer dot.deinit();
    dot.layout(.{ .x = 10, .y = 10, .w = 6, .h = 6 });
    r.paint(dot, 0x000000FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(t.colors.@"error", f2.pixelAt(13, 13));
}
