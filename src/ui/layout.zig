// Layout — constraints and two-pass layout algorithms (measure → layout).
// Widgets plug in through node.zig's VTable; the algorithms here are the
// reusable core shared by every layout widget (Row, Column, Stack, Grid, ...).
const std = @import("std");
const node_mod = @import("node.zig");
const i18n_mod = @import("i18n.zig");

const Node = node_mod.Node;
const Rect = node_mod.Rect;

/// Text direction (re-exported from ui/i18n.zig — the layout layer mirrors
/// against it, Phase 2b.2).
pub const Direction = i18n_mod.Direction;

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

    /// Shrink the constraints by per-side insets (EdgeInsets).
    pub fn deflateEdge(c: Constraints, e: EdgeInsets) Constraints {
        return .{
            .min_w = @max(0, c.min_w - e.hSum()),
            .max_w = @max(0, c.max_w - e.hSum()),
            .min_h = @max(0, c.min_h - e.vSum()),
            .max_h = @max(0, c.max_h - e.vSum()),
        };
    }

    /// Apply additional constraints on top of these (ConstrainedBox), Flutter's
    /// BoxConstraints.enforce semantics: each additional limit is clamped into
    /// the incoming range, so the result is always valid (min <= max) even when
    /// the additional limits do not intersect the incoming ones.
    pub fn enforcedBy(c: Constraints, add: Constraints) Constraints {
        return .{
            .min_w = std.math.clamp(add.min_w, c.min_w, c.max_w),
            .max_w = std.math.clamp(add.max_w, c.min_w, c.max_w),
            .min_h = std.math.clamp(add.min_h, c.min_h, c.max_h),
            .max_h = std.math.clamp(add.max_h, c.min_h, c.max_h),
        };
    }

    /// Loosen the main axis (children may take any size along it).
    pub fn loosenMain(c: Constraints, axis: Axis) Constraints {
        return switch (axis) {
            .horizontal => .{ .min_w = 0, .max_w = c.max_w, .min_h = c.min_h, .max_h = c.max_h },
            .vertical => .{ .min_w = c.min_w, .max_w = c.max_w, .min_h = 0, .max_h = c.max_h },
        };
    }

    /// Loosen both axes.
    pub fn loosen(c: Constraints) Constraints {
        return .{ .min_w = 0, .max_w = c.max_w, .min_h = 0, .max_h = c.max_h };
    }
};

/// Insets on the four sides (Flutter's EdgeInsets).
pub const EdgeInsets = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub fn all(v: f32) EdgeInsets {
        return .{ .left = v, .top = v, .right = v, .bottom = v };
    }

    pub fn symmetric(horizontal: f32, vertical: f32) EdgeInsets {
        return .{ .left = horizontal, .right = horizontal, .top = vertical, .bottom = vertical };
    }

    pub fn hSum(e: EdgeInsets) f32 {
        return e.left + e.right;
    }

    pub fn vSum(e: EdgeInsets) f32 {
        return e.top + e.bottom;
    }
};

/// Directional insets (Flutter's EdgeInsetsDirectional): start/end resolve
/// against the text direction (start = left in LTR, right in RTL). Phase 2b.2.
pub const EdgeInsetsDirectional = struct {
    start: f32 = 0,
    end: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,

    pub fn all(v: f32) EdgeInsetsDirectional {
        return .{ .start = v, .end = v, .top = v, .bottom = v };
    }

    pub fn resolve(e: EdgeInsetsDirectional, dir: Direction) EdgeInsets {
        return switch (dir) {
            .ltr => .{ .left = e.start, .right = e.end, .top = e.top, .bottom = e.bottom },
            .rtl => .{ .left = e.end, .right = e.start, .top = e.top, .bottom = e.bottom },
        };
    }
};

/// Main-axis alignment inside a flex container (Row/Column).
pub const MainAlign = enum { start, center, end, space_between, space_around, space_evenly };

/// Cross-axis alignment inside a flex container (Row/Column).
pub const CrossAlign = enum { start, center, end, stretch };

/// Horizontal text alignment (Text). `start`/`end` resolve against the
/// current text direction (start = left in LTR, right in RTL).
pub const TextAlign = enum { left, center, right, start, end };

/// Resolve a directional text alignment against the text direction.
pub fn resolveAlign(a: TextAlign, dir: Direction) TextAlign {
    return switch (a) {
        .start => if (dir == .rtl) .right else .left,
        .end => if (dir == .rtl) .left else .right,
        else => a,
    };
}

/// 9-point alignment: x/y in [-1, 1] (-1 = top/left, 0 = center, +1 = bottom/right).
pub const Alignment = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const top_left = Alignment{ .x = -1, .y = -1 };
    pub const top_center = Alignment{ .x = 0, .y = -1 };
    pub const top_right = Alignment{ .x = 1, .y = -1 };
    pub const center_left = Alignment{ .x = -1, .y = 0 };
    pub const center = Alignment{ .x = 0, .y = 0 };
    pub const center_right = Alignment{ .x = 1, .y = 0 };
    pub const bottom_left = Alignment{ .x = -1, .y = 1 };
    pub const bottom_center = Alignment{ .x = 0, .y = 1 };
    pub const bottom_right = Alignment{ .x = 1, .y = 1 };

    /// Rect for a child of size `s` placed inside `bounds` per this alignment.
    pub fn position(a: Alignment, bounds: Rect, s: Size) Rect {
        return .{
            .x = bounds.x + (bounds.w - s.w) * (a.x + 1) / 2,
            .y = bounds.y + (bounds.h - s.h) * (a.y + 1) / 2,
            .w = s.w,
            .h = s.h,
        };
    }

    /// Mirror the horizontal component for RTL (left ↔ right). Vertical
    /// alignment is unaffected.
    pub fn mirrored(a: Alignment, dir: Direction) Alignment {
        return switch (dir) {
            .ltr => a,
            .rtl => .{ .x = -a.x, .y = a.y },
        };
    }
};

// --- Flex (Row / Column) ---

/// Measure pass for a flex container: children are measured with a loosened main
/// axis; the container's main size is the sum (+ gaps + padding), the cross size
/// is the max child cross size (+ padding).
pub fn flexMeasure(node: *Node, c: Constraints, axis: Axis, gap: f32, padding: f32) Size {
    const inner = c.deflate(padding * 2);
    const gaps: f32 = if (node.children.items.len > 1)
        gap * @as(f32, @floatFromInt(node.children.items.len - 1))
    else
        0;
    var main_total: f32 = 0;
    var cross_max: f32 = 0;
    var flex_total: u32 = 0;
    var non_flex_main: f32 = 0;
    for (node.children.items) |child| {
        if (child.flex > 0) {
            flex_total += child.flex;
            continue;
        }
        const size = child.measure(inner.loosenMain(axis));
        non_flex_main += size.main(axis);
        cross_max = @max(cross_max, size.cross(axis));
    }
    // Flex children (Expanded) share the remaining main space, tight, by
    // weight. On an unbounded main axis they keep their natural size.
    const inner_main_max: f32 = switch (axis) {
        .horizontal => inner.max_w,
        .vertical => inner.max_h,
    };
    if (flex_total > 0 and std.math.isFinite(inner_main_max)) {
        const remaining = @max(0, inner_main_max - non_flex_main - gaps);
        for (node.children.items) |child| {
            if (child.flex == 0) continue;
            const alloc = remaining * @as(f32, @floatFromInt(child.flex)) / @as(f32, @floatFromInt(flex_total));
            const child_c = switch (axis) {
                .horizontal => Constraints{ .min_w = alloc, .max_w = alloc, .max_h = inner.max_h },
                .vertical => Constraints{ .min_h = alloc, .max_h = alloc, .max_w = inner.max_w },
            };
            const size = child.measure(child_c);
            main_total += alloc;
            cross_max = @max(cross_max, size.cross(axis));
        }
    } else {
        for (node.children.items) |child| {
            if (child.flex == 0) continue;
            const size = child.measure(inner.loosenMain(axis));
            main_total += size.main(axis);
            cross_max = @max(cross_max, size.cross(axis));
        }
    }
    main_total += non_flex_main + gaps;
    return c.constrain(Size.fromMainCross(axis, main_total + padding * 2, cross_max + padding * 2));
}

/// Layout pass for a flex container: children are measured, then placed along
/// the main axis (gap + padding, free space distributed per `main_align`) and
/// positioned on the cross axis per `cross_align` (default: stretch).
/// Children are sized by their measure pass; the container never clips (P0).
pub fn flexLayout(
    node: *Node,
    bounds: Rect,
    axis: Axis,
    gap: f32,
    padding: f32,
    main_align: MainAlign,
    cross_align: CrossAlign,
) void {
    const n = node.children.items.len;
    if (n == 0) return;
    // Scratch for child sizes: stack for the common case, heap only for
    // containers with > 32 children (keeps allocs_per_frame = 0 in practice).
    var stack_buf: [32]Size = undefined;
    const sizes: []Size = if (n <= stack_buf.len)
        stack_buf[0..n]
    else
        node.allocator.alloc(Size, n) catch @panic("klaxon: out of memory");
    defer if (n > stack_buf.len) node.allocator.free(sizes);

    const inner_main = @max(0, bounds.main(axis) - padding * 2);
    const cross_avail = @max(0, bounds.cross(axis) - padding * 2);

    // Pass 1: measure every child. Non-flex children get the full inner main
    // axis; flex children (Expanded) share the REMAINING main space, tight,
    // by weight (natural size on an unbounded main axis).
    var natural_main: f32 = padding * 2;
    var flex_total: u32 = 0;
    var non_flex_main: f32 = 0;
    const gaps_total: f32 = if (n > 1) gap * @as(f32, @floatFromInt(n - 1)) else 0;
    for (node.children.items, 0..) |child, i| {
        if (child.flex > 0) {
            flex_total += child.flex;
            continue;
        }
        const child_c = switch (axis) {
            .horizontal => Constraints{ .max_w = inner_main, .max_h = cross_avail },
            .vertical => Constraints{ .max_w = cross_avail, .max_h = inner_main },
        };
        sizes[i] = child.measure(child_c);
        non_flex_main += sizes[i].main(axis);
    }
    const remaining = @max(0, inner_main - non_flex_main - gaps_total);
    for (node.children.items, 0..) |child, i| {
        if (child.flex == 0) continue;
        if (flex_total > 0 and std.math.isFinite(inner_main)) {
            const alloc = remaining * @as(f32, @floatFromInt(child.flex)) / @as(f32, @floatFromInt(flex_total));
            const child_c = switch (axis) {
                .horizontal => Constraints{ .min_w = alloc, .max_w = alloc, .max_h = cross_avail },
                .vertical => Constraints{ .min_h = alloc, .max_h = alloc, .max_w = cross_avail },
            };
            sizes[i] = child.measure(child_c);
        } else {
            const child_c = switch (axis) {
                .horizontal => Constraints{ .max_w = inner_main, .max_h = cross_avail },
                .vertical => Constraints{ .max_w = cross_avail, .max_h = inner_main },
            };
            sizes[i] = child.measure(child_c);
        }
    }
    for (sizes) |s| natural_main += s.main(axis);
    natural_main += gaps_total;

    // Free space distribution along the main axis.
    const free = @max(0, bounds.main(axis) - natural_main);
    var start: f32 = padding;
    var extra_gap: f32 = 0;
    switch (main_align) {
        .start => {},
        .center => start += free / 2,
        .end => start += free,
        .space_between => {
            if (n > 1) extra_gap = free / @as(f32, @floatFromInt(n - 1));
        },
        .space_around => {
            const nf: f32 = @floatFromInt(n);
            start += free / (2 * nf);
            extra_gap = free / nf;
        },
        .space_evenly => {
            const nf: f32 = @floatFromInt(n + 1);
            start += free / nf;
            extra_gap = free / nf;
        },
    }

    // Pass 2: place children.
    const rtl = axis == .horizontal and i18n_mod.direction() == .rtl;
    var cursor = start;
    for (node.children.items, 0..) |child, i| {
        const s = sizes[i];
        const cross_pos: f32 = switch (cross_align) {
            .start, .stretch => padding,
            .center => padding + (cross_avail - s.cross(axis)) / 2,
            .end => padding + (cross_avail - s.cross(axis)),
        };
        const cross_size: f32 = if (cross_align == .stretch)
            cross_avail
        else
            @min(s.cross(axis), cross_avail);
        // RTL mirrors the horizontal main axis: the logical order runs
        // right → left (the cursor math — gaps, padding, free space — is
        // direction-agnostic, so mirroring the position is exact).
        const main_pos: f32 = if (rtl) bounds.w - cursor - s.w else cursor;
        const child_bounds = switch (axis) {
            .horizontal => Rect{ .x = bounds.x + main_pos, .y = bounds.y + cross_pos, .w = s.w, .h = cross_size },
            .vertical => Rect{ .x = bounds.x + cross_pos, .y = bounds.y + cursor, .w = cross_size, .h = s.h },
        };
        child.layout(child_bounds);
        cursor += s.main(axis) + gap + extra_gap;
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

test "edge insets sums" {
    const e = EdgeInsets{ .left = 2, .top = 4, .right = 6, .bottom = 8 };
    try std.testing.expectEqual(@as(f32, 8), e.hSum());
    try std.testing.expectEqual(@as(f32, 12), e.vSum());
    try std.testing.expectEqual(@as(f32, 10), EdgeInsets.all(5).hSum());
    try std.testing.expectEqual(@as(f32, 18), EdgeInsets.symmetric(3, 9).vSum()); // 9 + 9
    try std.testing.expectEqual(@as(f32, 6), EdgeInsets.symmetric(3, 9).hSum()); // 3 + 3
}

test "constraints deflateEdge shrinks per side" {
    const c = (Constraints{ .min_w = 10, .max_w = 100, .min_h = 10, .max_h = 100 })
        .deflateEdge(.{ .left = 2, .top = 4, .right = 6, .bottom = 8 });
    try std.testing.expectEqual(@as(f32, 2), c.min_w); // 10 - 8
    try std.testing.expectEqual(@as(f32, 92), c.max_w); // 100 - 8
    try std.testing.expectEqual(@as(f32, 0), c.min_h); // 10 - 12 → clamped to 0
    try std.testing.expectEqual(@as(f32, 88), c.max_h); // 100 - 12
}

test "constraints enforcedBy intersects with additional constraints" {
    const c = Constraints{ .min_w = 10, .max_w = 100, .min_h = 0, .max_h = 50 };
    const e = c.enforcedBy(.{ .min_w = 40, .max_w = 60, .min_h = 5, .max_h = 200 });
    try std.testing.expectEqual(@as(f32, 40), e.min_w);
    try std.testing.expectEqual(@as(f32, 60), e.max_w);
    try std.testing.expectEqual(@as(f32, 5), e.min_h);
    try std.testing.expectEqual(@as(f32, 50), e.max_h);
}

test "constraints enforcedBy clamps non-intersecting limits into range" {
    // Parent allows at most 50 wide; the additional constraints request 80+.
    const c = Constraints{ .max_w = 50, .max_h = 50 };
    const e = c.enforcedBy(.{ .min_w = 80, .min_h = 80 });
    try std.testing.expectEqual(@as(f32, 50), e.min_w); // clamped to the parent's max
    try std.testing.expectEqual(@as(f32, 50), e.max_w);
    try std.testing.expectEqual(@as(f32, 50), e.min_h);
    try std.testing.expectEqual(@as(f32, 50), e.max_h);
    try std.testing.expect(e.min_w <= e.max_w); // always a valid range
    try std.testing.expect(e.min_h <= e.max_h);
}

test "constraints loosen zeroes the minimums" {
    const c = (Constraints{ .min_w = 10, .max_w = 100, .min_h = 20, .max_h = 50 }).loosen();
    try std.testing.expectEqual(@as(f32, 0), c.min_w);
    try std.testing.expectEqual(@as(f32, 100), c.max_w);
    try std.testing.expectEqual(@as(f32, 0), c.min_h);
    try std.testing.expectEqual(@as(f32, 50), c.max_h);
}

test "text align start/end resolve against the direction" {
    try std.testing.expectEqual(TextAlign.left, resolveAlign(.start, .ltr));
    try std.testing.expectEqual(TextAlign.right, resolveAlign(.start, .rtl));
    try std.testing.expectEqual(TextAlign.right, resolveAlign(.end, .ltr));
    try std.testing.expectEqual(TextAlign.left, resolveAlign(.end, .rtl));
    try std.testing.expectEqual(TextAlign.center, resolveAlign(.center, .rtl));
    try std.testing.expectEqual(TextAlign.left, resolveAlign(.left, .rtl)); // absolute stays
}

test "edge insets directional resolve start/end per direction" {
    const e = EdgeInsetsDirectional{ .start = 2, .end = 6, .top = 4, .bottom = 8 };
    const ltr = e.resolve(.ltr);
    try std.testing.expectEqual(@as(f32, 2), ltr.left);
    try std.testing.expectEqual(@as(f32, 6), ltr.right);
    const rtl = e.resolve(.rtl);
    try std.testing.expectEqual(@as(f32, 6), rtl.left);
    try std.testing.expectEqual(@as(f32, 2), rtl.right);
    try std.testing.expectEqual(@as(f32, 4), rtl.top);
}

test "alignment mirrored flips only the horizontal component" {
    const tl = Alignment.top_left.mirrored(.rtl);
    try std.testing.expectEqual(@as(f32, 1), tl.x);
    try std.testing.expectEqual(@as(f32, -1), tl.y);
    const c = Alignment.center.mirrored(.rtl);
    try std.testing.expectEqual(@as(f32, 0), c.x);
    const ltr = Alignment.top_right.mirrored(.ltr);
    try std.testing.expectEqual(@as(f32, 1), ltr.x);
}

test "alignment position centers a child in bounds" {
    const bounds = Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    const r = Alignment.center.position(bounds, .{ .w = 20, .h = 10 });
    try std.testing.expectEqual(@as(f32, 50), r.x); // 10 + (100-20)/2
    try std.testing.expectEqual(@as(f32, 40), r.y); // 20 + (50-10)/2
    try std.testing.expectEqual(@as(f32, 20), r.w);
    try std.testing.expectEqual(@as(f32, 10), r.h);
    const tl = Alignment.top_left.position(bounds, .{ .w = 20, .h = 10 });
    try std.testing.expectEqual(@as(f32, 10), tl.x);
    try std.testing.expectEqual(@as(f32, 20), tl.y);
    const br = Alignment.bottom_right.position(bounds, .{ .w = 20, .h = 10 });
    try std.testing.expectEqual(@as(f32, 90), br.x);
    try std.testing.expectEqual(@as(f32, 60), br.y);
}
