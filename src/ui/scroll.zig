// Scroll — shared scroll state + virtualization math (Phase 1f).
//
// ScrollState: offset clamping against content/viewport sizes. Pure data +
// methods — no node dependency (widgets embed it; node.zig only needs
// ScrollInfo for the scrollable vtable hooks).
//
// visibleRange: the item window a virtualized list/grid keeps alive — the
// items intersecting the viewport ± `margin` on each side. 10k items →
// ~10 live child nodes.
const std = @import("std");

/// Scrollable info — read by the Scrollbar through the vtable hook.
pub const ScrollInfo = struct {
    offset: f32 = 0,
    max_offset: f32 = 0,
    viewport: f32 = 0,
    content: f32 = 0,

    pub fn canScroll(info: ScrollInfo) bool {
        return info.max_offset > 0;
    }

    /// Thumb size as a fraction of the track (viewport / content).
    pub fn thumbFraction(info: ScrollInfo) f32 {
        if (info.content <= 0) return 1;
        return std.math.clamp(info.viewport / info.content, 0.05, 1);
    }
};

pub const ScrollState = struct {
    offset: f32 = 0,
    content: f32 = 0,
    viewport: f32 = 0,

    pub fn maxOffset(s: *const ScrollState) f32 {
        return @max(0, s.content - s.viewport);
    }

    pub fn info(s: *const ScrollState) ScrollInfo {
        return .{
            .offset = s.offset,
            .max_offset = s.maxOffset(),
            .viewport = s.viewport,
            .content = s.content,
        };
    }

    /// Set the offset (clamped to [0, max]). Returns true if it changed.
    pub fn setOffset(s: *ScrollState, value: f32) bool {
        const clamped = std.math.clamp(value, 0, s.maxOffset());
        if (clamped == s.offset) return false;
        s.offset = clamped;
        return true;
    }

    /// Scroll by a delta (clamped). Returns true if the offset changed.
    pub fn scrollBy(s: *ScrollState, dy: f32) bool {
        return s.setOffset(s.offset + dy);
    }
};

/// Half-open item range [first, last).
pub const Range = struct { first: usize, last: usize };

/// The item window a virtualized list keeps alive: items intersecting the
/// viewport ± `margin` items on each side, clamped to [0, item_count].
pub fn visibleRange(item_count: usize, stride: f32, viewport: f32, offset: f32, margin: usize) Range {
    if (item_count == 0 or viewport <= 0 or stride <= 0) return .{ .first = 0, .last = 0 };
    const margin_f: f32 = @floatFromInt(margin);
    const count_f: f32 = @floatFromInt(item_count);
    const first_f = @max(0, @floor(offset / stride) - margin_f);
    const last_f = @min(count_f, @ceil((offset + viewport) / stride) + margin_f);
    const first: usize = @intFromFloat(@max(0, first_f));
    const last: usize = @intFromFloat(@max(@as(f32, @floatFromInt(first)), last_f));
    return .{ .first = first, .last = last };
}

// --- tests ---

test "scroll state: offset clamps to [0, content - viewport]" {
    var s = ScrollState{ .content = 1000, .viewport = 200 };
    try std.testing.expectEqual(@as(f32, 800), s.maxOffset());
    try std.testing.expect(s.setOffset(100));
    try std.testing.expectEqual(@as(f32, 100), s.offset);
    try std.testing.expect(!s.setOffset(100)); // unchanged → false
    try std.testing.expect(s.setOffset(9999)); // clamps to max
    try std.testing.expectEqual(@as(f32, 800), s.offset);
    try std.testing.expect(s.scrollBy(-9999)); // clamps to 0
    try std.testing.expectEqual(@as(f32, 0), s.offset);
    // content smaller than the viewport: no scroll
    var s2 = ScrollState{ .content = 100, .viewport = 200 };
    try std.testing.expectEqual(@as(f32, 0), s2.maxOffset());
    try std.testing.expect(!s2.scrollBy(50));
    try std.testing.expectEqual(@as(f32, 0), s2.offset);
}

test "scroll info: thumb fraction is viewport / content" {
    const info = ScrollInfo{ .offset = 0, .max_offset = 800, .viewport = 200, .content = 1000 };
    try std.testing.expect(info.canScroll());
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), info.thumbFraction(), 1e-6);
    const no_scroll = ScrollInfo{ .max_offset = 0, .viewport = 200, .content = 100 };
    try std.testing.expect(!no_scroll.canScroll());
    try std.testing.expectEqual(@as(f32, 1), no_scroll.thumbFraction());
}

test "visibleRange: viewport ± margin, clamped to the item count" {
    // 10 items of 10px, viewport 25 → items [0, 4) at offset 0 (margin 1)
    const r0 = visibleRange(10, 10, 25, 0, 1);
    try std.testing.expectEqual(@as(usize, 0), r0.first);
    try std.testing.expectEqual(@as(usize, 4), r0.last);
    // offset 55 → first = floor(5.5) - 1 = 4, last = ceil(8) + 1 = 9
    const r1 = visibleRange(10, 10, 25, 55, 1);
    try std.testing.expectEqual(@as(usize, 4), r1.first);
    try std.testing.expectEqual(@as(usize, 9), r1.last);
    // offset past the end clamps to the last items
    const r2 = visibleRange(10, 10, 25, 95, 1);
    try std.testing.expectEqual(@as(usize, 8), r2.first);
    try std.testing.expectEqual(@as(usize, 10), r2.last);
    // degenerate inputs → empty
    try std.testing.expectEqual(Range{ .first = 0, .last = 0 }, visibleRange(0, 10, 25, 0, 1));
    try std.testing.expectEqual(Range{ .first = 0, .last = 0 }, visibleRange(10, 10, 0, 0, 1));
    // 10k items, 200px viewport of 48px items: ~9 live items (margin 2)
    const r3 = visibleRange(10_000, 48, 200, 0, 2);
    try std.testing.expect(r3.last - r3.first <= 10);
}
