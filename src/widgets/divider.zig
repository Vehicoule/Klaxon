// Divider widget (Phase 1b P0) — a horizontal or vertical hairline that
// expands along its main axis (Flutter semantics).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;

pub const DividerOptions = struct {
    horizontal: bool = true,
    thickness: f32 = 1,
    color: Color = 0xFF444444,
    indent: f32 = 0,
    end_indent: f32 = 0,
};

const DividerState = struct { opts: DividerOptions };

fn dividerMeasure(n: *Node, c: Constraints) Size {
    const s: *DividerState = @ptrCast(@alignCast(n.state.?));
    if (s.opts.horizontal) {
        return c.constrain(.{
            .w = if (std.math.isFinite(c.max_w)) c.max_w else 0,
            .h = s.opts.thickness,
        });
    }
    return c.constrain(.{
        .w = s.opts.thickness,
        .h = if (std.math.isFinite(c.max_h)) c.max_h else 0,
    });
}
fn dividerLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn dividerPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *DividerState = @ptrCast(@alignCast(n.state.?));
    const b = n.bounds;
    if (s.opts.horizontal) {
        const w = @max(0, b.w - s.opts.indent - s.opts.end_indent);
        ui.paint.fillRect(ctx, b.x + s.opts.indent, b.y + (b.h - s.opts.thickness) / 2, w, s.opts.thickness, s.opts.color);
    } else {
        const h = @max(0, b.h - s.opts.indent - s.opts.end_indent);
        ui.paint.fillRect(ctx, b.x + (b.w - s.opts.thickness) / 2, b.y + s.opts.indent, s.opts.thickness, h, s.opts.color);
    }
}
fn dividerDeinit(n: *Node) void {
    n.allocator.destroy(@as(*DividerState, @ptrCast(@alignCast(n.state.?))));
}
const divider_vtable = ui.node.VTable{ .measure = dividerMeasure, .layout = dividerLayout, .paint = dividerPaint, .deinit = dividerDeinit };

pub fn divider(allocator: std.mem.Allocator, opts: DividerOptions) !*Node {
    const node = try Node.create(allocator, &divider_vtable);
    const s = try allocator.create(DividerState);
    s.* = .{ .opts = opts };
    node.state = s;
    return node;
}

// --- tests ---

test "divider expands along its main axis" {
    const h = try divider(std.testing.allocator, .{ .thickness = 2 });
    defer h.deinit();
    const hs = h.measure(.{ .max_w = 100, .max_h = 50 });
    try std.testing.expectEqual(@as(f32, 100), hs.w);
    try std.testing.expectEqual(@as(f32, 2), hs.h);
    const v = try divider(std.testing.allocator, .{ .horizontal = false, .thickness = 3 });
    defer v.deinit();
    const vs = v.measure(.{ .max_w = 100, .max_h = 50 });
    try std.testing.expectEqual(@as(f32, 3), vs.w);
    try std.testing.expectEqual(@as(f32, 50), vs.h);
}

test "golden: horizontal divider paints an exact line with indents" {
    const bg = 0x101010FF;
    const gray = 0xAAAAAAFF;
    const root = try divider(std.testing.allocator, .{ .thickness = 2, .color = gray, .indent = 10, .end_indent = 20 });
    var frame = try golden.render(std.testing.allocator, root, 100, 20, bg);
    defer frame.deinit();
    // Line: x in [10, 80), thickness 2, vertically centered in the 20px bounds
    // → y in [9, 11).
    try std.testing.expectEqual(@as(u64, 70 * 2), frame.countColor(gray));
    try std.testing.expectEqual(gray, frame.pixelAt(10, 9));
    try std.testing.expectEqual(gray, frame.pixelAt(79, 10));
    try std.testing.expectEqual(bg, frame.pixelAt(9, 9)); // indent
    try std.testing.expectEqual(bg, frame.pixelAt(80, 9)); // end indent
    try std.testing.expectEqual(bg, frame.pixelAt(50, 2)); // above the line
    try std.testing.expectEqual(bg, frame.pixelAt(50, 11)); // below the line
}
