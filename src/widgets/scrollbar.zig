// Scrollbar (Phase 1f) — draggable thumb over a scrollable.
//
// Drives ANY scrollable through the vtable hooks (scroll_info /
// scroll_set_offset) — no direct dependency on ListView/GridView/ScrollView.
// Compose: Row[ ListView, Scrollbar ].
//
// P0: visible while the content overflows (thumb only when scrollable);
// thumb height = viewport/content fraction (min `min_thumb`); dragging the
// thumb maps the pointer position to the scroll offset.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const scroll_mod = @import("../ui/scroll.zig");
const anim = @import("../ui/anim.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;

fn stateOf(comptime T: type, n: *Node) *T {
    return @ptrCast(@alignCast(n.state.?));
}

pub const ScrollbarOptions = struct {
    scroll: *Node, // the scrollable (vtable hooks drive it)
    width: f32 = 8,
    track_color: Color = 0x1A1A1AFF, // subtle track
    thumb_color: Color = 0x80808080,
    min_thumb: f32 = 24, // minimum thumb height (px)
};

const ScrollbarState = struct {
    opts: ScrollbarOptions,
    node: *Node,
    dragging: bool = false,
    /// Last offset seen by the tracker ticker — the thumb follows the
    /// scrollable's offset changes even when the scrollable (a sibling)
    /// is the only node whose damage region is repainted.
    last_offset: f32 = -1,
    ticker: ?anim.Timeline.Ticker = null,
};

/// Timeline ticker: mark the scrollbar dirty when the scroll offset moved
/// (wheel / list-drag scroll the list without touching the scrollbar's
/// damage region — the sibling must repaint its thumb).
fn sbTickCb(userdata: ?*anyopaque, now_ms: u64) void {
    _ = now_ms;
    const s: *ScrollbarState = @ptrCast(@alignCast(userdata.?));
    const info = s.opts.scroll.vtable.scroll_info.?(s.opts.scroll);
    if (info.offset != s.last_offset) {
        s.last_offset = info.offset;
        s.node.markDirty();
    }
}

fn thumbRect(s: *const ScrollbarState, b: Rect) Rect {
    const info = s.opts.scroll.vtable.scroll_info.?(s.opts.scroll);
    const track_h = b.h;
    var thumb_h = track_h * info.thumbFraction();
    thumb_h = @max(thumb_h, @min(s.opts.min_thumb, track_h));
    const max_offset = info.max_offset;
    const frac = if (max_offset > 0) info.offset / max_offset else 0;
    const thumb_y = b.y + frac * (track_h - thumb_h);
    return .{ .x = b.x, .y = thumb_y, .w = b.w, .h = thumb_h };
}

fn scrollbarMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(ScrollbarState, n);
    return c.constrain(.{ .w = s.opts.width, .h = c.max_h });
}
fn scrollbarLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn scrollbarPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(ScrollbarState, n);
    const b = n.bounds;
    const info = s.opts.scroll.vtable.scroll_info.?(s.opts.scroll);
    if (!info.canScroll()) return; // nothing to scroll: no thumb
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, s.opts.track_color);
    const t = thumbRect(s, b);
    ui.paint.fillRRect(ctx, t.x, t.y, t.w, t.h, t.w / 2, s.opts.thumb_color);
}
fn scrollbarOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(ScrollbarState, n);
    const b = n.bounds;
    const scroll = s.opts.scroll;
    switch (ev.phase) {
        .down => {
            const t = thumbRect(s, b);
            if (t.contains(ev.x, ev.y)) {
                s.dragging = true;
                return true;
            }
            // Click on the track: page toward the click (P0: jump to it).
            if (b.contains(ev.x, ev.y)) {
                const info = scroll.vtable.scroll_info.?(scroll);
                const max_offset = info.max_offset;
                if (max_offset > 0) {
                    const frac = std.math.clamp((ev.y - b.y) / b.h, 0, 1);
                    scroll.vtable.scroll_set_offset.?(scroll, frac * max_offset);
                }
                return true;
            }
            return false;
        },
        .move => {
            if (!s.dragging) return false;
            const info = scroll.vtable.scroll_info.?(scroll);
            const t = thumbRect(s, b);
            const max_offset = info.max_offset;
            if (max_offset <= 0) return false;
            const usable = b.h - t.h;
            if (usable <= 0) return false;
            const frac = std.math.clamp((ev.y - b.y - t.h / 2) / usable, 0, 1);
            scroll.vtable.scroll_set_offset.?(scroll, frac * max_offset);
            return true;
        },
        .up, .outside_down => {
            s.dragging = false;
            return false;
        },
        else => return false,
    }
}
fn scrollbarDeinit(n: *Node) void {
    const s = stateOf(ScrollbarState, n);
    if (s.ticker) |t| {
        if (anim.timeline()) |tl| tl.removeTicker(t);
    }
    input.releaseNode(n);
    n.allocator.destroy(s);
}
const scrollbar_vtable = ui.node.VTable{
    .measure = scrollbarMeasure,
    .layout = scrollbarLayout,
    .paint = scrollbarPaint,
    .deinit = scrollbarDeinit,
    .on_pointer = scrollbarOnPointer,
};

pub fn scrollbar(allocator: std.mem.Allocator, opts: ScrollbarOptions) !*Node {
    const node = try Node.create(allocator, &scrollbar_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(ScrollbarState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .node = node };
    // Track the scrollable's offset: the thumb repaints when it moves.
    // (The scrollbar must not outlive its scrollable — the ticker borrows it,
    // same convention as the dropdown's borrowed menu-item labels.)
    if (anim.timeline()) |tl| {
        const t = anim.Timeline.Ticker{ .fn_ptr = sbTickCb, .userdata = s };
        tl.addTicker(t);
        s.ticker = t;
    }
    node.state = s;
    return node;
}

// --- tests ---

const test_factory = @import("list_view.zig").ItemFactory{ .fn_ptr = testItem, .userdata = null };

fn testItem(userdata: ?*anyopaque, index: usize) *Node {
    _ = userdata;
    _ = index;
    return golden.solidBox(std.testing.allocator, 100, 48, 0x3B5BDBFF) catch @panic("klaxon: out of memory");
}

fn testList() !*Node {
    const list_mod = @import("list_view.zig");
    return list_mod.listView(std.testing.allocator, .{
        .item_count = 100, // content 4800
        .factory = test_factory,
        .item_height = 48,
    });
}

test "scrollbar: thumb geometry follows the scroll position" {
    const list = try testList();
    defer list.deinit();
    const sb = try scrollbar(std.testing.allocator, .{ .scroll = list, .width = 8 });
    defer sb.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    sb.layout(.{ .x = 100, .y = 0, .w = 8, .h = 200 });
    // content 4800, viewport 200 → thumb = 200 * 200/4800 ≈ 8.3 → min_thumb 24
    const s = stateOf(ScrollbarState, sb);
    var t = thumbRect(s, sb.bounds);
    try std.testing.expectEqual(@as(f32, 24), t.h);
    try std.testing.expectEqual(@as(f32, 0), t.y);
    // scrolled to the middle: thumb centered
    const list_mod = @import("list_view.zig");
    _ = list_mod.setScrollOffset(list, 2300); // max = 4600 → frac 0.5
    t = thumbRect(s, sb.bounds);
    try std.testing.expectApproxEqAbs(@as(f32, 88), t.y, 1); // (200-24)/2
}

test "scrollbar: dragging the thumb scrolls the list" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const list = try testList();
    defer list.deinit();
    const sb = try scrollbar(std.testing.allocator, .{ .scroll = list, .width = 8 });
    defer sb.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    sb.layout(.{ .x = 100, .y = 0, .w = 8, .h = 200 });
    // grab the thumb (at the top) and drag to the middle of the track
    router.dispatchPointer(sb, .{ .phase = .down, .x = 104, .y = 10 });
    router.dispatchPointer(sb, .{ .phase = .move, .x = 104, .y = 100 });
    const list_mod = @import("list_view.zig");
    const off = list_mod.scrollOffset(list);
    try std.testing.expect(off > 2000 and off < 2600); // ~half of max 4600
    router.dispatchPointer(sb, .{ .phase = .up, .x = 104, .y = 100 });
    // after release, moves no longer scroll
    router.dispatchPointer(sb, .{ .phase = .move, .x = 104, .y = 10 });
    try std.testing.expectEqual(off, list_mod.scrollOffset(list));
}

test "scrollbar: the thumb follows external scrolls (ticker)" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const list = try testList();
    defer list.deinit();
    const sb = try scrollbar(std.testing.allocator, .{ .scroll = list, .width = 8 });
    defer sb.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    sb.layout(.{ .x = 100, .y = 0, .w = 8, .h = 200 });
    const list_mod = @import("list_view.zig");
    _ = list_mod.setScrollOffset(list, 1000); // external scroll (wheel path)
    sb.dirty = false;
    tl.tick(0); // the tracker notices the offset change → thumb repaints
    try std.testing.expect(sb.dirty);
}

test "golden: scrollbar paints track + thumb at the scroll position" {
    const bg: Color = 0x000000FF;
    const list = try testList();
    defer list.deinit();
    const track: Color = 0x1A1A1AFF;
    const thumb: Color = 0xFFFFFFFF; // opaque: exact pixel assertions
    const sb = try scrollbar(std.testing.allocator, .{ .scroll = list, .width = 8, .track_color = track, .thumb_color = thumb });
    defer sb.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    sb.layout(.{ .x = 100, .y = 0, .w = 8, .h = 200 });
    var r = try golden.Renderer.init(std.testing.allocator, 108, 200);
    defer r.deinit();
    r.paint(sb, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    // thumb (24px tall) at the top of the track
    try std.testing.expectEqual(thumb, f1.pixelAt(104, 10));
    try std.testing.expectEqual(track, f1.pixelAt(104, 100));
    try std.testing.expectEqual(bg, f1.pixelAt(50, 100)); // outside the scrollbar
    // scrolled halfway: the thumb moves down
    const list_mod = @import("list_view.zig");
    _ = list_mod.setScrollOffset(list, 2300);
    r.paint(sb, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(thumb, f2.pixelAt(104, 100));
    try std.testing.expectEqual(track, f2.pixelAt(104, 10));
}
