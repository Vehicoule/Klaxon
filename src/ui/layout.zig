// Layout — constraints and two-pass layout algorithms (measure → layout).
// Widgets plug in through node.zig's VTable; the algorithms here are the
// reusable core shared by every layout widget (Row, Column, Stack, Grid, ...).
const std = @import("std");
const node_mod = @import("node.zig");

const Node = node_mod.Node;
const Rect = node_mod.Rect;

pub const Axis = enum { horizontal, vertical };

pub const Size = struct {
    w: f32 = 0,
    h: f32 = 0,

    pub fn main(self: Size, axis: Axis) f32 {
        return switch (axis) {
            .horizontal => self.w,
            .vertical => self.h,
        };
    }

    pub fn cross(self: Size, axis: Axis) f32 {
        return switch (axis) {
            .horizontal => self.h,
            .vertical => self.w,
        };
    }

    pub fn fromMainCross(axis: Axis, main_axis: f32, cross_axis: f32) Size {
        return switch (axis) {
            .horizontal => .{ .w = main_axis, .h = cross_axis },
            .vertical => .{ .w = cross_axis, .h = main_axis },
        };
    }
};

pub const Constraints = struct {
    min_w: f32 = 0,
    max_w: f32 = std.math.inf(f32),
    min_h: f32 = 0,
    max_h: f32 = std.math.inf(f32),

    pub fn constrain(c: Constraints, size: Size) Size {
        return .{
            .w = std.math.clamp(size.w, c.min_w, c.max_w),
            .h = std.math.clamp(size.h, c.min_h, c.max_h),
        };
    }

    /// Shrink the constraints by `amount` on every side (padding).
    pub fn deflate(c: Constraints, amount: f32) Constraints {
        return .{
            .min_w = @max(0, c.min_w - amount),
            .max_w = @max(0, c.max_w - amount),
            .min_h = @max(0, c.min_h - amount),
            .max_h = @max(0, c.max_h - amount),
        };
    }

    /// Loosen the main axis (children may take any size along it).
    pub fn loosenMain(c: Constraints, axis: Axis) Constraints {
        return switch (axis) {
            .horizontal => .{ .min_w = 0, .max_w = c.max_w, .min_h = c.min_h, .max_h = c.max_h },
            .vertical => .{ .min_w = c.min_w, .max_w = c.max_w, .min_h = 0, .max_h = c.max_h },
        };
    }
};

// --- Flex (Row / Column) ---

/// Measure pass for a flex container: children are measured with a loosened main
/// axis; the container's main size is the sum (+ gaps + padding), the cross size
/// is the max child cross size (+ padding).
pub fn flexMeasure(node: *Node, c: Constraints, axis: Axis, gap: f32, padding: f32) Size {
    const inner = c.deflate(padding * 2);
    var main_total: f32 = 0;
    var cross_max: f32 = 0;
    for (node.children.items) |child| {
        const size = child.measure(inner.loosenMain(axis));
        main_total += size.main(axis);
        cross_max = @max(cross_max, size.cross(axis));
    }
    if (node.children.items.len > 1) {
        main_total += gap * @as(f32, @floatFromInt(node.children.items.len - 1));
    }
    return c.constrain(Size.fromMainCross(axis, main_total + padding * 2, cross_max + padding * 2));
}

/// Layout pass for a flex container: children are stacked along the main axis
/// (gap + padding), stretched to the cross size, then recursively laid out.
pub fn flexLayout(node: *Node, bounds: Rect, axis: Axis, gap: f32, padding: f32) void {
    var cursor: f32 = padding;
    const cross_avail = @max(0, bounds.cross(axis) - padding * 2);
    for (node.children.items) |child| {
        const remaining = @max(0, bounds.main(axis) - padding * 2 - cursor);
        const child_c = switch (axis) {
            .horizontal => Constraints{ .max_w = remaining, .max_h = cross_avail },
            .vertical => Constraints{ .max_w = cross_avail, .max_h = remaining },
        };
        const size = child.measure(child_c);
        const child_bounds = switch (axis) {
            .horizontal => Rect{ .x = bounds.x + cursor, .y = bounds.y + padding, .w = size.w, .h = cross_avail },
            .vertical => Rect{ .x = bounds.x + padding, .y = bounds.y + cursor, .w = cross_avail, .h = size.h },
        };
        child.layout(child_bounds);
        cursor += size.main(axis) + gap;
    }
}

test "constraints clamp to min/max" {
    const c = Constraints{ .min_w = 10, .max_w = 100, .min_h = 5, .max_h = 50 };
    const s = c.constrain(.{ .w = 200, .h = 2 });
    try std.testing.expectEqual(@as(f32, 100), s.w);
    try std.testing.expectEqual(@as(f32, 5), s.h);
}

test "constraints deflate shrinks all sides" {
    const c = (Constraints{ .min_w = 10, .max_w = 100, .min_h = 10, .max_h = 100 }).deflate(4);
    try std.testing.expectEqual(@as(f32, 6), c.min_w);
    try std.testing.expectEqual(@as(f32, 96), c.max_w);
}

test "size main/cross by axis" {
    const s = Size{ .w = 30, .h = 40 };
    try std.testing.expectEqual(@as(f32, 30), s.main(.horizontal));
    try std.testing.expectEqual(@as(f32, 40), s.cross(.horizontal));
    try std.testing.expectEqual(@as(f32, 40), s.main(.vertical));
    try std.testing.expectEqual(@as(f32, 30), s.cross(.vertical));
}
