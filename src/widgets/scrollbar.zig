// Scrollbar (Phase 1f) — draggable thumb over a scrollable.
//
// Drives ANY scrollable through the vtable hooks (scroll_info /
// scroll_set_offset) — no direct dependency on ListView/GridView/ScrollView.
// Compose: Row[ ListView, Scrollbar ].
//
// P0: visible while the content overflows (thumb only when scrollable);
// thumb height = viewport/content fraction (min `min_thumb`); dragging the
// thumb maps the pointer position to the scroll offset.
//
// Phase 2d-0.5 styles (from theme.platform.scrollbar_style):
//   - classic: permanent track + thumb, takes layout space (GTK-like)
//   - overlay: floats over the content's right edge (no layout space, no
//     track), shows on scroll/hover/drag, fades out after an idle delay
//     (macOS-like)
//   - auto_hide: takes layout space (track + thumb), hidden at rest, shows
//     on scroll/hover/drag (Windows-like)
//
// Fill semantics: natural height = max_h (like the scrollables). Inside a
// vertically unbounded container (e.g. a ScrollView's content) it measures
// infinity — bound it with a ConstrainedBox, same as the scrollable.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const scroll_mod = @import("../ui/scroll.zig");
const anim = @import("../ui/anim.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

fn stateOf(comptime T: type, n: *Node) *T {
    return @ptrCast(@alignCast(n.state.?));
}

/// Idle delay before an overlay/auto_hide scrollbar fades out (macOS ~1s).
const hide_delay_ms: u64 = 800;
/// Show/hide fade duration.
const fade_ms: u32 = 150;

pub const ScrollbarOptions = struct {
    scroll: *Node, // the scrollable (vtable hooks drive it)
    width: ?f32 = null, // null → theme.platform.scrollbar_width
    track_color: Color = 0x1A1A1AFF, // subtle track
    thumb_color: Color = 0x80808080,
    min_thumb: f32 = 24, // minimum thumb height (px)
    theme: Theme = theme_mod.light,
};

fn styleOfOpts(opts: ScrollbarOptions) theme_mod.ScrollbarStyle {
    return opts.theme.platform.scrollbar_style;
}

const ScrollbarState = struct {
    opts: ScrollbarOptions,
    node: *Node,
    dragging: bool = false,
    /// Last offset seen by the tracker ticker — the thumb follows the
    /// scrollable's offset changes even when the scrollable (a sibling)
    /// is the only node whose damage region is repainted.
    last_offset: f32 = -1,
    ticker: ?anim.Timeline.Ticker = null,
    // show/hide (overlay + auto_hide): scroll activity / hover / drag show
    // the scrollbar; an idle delay fades it out (classic: always shown)
    shown: bool = false,
    hovering: bool = false, // the pointer rests on the scrollbar: no idle hide
    alpha: f32 = 0,
    anim_to: f32 = 0,
    hide_deadline: ?u64 = null,
    anim_channel: u8 = 0,
};

fn styleOf(s: *const ScrollbarState) theme_mod.ScrollbarStyle {
    return styleOfOpts(s.opts);
}
fn widthOf(s: *const ScrollbarState) f32 {
    return s.opts.width orelse s.opts.theme.platform.scrollbar_width;
}

/// The track rect in parent space: the node's bounds (classic/auto_hide) or
/// the parent's right edge (overlay — the scrollbar floats over the content
/// and takes no layout space).
fn trackRect(s: *const ScrollbarState, n: *Node) Rect {
    if (styleOf(s) != .overlay) return n.bounds;
    const p = n.parent orelse return n.bounds;
    const pb = p.bounds;
    const w = widthOf(s);
    return .{ .x = pb.x + pb.w - w, .y = pb.y, .w = w, .h = pb.h };
}

fn scrollbarHitBounds(n: *Node) Rect {
    const s = stateOf(ScrollbarState, n);
    // nothing to scroll: an empty hit zone — the overlay never intercepts
    // the content's clicks
    if (!s.opts.scroll.vtable.scroll_info.?(s.opts.scroll).canScroll()) return .{};
    return trackRect(s, n);
}

/// Damage for a show/hide/offset change: the overlay node measures zero
/// width, so its own bounds would be discarded by the damage union — dirty
/// the track rect (parent space) instead.
fn damageSb(s: *ScrollbarState) void {
    if (styleOf(s) == .overlay) {
        s.node.markDirtyRect(trackRect(s, s.node));
    } else {
        s.node.markDirty();
    }
}

/// Wheel over the overlay strip: the wheel bubbles to ancestors only, so
/// forward it to the scrollable (the strip floats over the content).
fn scrollbarOnScroll(n: *Node, ev: input.ScrollEvent) bool {
    const s = stateOf(ScrollbarState, n);
    const scroll = s.opts.scroll;
    if (scroll.vtable.on_scroll) |h| return h(scroll, ev);
    return false;
}

/// Timeline ticker: mark the scrollbar dirty when the scroll offset moved
/// (wheel / list-drag scroll the list without touching the scrollbar's
/// damage region — the sibling must repaint its thumb). For overlay /
/// auto_hide styles it also shows the scrollbar on scroll activity and
/// fires the idle hide timer.
fn sbTickCb(userdata: ?*anyopaque, now_ms: u64) void {
    const s: *ScrollbarState = @ptrCast(@alignCast(userdata.?));
    const info = s.opts.scroll.vtable.scroll_info.?(s.opts.scroll);
    if (info.offset != s.last_offset) {
        s.last_offset = info.offset;
        damageSb(s);
        if (styleOf(s) != .classic) showSb(s, now_ms); // scroll activity shows it
    }
    // the idle hide timer (overlay/auto_hide) — suppressed while hovered
    if (s.hide_deadline) |dl| {
        if (!s.hovering and now_ms >= dl) {
            s.hide_deadline = null;
            hideSb(s);
        }
    }
}

/// The host wakes at the hide deadline even at true idle (the timeout fires
/// without user input).
fn sbHasPendingCb(userdata: ?*anyopaque) bool {
    const s: *ScrollbarState = @ptrCast(@alignCast(userdata.?));
    if (styleOf(s) == .classic) return false;
    return s.hide_deadline != null;
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
    // overlay floats over the content: no layout space
    const w: f32 = if (styleOf(s) == .overlay) 0 else widthOf(s);
    return c.constrain(.{ .w = w, .h = c.max_h });
}
fn scrollbarLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn scrollbarPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(ScrollbarState, n);
    const info = s.opts.scroll.vtable.scroll_info.?(s.opts.scroll);
    if (!info.canScroll()) return; // nothing to scroll: no thumb
    const style = styleOf(s);
    if (style == .classic) {
        const b = n.bounds;
        ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, s.opts.track_color);
        const t = thumbRect(s, b);
        ui.paint.fillRRect(ctx, t.x, t.y, t.w, t.h, t.w / 2, s.opts.thumb_color);
        return;
    }
    if (s.alpha <= 0) return; // hidden at rest
    const b = trackRect(s, n);
    if (style == .auto_hide) {
        ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, ui.paint.withAlphaScaled(s.opts.track_color, s.alpha));
    }
    // overlay: no track, the thumb floats with a 2px horizontal inset
    var t = thumbRect(s, b);
    if (style == .overlay) {
        t.x += 2;
        t.w = @max(0, t.w - 4);
    }
    ui.paint.fillRRect(ctx, t.x, t.y, t.w, t.h, t.w / 2, ui.paint.withAlphaScaled(s.opts.thumb_color, s.alpha));
}
fn scrollbarOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(ScrollbarState, n);
    const b = trackRect(s, n);
    const scroll = s.opts.scroll;
    switch (ev.phase) {
        .down => {
            if (styleOf(s) != .classic) showSb(s, ev.time_ms); // drag activity shows it
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
            if (styleOf(s) != .classic) showSb(s, ev.time_ms); // keep it alive while dragging
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
        // hover shows an overlay/auto_hide scrollbar (a notification: it
        // never claims hover, and bubbles past anyway)
        .enter, .hover_move => {
            if (styleOf(s) != .classic) {
                s.hovering = true;
                showSb(s, ev.time_ms);
            }
            return false;
        },
        // leaving keeps it visible briefly (the idle hide arms from the leave)
        .leave => {
            if (styleOf(s) != .classic) {
                s.hovering = false;
                s.hide_deadline = ev.time_ms + hide_delay_ms;
            }
            return false;
        },
    }
}

/// Show the scrollbar (scroll activity / hover / drag) and re-arm the idle
/// hide deadline. Classic scrollbars are always shown.
fn showSb(s: *ScrollbarState, now_ms: u64) void {
    if (styleOf(s) == .classic) return;
    s.shown = true;
    s.hide_deadline = now_ms + hide_delay_ms;
    if (s.anim_to != 1) animateAlpha(s, 1);
    damageSb(s);
}

/// Hide the scrollbar (the idle delay elapsed).
fn hideSb(s: *ScrollbarState) void {
    if (styleOf(s) == .classic) return;
    s.shown = false;
    if (s.anim_to != 0) animateAlpha(s, 0);
    damageSb(s);
}

/// Fade the scrollbar to `to` (0/1); without a timeline, snap.
fn animateAlpha(s: *ScrollbarState, to: f32) void {
    s.anim_to = to;
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.tweenAnim(.{ to, 0, 0, 0 }, fade_ms, .{ .ease = .standard }),
            .from = .{ s.alpha, 0, 0, 0 },
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = sbAnimUpdateCb, .userdata = s.node },
        });
    } else {
        s.alpha = to;
    }
}

fn sbAnimUpdateCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(ScrollbarState, n);
    s.alpha = value[0];
    damageSb(s);
}

fn scrollbarDeinit(n: *Node) void {
    const s = stateOf(ScrollbarState, n);
    if (anim.timeline()) |tl| {
        tl.cancelChannel(@ptrCast(&s.anim_channel));
        if (s.ticker) |t| tl.removeTicker(t);
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
    .on_scroll = scrollbarOnScroll,
    .hit_bounds = scrollbarHitBounds,
};

pub fn scrollbar(allocator: std.mem.Allocator, opts: ScrollbarOptions) !*Node {
    const node = try Node.create(allocator, &scrollbar_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(ScrollbarState);
    errdefer allocator.destroy(s);
    // classic is always shown; overlay/auto_hide start hidden at rest
    s.* = .{
        .opts = opts,
        .node = node,
        .shown = styleOfOpts(opts) == .classic,
        .alpha = if (styleOfOpts(opts) == .classic) 1 else 0,
    };
    // Track the scrollable's offset: the thumb repaints when it moves.
    // (The scrollbar must not outlive its scrollable — the ticker borrows it,
    // same convention as the dropdown's borrowed menu-item labels.)
    if (anim.timeline()) |tl| {
        const t = anim.Timeline.Ticker{ .fn_ptr = sbTickCb, .userdata = s, .has_pending = sbHasPendingCb };
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

// --- Phase 2d-0.5 styles (overlay / auto_hide) ---

const layout_w = @import("layout.zig");

fn overlayTheme() Theme {
    return .{ .platform = .{ .scrollbar_style = .overlay } };
}

/// The row OWNS the list and the scrollbar (add = possession): tests deinit
/// the row only. The row does not shrink its children: the list keeps its
/// measured width (100), so the row is 100 wide for overlay (the scrollbar
/// takes no space) and 108 for auto_hide (the scrollbar takes 8).
fn addToRow(row: *Node, list: *Node, sb: *Node, row_w: f32) void {
    row.add(list);
    row.add(sb);
    row.layout(.{ .x = 0, .y = 0, .w = row_w, .h = 200 });
}

test "scrollbar overlay: no layout space, hidden at rest, shows on scroll, hides after the idle delay" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const row = try layout_w.row(std.testing.allocator, .{});
    defer row.deinit();
    const list = try testList();
    const sb = try scrollbar(std.testing.allocator, .{ .scroll = list, .theme = overlayTheme() });
    addToRow(row, list, sb, 100);
    const s = stateOf(ScrollbarState, sb);
    // overlay: no layout space (the content keeps the full width)
    try std.testing.expectEqual(@as(f32, 0), sb.bounds.w);
    try std.testing.expectEqual(@as(f32, 100), list.bounds.w);
    // hidden at rest
    try std.testing.expect(!s.shown);
    try std.testing.expectEqual(@as(f32, 0), s.alpha);
    // the hit zone is the parent's right edge (8dp wide, the width token)
    const hb = sb.vtable.hit_bounds.?(sb);
    try std.testing.expectEqual(@as(f32, 92), hb.x);
    try std.testing.expectEqual(@as(f32, 8), hb.w);
    try std.testing.expectEqual(@as(f32, 200), hb.h);
    // scroll activity shows it (the tracker ticker)
    const list_mod = @import("list_view.zig");
    _ = list_mod.setScrollOffset(list, 1000);
    tl.tick(0); // notices the offset change → show + arm the hide deadline
    try std.testing.expect(s.shown);
    try std.testing.expectEqual(@as(u64, 800), s.hide_deadline.?);
    tl.tick(200); // the fade (150ms) settled
    try std.testing.expectEqual(@as(f32, 1), s.alpha);
    // the idle delay hides it
    tl.tick(900); // deadline (800) passed → hide
    try std.testing.expect(!s.shown);
    tl.tick(1100); // the fade-out settled
    try std.testing.expectEqual(@as(f32, 0), s.alpha);
}

test "scrollbar overlay: hover shows it, dragging the thumb scrolls" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const row = try layout_w.row(std.testing.allocator, .{});
    defer row.deinit();
    const list = try testList();
    const sb = try scrollbar(std.testing.allocator, .{ .scroll = list, .theme = overlayTheme() });
    addToRow(row, list, sb, 100);
    const s = stateOf(ScrollbarState, sb);
    // hover the right edge → enter → show (snap: no timeline)
    router.dispatchPointer(row, .{ .phase = .move, .x = 96, .y = 100 });
    try std.testing.expect(s.shown);
    try std.testing.expectEqual(@as(f32, 1), s.alpha);
    // drag the thumb (at the top of the track) to the middle
    router.dispatchPointer(row, .{ .phase = .down, .x = 96, .y = 10 });
    router.dispatchPointer(row, .{ .phase = .move, .x = 96, .y = 100 });
    const list_mod = @import("list_view.zig");
    const off = list_mod.scrollOffset(list);
    try std.testing.expect(off > 2000 and off < 2600); // ~half of max 4600
    router.dispatchPointer(row, .{ .phase = .up, .x = 96, .y = 100 });
}

test "scrollbar auto_hide: takes layout space, hidden at rest, track+thumb when shown" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const list = try testList();
    defer list.deinit();
    const sb = try scrollbar(std.testing.allocator, .{
        .scroll = list,
        .theme = .{ .platform = .{ .scrollbar_style = .auto_hide } },
        .track_color = 0x1A1A1AFF,
        .thumb_color = 0xFFFFFFFF,
    });
    defer sb.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    sb.layout(.{ .x = 100, .y = 0, .w = 8, .h = 200 });
    const s = stateOf(ScrollbarState, sb);
    // auto_hide takes layout space (the width token)
    const m = sb.measure(.{ .max_w = 108, .max_h = 200 });
    try std.testing.expectEqual(@as(f32, 8), m.w);
    // hidden at rest
    try std.testing.expectEqual(@as(f32, 0), s.alpha);
    // scroll activity shows it (track + thumb, faded in)
    const list_mod = @import("list_view.zig");
    _ = list_mod.setScrollOffset(list, 1000);
    tl.tick(0);
    tl.tick(200);
    try std.testing.expect(s.shown);
    try std.testing.expectEqual(@as(f32, 1), s.alpha);
    // back to the top: the thumb sits at the top of the track
    _ = list_mod.setScrollOffset(list, 0);
    tl.tick(300);
    // pixel check: track + thumb painted at the node's bounds
    var r = try golden.Renderer.init(std.testing.allocator, 108, 200);
    defer r.deinit();
    r.paint(sb, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(104, 10)); // thumb at the top
    try std.testing.expectEqual(@as(Color, 0x1A1A1AFF), f.pixelAt(104, 100)); // the opaque track
}

test "golden: overlay scrollbar floats over the parent's right edge (no track)" {
    const row = try layout_w.row(std.testing.allocator, .{});
    defer row.deinit();
    const list = try testList();
    const sb = try scrollbar(std.testing.allocator, .{ .scroll = list, .theme = overlayTheme(), .thumb_color = 0xFFFFFFFF });
    addToRow(row, list, sb, 100);
    var r = try golden.Renderer.init(std.testing.allocator, 100, 200);
    defer r.deinit();
    // hidden at rest: nothing painted over the content
    r.paint(row, 0x000000FF);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    try std.testing.expectEqual(@as(Color, 0x3B5BDBFF), f1.pixelAt(96, 10)); // the list shows through
    // shown (hover, snap without a timeline): the thumb floats at the right
    // edge with a 2px inset — no track
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.dispatchPointer(row, .{ .phase = .move, .x = 96, .y = 100 }); // enter → show
    r.paint(row, 0x000000FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f2.pixelAt(96, 10)); // thumb (inset 2: 94..98)
    try std.testing.expectEqual(@as(Color, 0x3B5BDBFF), f2.pixelAt(92, 10)); // no track: the list shows
    try std.testing.expectEqual(@as(Color, 0x3B5BDBFF), f2.pixelAt(96, 100)); // below the 24px thumb
}

test "scrollbar overlay: wheel over the strip scrolls the content" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const row = try layout_w.row(std.testing.allocator, .{});
    defer row.deinit();
    const list = try testList();
    const sb = try scrollbar(std.testing.allocator, .{ .scroll = list, .theme = overlayTheme() });
    addToRow(row, list, sb, 100);
    const list_mod = @import("list_view.zig");
    // wheel down over the overlay strip (x=96): forwarded to the scrollable
    router.dispatchScroll(row, .{ .x = 96, .y = 100, .delta_y = -10 });
    const off1 = list_mod.scrollOffset(list);
    try std.testing.expect(off1 > 0);
    // wheel down over the content (x=50): scrolls directly
    router.dispatchScroll(row, .{ .x = 50, .y = 100, .delta_y = -10 });
    try std.testing.expect(list_mod.scrollOffset(list) > off1);
}

test "scrollbar overlay: a stationary pointer keeps it shown; leaving hides it" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const row = try layout_w.row(std.testing.allocator, .{});
    defer row.deinit();
    const list = try testList();
    const sb = try scrollbar(std.testing.allocator, .{ .scroll = list, .theme = overlayTheme() });
    addToRow(row, list, sb, 100);
    const s = stateOf(ScrollbarState, sb);
    // enter at t=0 → shown; the idle deadline expires but the pointer rests there
    router.dispatchPointer(row, .{ .phase = .move, .x = 96, .y = 100, .time_ms = 0 });
    tl.tick(0);
    tl.tick(200); // fade in settled
    try std.testing.expect(s.shown);
    try std.testing.expectEqual(@as(f32, 1), s.alpha);
    tl.tick(1000); // the idle deadline (800) expired — but the pointer hovers
    try std.testing.expect(s.shown);
    // leave at t=1000 → the hide deadline arms from the leave
    router.dispatchPointer(row, .{ .phase = .move, .x = 50, .y = 100, .time_ms = 1000 });
    try std.testing.expect(!s.hovering);
    tl.tick(1900); // deadline (1000 + 800) passed → hide
    try std.testing.expect(!s.shown);
    tl.tick(2100); // the fade-out settled
    try std.testing.expectEqual(@as(f32, 0), s.alpha);
}

test "scrollbar overlay: no hit zone when the content fits (clicks pass through)" {
    const row = try layout_w.row(std.testing.allocator, .{});
    defer row.deinit();
    const list_mod = @import("list_view.zig");
    const list = try list_mod.listView(std.testing.allocator, .{
        .item_count = 2, // content 96 < viewport 200: nothing to scroll
        .factory = test_factory,
        .item_height = 48,
    });
    const sb = try scrollbar(std.testing.allocator, .{ .scroll = list, .theme = overlayTheme() });
    addToRow(row, list, sb, 100);
    // the hit zone is empty: the overlay never intercepts the content's clicks
    const hb = sb.vtable.hit_bounds.?(sb);
    try std.testing.expectEqual(@as(f32, 0), hb.w);
    try std.testing.expectEqual(@as(f32, 0), hb.h);
    const hit = row.hitTestMapped(96, 100);
    try std.testing.expect(hit != null);
    try std.testing.expect(hit.?.node != sb);
}
