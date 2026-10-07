// Icon widget (Phase 1b P0) — a glyph painted from the default font, Flutter's
// IconData model (font + codepoint). The built-in name table uses codepoints
// covered by DejaVu/system fonts; custom icon fonts land with the theme system.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;

pub const IconName = enum {
    play,
    pause,
    stop,
    circle,
    square,
    triangle_right,
    triangle_left,
    triangle_up,
    triangle_down,
    arrow_right,
    arrow_left,
    arrow_up,
    arrow_down,
    chevron_right,
    chevron_left,
    check,
    close,
    menu,
    search,
    star,
    heart,
    plus,
    minus,
    home,
};

/// Unicode codepoint for a built-in icon name (Geometric Shapes / Arrows /
/// Dingbats blocks — covered by DejaVu Sans and the system fonts).
pub fn codepoint(name: IconName) u21 {
    return switch (name) {
        .play => 0x25B6, // ▶
        .pause => 0x275A, // ❚
        .stop => 0x25A0, // ■
        .circle => 0x25CF, // ●
        .square => 0x25A1, // □
        .triangle_right => 0x25B6, // ▶
        .triangle_left => 0x25C0, // ◀
        .triangle_up => 0x25B2, // ▲
        .triangle_down => 0x25BC, // ▼
        .arrow_right => 0x2192, // →
        .arrow_left => 0x2190, // ←
        .arrow_up => 0x2191, // ↑
        .arrow_down => 0x2193, // ↓
        .chevron_right => 0x203A, // ›
        .chevron_left => 0x2039, // ‹
        .check => 0x2713, // ✓
        .close => 0x2715, // ✕
        .menu => 0x2261, // ≡
        .search => 0x2315, // ⌕
        .star => 0x2605, // ★
        .heart => 0x2665, // ♥
        .plus => 0x002B, // +
        .minus => 0x2212, // −
        .home => 0x2302, // ⌂
    };
}

pub const IconOptions = struct {
    size: f32 = 24,
    color: Color = 0x000000FF, // opaque black (0xRRGGBBAA)
};

const IconState = struct {
    glyph: [4]u8, // UTF-8 encoded codepoint
    glyph_len: usize,
    opts: IconOptions,
};

fn iconMeasure(n: *Node, c: Constraints) Size {
    const s: *IconState = @ptrCast(@alignCast(n.state.?));
    return c.constrain(.{ .w = s.opts.size, .h = s.opts.size });
}
fn iconLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn iconPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *IconState = @ptrCast(@alignCast(n.state.?));
    const glyph = s.glyph[0..s.glyph_len :0];
    const m = ui.paint.measureText(glyph, s.opts.size, false);
    // Center the glyph box inside the widget bounds.
    const x = n.bounds.x + (n.bounds.w - m.width) / 2;
    const baseline = n.bounds.y + (n.bounds.h - m.height) / 2 + m.ascent;
    ui.paint.text(ctx, glyph, x, baseline, s.opts.size, false, s.opts.color);
}
fn iconDeinit(n: *Node) void {
    n.allocator.destroy(@as(*IconState, @ptrCast(@alignCast(n.state.?))));
}
const icon_vtable = ui.node.VTable{ .measure = iconMeasure, .layout = iconLayout, .paint = iconPaint, .deinit = iconDeinit };

pub fn icon(allocator: std.mem.Allocator, name: IconName, opts: IconOptions) !*Node {
    const node = try Node.create(allocator, &icon_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(IconState);
    errdefer allocator.destroy(s);
    var buf: [4]u8 = .{ 0, 0, 0, 0 }; // zeroed: buf[len] is the [:0] sentinel
    const len = try std.unicode.utf8Encode(codepoint(name), &buf);
    s.* = .{ .glyph = buf, .glyph_len = len, .opts = opts };
    node.state = s;
    return node;
}

// --- tests ---

test "icon codepoints are stable (golden data)" {
    try std.testing.expectEqual(@as(u21, 0x25CF), codepoint(.circle));
    try std.testing.expectEqual(@as(u21, 0x25A1), codepoint(.square));
    try std.testing.expectEqual(@as(u21, 0x2192), codepoint(.arrow_right));
    try std.testing.expectEqual(@as(u21, 0x2713), codepoint(.check));
}

test "icon measures a square of its size" {
    const ic = try icon(std.testing.allocator, .star, .{ .size = 32 });
    defer ic.deinit();
    const size = ic.measure(.{});
    try std.testing.expectEqual(@as(f32, 32), size.w);
    try std.testing.expectEqual(@as(f32, 32), size.h);
}

test "golden: icon renders ink centered in its bounds" {
    const bg = 0x101010FF;
    const white = 0xFFFFFFFF;
    const root = try icon(std.testing.allocator, .circle, .{ .size = 24, .color = white });
    var frame = try golden.render(std.testing.allocator, root, 64, 64, bg);
    defer frame.deinit();
    // ● (U+25CF) is covered by DejaVu/system fonts: ink must be present,
    // roughly centered in the 64x64 canvas.
    const ink = frame.countNotIn(.{ .x = 16, .y = 16, .w = 32, .h = 32 }, bg);
    try std.testing.expect(ink > 0);
    try std.testing.expectEqual(@as(u64, 0), frame.countNotIn(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, bg));
}
