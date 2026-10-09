// An M3E single-choice segmented button row: equal-width segments with a
// 1dp outlined border, one selected (SecondaryContainer), driven by an
// external Signal(usize) (single choice = radio-group semantics: the arrow
// keys move AND select).
//
// Spec: m3.material.io/components/segmented-buttons + Compose
// SegmentedButton.kt (SingleChoiceSegmentedButtonRow / SegmentedButton) +
// OutlinedSegmentedButtonTokens:
//   - row: segments are EQUAL width (weight 1f), 40dp tall (ContainerHeight),
//     min width 58dp (ButtonDefaults.MinWidth); the segments OVERLAP by the
//     border width (spacedBy(-space), space = OutlineWidth = 1dp) so the
//     borders coincide — no double border
//   - shapes (itemShape on CornerFull): count == 1 -> full; first -> the
//     start side full (tl/bl = h/2); last -> the end side full (tr/br = h/2);
//     middle -> square. RTL mirrors the row and the shapes
//   - segment: 1dp Outline border (disabled: OnSurface @ 0.12), label
//     label_large, optional 18dp icon + 8dp gap, content padding 12dp
//     start/end
//   - colors: selected = SecondaryContainer fill + OnSecondaryContainer
//     content; unselected = transparent fill + OnSurface content; disabled =
//     OnSurface @ 0.38 content (the fill stays: a disabled+selected segment
//     keeps SecondaryContainer)
//   - state layer: the content color blended over the container at hover
//     0.08 / focus 0.10 / pressed 0.12 (over the transparent unselected
//     container the layer is the content color AT that alpha — lerping from
//     transparent black would double-scale the RGB in the src-over blend)
//   - input: a drag past the touch slop (ui/gestures.SLOP, raw coords) is a
//     scroll, not a press; a click selects (sets the signal + on_change);
//     left/right (up/down) arrows move the selection, skipping disabled
//     segments and wrapping (RTL flips left/right)
//
// v1 deviations (documented, fixed later):
//   - Single choice only (MultiChoiceSegmentedButtonRow is a follow-up).
//   - Equal width = the WIDEST content (Compose weight(1f) + IntrinsicSize
//     .Min distributes the row's intrinsic width evenly — the mean; v1 uses
//     the max, the common visual case).
//   - No checked-icon crossfade / icon-less-to-icon transition animation
//     (the M3E segment morph lands with the animation system, Phase 3).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const icon_w = @import("icon.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

/// A segment (the factory copies the label).
pub const SegmentedItem = struct {
    label: []const u8,
    icon: ?icon_w.IconName = null,
    enabled: bool = true,
};

pub const SegmentedButtonOptions = struct {
    /// The fixed selection when no signal is given (with one, the signal is
    /// the source of truth and this is only the fallback).
    selected: usize = 0,
    theme: Theme = theme_mod.light,
};

/// M3E tokens (OutlinedSegmentedButtonTokens + SegmentedButtonDefaults).
const seg_height: f32 = 40; // ContainerHeight
const seg_min_w: f32 = 58; // ButtonDefaults.MinWidth
const seg_h_pad: f32 = 12; // ContentPadding (start/end)
const icon_size: f32 = 18; // IconSize
const icon_gap: f32 = 8; // IconSpacing (private val in SegmentedButton.kt)
const border_w: f32 = 1; // OutlineWidth (also the row overlap)

const ItemDef = struct {
    label: [:0]const u8, // owned
    icon: ?icon_w.IconName,
    enabled: bool,
};

const SegState = struct {
    items: std.array_list.Managed(ItemDef), // owned defs
    opts: SegmentedButtonOptions,
    sig: ?*ui.state.Signal(usize) = null,
    on_change: ?Callback = null,
    selected: usize = 0,
    pressed: i32 = -1,
    hovered: i32 = -1,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — gestures.SLOP).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
};

fn stateOf(n: *Node) *SegState {
    return @ptrCast(@alignCast(n.state.?));
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

/// The segment width: all segments are equal, sized to the widest content
/// (icon + gap + label + paddings) with the 58dp min width.
fn segWidth(s: *SegState, t: Theme) f32 {
    const ls = t.type_scale.label_large;
    const bold = ls.weight >= 500;
    var w: f32 = seg_min_w;
    for (s.items.items) |def| {
        var cw = seg_h_pad * 2 + ui.paint.measureText(def.label, ls.size, bold).width;
        if (def.icon != null) cw += icon_size + icon_gap;
        w = @max(w, cw);
    }
    return w;
}

/// The segment's rect in LTR space (the segments overlap by the border
/// width). The caller mirrors it for RTL.
fn segRectLtr(b: Rect, i: usize, w: f32) Rect {
    return .{ .x = b.x + @as(f32, @floatFromInt(i)) * (w - border_w), .y = b.y, .w = w, .h = b.h };
}

fn mirrorX(b: Rect, r: Rect) Rect {
    return .{ .x = b.x + b.w - (r.x - b.x) - r.w, .y = r.y, .w = r.w, .h = r.h };
}

/// The segment under the point (-1 = none), in the widget's parent space.
fn segAt(s: *SegState, t: Theme, b: Rect, x: f32, y: f32) i32 {
    const count = s.items.items.len;
    if (count == 0) return -1;
    if (y < b.y or y >= b.y + b.h) return -1;
    const w = segWidth(s, t);
    const rtl = ui.i18n.direction() == .rtl;
    for (0..count) |i| {
        var sr = segRectLtr(b, i, w);
        if (rtl) sr = mirrorX(b, sr);
        if (x >= sr.x and x < sr.x + sr.w) return @intCast(i);
    }
    return -1;
}

/// Select a segment: the state + the signal (if any) + the a11y value, then
/// on_change. Radio-group semantics: the selection follows.
fn segSelect(n: *Node, index: usize) void {
    const s = stateOf(n);
    if (index >= s.items.items.len) return;
    if (!s.items.items[index].enabled) return;
    s.selected = index;
    if (s.sig) |sig| sig.set(index); // the sync callback re-reads (idempotent)
    n.markDirty();
    if (n.semantics) |sem| {
        sem.value = s.items.items[index].label; // a11y: the value follows
        ui.semantics.notifyControlChanged(n);
    }
    if (s.on_change) |cb| cb.fn_ptr(cb.userdata);
}

/// The signal -> widget sync (the app moved the selection externally).
fn segSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const v = s.sig.?.peek();
    if (v < s.items.items.len and v != s.selected) {
        s.selected = v;
        if (n.semantics) |sem| sem.value = s.items.items[v].label;
        n.markDirty();
    }
}

/// The last selected index (pub accessor).
pub fn selectedIndex(n: *Node) usize {
    return stateOf(n).selected;
}

fn segMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const count = s.items.items.len;
    if (count == 0) return c.constrain(.{});
    const w = segWidth(s, s.opts.theme);
    const total_w = @as(f32, @floatFromInt(count)) * w - @as(f32, @floatFromInt(count - 1)) * border_w;
    return c.constrain(.{ .w = total_w, .h = seg_height });
}

fn segLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: the segments are computed from the bounds at paint/hit
}

/// Paint an icon glyph centered in a 24x24 box (menu.zig's helper, 18dp here).
fn paintIcon(ctx: *kx.Ctx, name: icon_w.IconName, x: f32, y: f32, size: f32, color: Color) void {
    if (color & 0xFF == 0) return;
    var gbuf: [4]u8 = .{ 0, 0, 0, 0 };
    const glen = std.unicode.utf8Encode(icon_w.codepoint(name), &gbuf) catch return;
    const glyph: [:0]const u8 = gbuf[0..glen :0];
    const m = ui.paint.measureText(glyph, size, false);
    const gx = x + (size - m.width) / 2;
    const baseline = y + (size - m.height) / 2 + m.ascent;
    ui.paint.text(ctx, glyph, gx, baseline, size, false, color);
}

fn segPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const cs = t.colors;
    const count: usize = s.items.items.len;
    if (count == 0) return;
    const w = segWidth(s, t);
    const ls = t.type_scale.label_large;
    const bold = ls.weight >= 500;
    const rtl = ui.i18n.direction() == .rtl;
    const focused = input.isFocused(n);
    const half = b.h / 2; // CornerFull
    for (0..count) |i| {
        const def = s.items.items[i];
        const idx: i32 = @intCast(i);
        var sr = segRectLtr(b, i, w);
        if (rtl) sr = mirrorX(b, sr);
        const selected = i == s.selected;
        // itemShape(index, count) on CornerFull: first = start half, last =
        // end half, middle = square, single = full
        var tl: f32 = 0;
        var tr: f32 = 0;
        var br: f32 = 0;
        var bl: f32 = 0;
        if (count == 1) {
            tl = half;
            tr = half;
            br = half;
            bl = half;
        } else if (i == 0) {
            tl = half;
            bl = half;
        } else if (i == count - 1) {
            tr = half;
            br = half;
        }
        if (rtl) { // the start side flips to the right
            const t2 = tl;
            tl = tr;
            tr = t2;
            const b2 = bl;
            bl = br;
            br = b2;
        }
        // container (a disabled+selected segment keeps the fill)
        if (selected) {
            ui.paint.fillRRectCorners(ctx, sr.x, sr.y, sr.w, sr.h, tl, tr, br, bl, cs.secondary_container);
        }
        // state layer (enabled only): the content color over the container
        if (def.enabled) {
            const alpha: f32 = if (s.pressed == idx)
                t.state.pressed
            else if (focused)
                t.state.focus
            else if (s.hovered == idx)
                t.state.hover
            else
                0;
            if (alpha > 0) {
                const on = if (selected) cs.on_secondary_container else cs.on_surface;
                const layer = if (selected)
                    theme_mod.stateLayer(cs.secondary_container, on, alpha)
                else
                    ui.paint.withAlphaScaled(on, alpha); // transparent container
                ui.paint.fillRRectCorners(ctx, sr.x, sr.y, sr.w, sr.h, tl, tr, br, bl, layer);
            }
        }
        // border
        const oc: Color = if (def.enabled) cs.outline else ui.paint.withAlphaScaled(cs.on_surface, 0.12);
        ui.paint.strokeRRectCorners(ctx, sr.x, sr.y, sr.w, sr.h, tl, tr, br, bl, border_w, oc);
        // content: [icon, gap, label] centered
        const fg: Color = if (!def.enabled)
            ui.paint.withAlphaScaled(cs.on_surface, 0.38)
        else if (selected)
            cs.on_secondary_container
        else
            cs.on_surface;
        const lm = ui.paint.measureText(def.label, ls.size, bold);
        var content_w = lm.width;
        if (def.icon != null) content_w += icon_size + icon_gap;
        const cx = sr.x + (sr.w - content_w) / 2;
        const baseline = sr.y + (sr.h - lm.height) / 2 + lm.ascent;
        var tx = cx;
        if (def.icon) |iname| {
            paintIcon(ctx, iname, tx, sr.y + (sr.h - icon_size) / 2, icon_size, fg);
            tx += icon_size + icon_gap;
        }
        ui.paint.text(ctx, def.label, tx, baseline, ls.size, bold, fg);
    }
}

fn segOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    const idx = segAt(s, s.opts.theme, n.bounds, ev.x, ev.y);
    switch (ev.phase) {
        .down => {
            if (idx < 0 or !s.items.items[@intCast(idx)].enabled) return false;
            s.pressed = idx;
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            n.markDirty();
            return true;
        },
        .up => {
            const was = s.pressed;
            s.pressed = -1;
            n.markDirty();
            if (was >= 0 and idx == was) segSelect(n, @intCast(was));
            return true;
        },
        .move => {
            // A drag beyond the touch slop is a scroll, not a press: cancel
            // the pressed state. The move is NOT claimed (return false) so
            // it keeps bubbling to scrollable ancestors.
            if (s.pressed >= 0) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.pressed = -1;
                    n.markDirty();
                }
            }
            return false;
        },
        // the pointer went down outside while we held the capture: cancel
        .outside_down => {
            s.pressed = -1;
            n.markDirty();
            return true;
        },
        .enter => {
            s.hovered = idx;
            n.markDirty();
            return true;
        },
        .leave => {
            s.hovered = -1;
            n.markDirty();
            return true;
        },
        else => {},
    }
    return false;
}

/// Keyboard: the row is focusable; the arrows move AND select (radio-group
/// semantics), skipping disabled segments and wrapping (RTL flips
/// left/right).
fn segOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind != .key_down) return false;
    const count: i32 = @intCast(s.items.items.len);
    if (count == 0) return false;
    switch (ev.key) {
        .left, .up, .right, .down => {
            const rtl = ui.i18n.direction() == .rtl;
            const forward: i32 = if (ev.key == .right or ev.key == .down) 1 else -1;
            const step: i32 = if (rtl and (ev.key == .left or ev.key == .right)) -forward else forward;
            var i: i32 = @intCast(@min(s.selected, s.items.items.len - 1));
            var guard: i32 = 0;
            while (guard < count) : (guard += 1) {
                i = @mod(i + step, count);
                if (s.items.items[@intCast(i)].enabled) break;
            }
            segSelect(n, @intCast(i));
            return true;
        },
        else => {},
    }
    return false;
}

fn segDeinit(n: *Node) void {
    const s = stateOf(n);
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = segSyncCb, .userdata = n } });
    input.releaseNode(n);
    for (s.items.items) |*def| n.allocator.free(def.label);
    s.items.deinit();
    n.allocator.destroy(s);
}

const seg_vtable = ui.node.VTable{
    .measure = segMeasure,
    .layout = segLayout,
    .paint = segPaint,
    .deinit = segDeinit,
    .on_pointer = segOnPointer,
    .on_key = segOnKey,
};

/// An M3E single-choice segmented button row. The segments are internal
/// chrome painted by the widget (a leaf — no document children). `items`
/// are copied (the labels are owned). `sig` drives the selection
/// (round-trips); `on_change` fires with `selectedIndex(n)` valid after a
/// click or an arrow-key selection.
pub fn segmentedButton(allocator: std.mem.Allocator, items: []const SegmentedItem, sig: ?*ui.state.Signal(usize), on_change: ?Callback, opts: SegmentedButtonOptions) !*Node {
    const node = try Node.create(allocator, &seg_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(SegState);
    errdefer allocator.destroy(s);
    s.* = .{
        .items = std.array_list.Managed(ItemDef).init(allocator),
        .opts = opts,
        .sig = sig,
        .on_change = on_change,
        .selected = opts.selected,
    };
    // One ownership boundary: on ANY failure this errdefer frees the
    // appended defs' labels (segDeinit owns them only once returned).
    errdefer {
        for (s.items.items) |*def| allocator.free(def.label);
        s.items.deinit();
    }
    for (items) |item| {
        const label = try dupeZ(allocator, item.label);
        errdefer allocator.free(label); // iteration scope: freed only if THIS iteration fails before the append
        // No catch-free here: on append failure the errdefer frees the copy.
        try s.items.append(.{ .label = label, .icon = item.icon, .enabled = item.enabled });
    }
    node.state = s;
    if (sig) |sg| {
        sg.subscribe(.{ .callback = .{ .fn_ptr = segSyncCb, .userdata = node } });
        const v = sg.peek();
        if (v < s.items.items.len) s.selected = v; // the signal wins
    }
    if (s.selected >= s.items.items.len) s.selected = 0; // clamp bad data
    ui.semantics.attach(node, .{
        .role = .group, // a radio group (single choice)
        .label = "Segmented button",
        .focusable = true, // takes the keyboard focus (arrow nav)
        .value = if (s.items.items.len > 0) s.items.items[s.selected].label else "",
    }); // Phase 2c
    return node;
}

// --- tests ---

fn changeCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "segmented_button: measures equal-width segments overlapping by the border; 40dp tall" {
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{ .{ .label = "Day" }, .{ .label = "Week" }, .{ .label = "Month" } }, null, null, .{});
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    const t = theme_mod.light;
    const ls = t.type_scale.label_large;
    const w_month = seg_h_pad * 2 + ui.paint.measureText("Month", ls.size, true).width;
    const w = @max(seg_min_w, w_month); // all segments = the widest content
    try std.testing.expectApproxEqAbs(@as(f32, 3) * w - 2 * border_w, sz.w, 0.001);
    try std.testing.expectEqual(seg_height, sz.h);
    // a single segment: full width, no overlap
    const one = try segmentedButton(a, &.{.{ .label = "Only" }}, null, null, .{});
    defer one.deinit();
    const sz1 = one.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(@max(seg_min_w, seg_h_pad * 2 + ui.paint.measureText("Only", ls.size, true).width), sz1.w, 0.001);
}

test "segmented_button: click selects (signal + on_change); arrows move AND select; a11y follows" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = changeCounterCb, .userdata = &count };
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sig.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{ .{ .label = "Day" }, .{ .label = "Week", .enabled = false }, .{ .label = "Month" } }, sig, cb, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 300, .h = 40 });
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n));
    try std.testing.expectEqualStrings("Day", n.semantics.?.value);
    // click the 3rd segment (the widest item sets the segment width; the
    // segments overlap by 1dp)
    const t = theme_mod.light;
    const w = @max(seg_min_w, seg_h_pad * 2 + ui.paint.measureText("Month", t.type_scale.label_large.size, true).width);
    const x3 = @as(f32, @floatFromInt(2)) * (w - border_w) + 10;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = x3, .y = 20, .raw_x = x3, .raw_y = 20 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = x3, .y = 20, .raw_x = x3, .raw_y = 20 });
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(n));
    try std.testing.expectEqual(@as(usize, 2), sig.peek()); // the signal round-trips
    try std.testing.expectEqual(@as(u32, 1), count); // on_change fired
    try std.testing.expectEqualStrings("Month", n.semantics.?.value); // a11y follows
    // keyboard: the row takes the focus; left wraps AND selects (skipping
    // the disabled middle segment)
    input.requestFocus(n);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .left });
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n)); // wrapped from 2 (1 disabled)
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .right });
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(n)); // 0 -> skips 1 -> 2
    try std.testing.expectEqual(@as(u32, 3), count);
    // the external signal moves the selection too
    sig.set(0);
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n));
    try std.testing.expectEqualStrings("Day", n.semantics.?.value);
}

test "segmented_button: semantics — role group, focusable, value follows the selection" {
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{ .{ .label = "A" }, .{ .label = "B" } }, null, null, .{ .selected = 1 });
    defer n.deinit();
    try std.testing.expectEqual(ui.semantics.Role.group, n.semantics.?.role);
    try std.testing.expect(n.semantics.?.focusable);
    try std.testing.expectEqualStrings("B", n.semantics.?.value);
    try std.testing.expectEqual(@as(usize, 1), selectedIndex(n));
}

test "golden: the selected segment paints SecondaryContainer; the row's ends are rounded, the middle is square" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{ .{ .label = "Day" }, .{ .label = "Week" }, .{ .label = "Month" } }, null, null, .{ .selected = 1, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 320, 80);
    defer r.deinit();
    // half-pixel y: the 1dp border stroke then covers pixel row 20 exactly
    n.layout(.{ .x = 20, .y = 20.5, .w = 280, .h = 40 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const w = segWidth(stateOf(n), t);
    const mid_lx = 20 + (w - border_w);
    const mid_x = mid_lx + w / 2;
    // the middle (selected) segment: SecondaryContainer above the label ink
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(@intFromFloat(mid_x), 24));
    // the first segment's start corner (radius 20 = h/2): the exact corner
    // stays background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20, 20));
    // the middle segment's corners are square: inside the corner (clear of
    // the strokes) the fill is there
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(@as(i32, @intFromFloat(mid_lx)) + 2, 23));
    // the unselected segments' borders: Outline ink at the row's top edge
    // (the first segment's straight top edge starts at x = 20 + 20)
    try std.testing.expect(f.countColorIn(.{ .x = 40, .y = 20, .w = 20, .h = 1 }, t.colors.outline) > 0);
    // the selected segment's label ink (on_secondary_container) in its row
    try std.testing.expect(f.countColorIn(.{ .x = mid_lx, .y = 30, .w = w, .h = 20 }, t.colors.on_secondary_container) > 0);
}

test "golden: a hovered unselected segment paints the on_surface state layer" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try segmentedButton(a, &.{ .{ .label = "Day" }, .{ .label = "Week" } }, null, null, .{ .selected = 0, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 80);
    defer r.deinit();
    n.layout(.{ .x = 20, .y = 20, .w = 160, .h = 40 });
    // hover the 2nd (unselected) segment
    const w = segWidth(stateOf(n), t);
    const x2 = 20 + (w - border_w) + w - 5; // near its end edge, no label ink
    _ = n.vtable.on_pointer.?(n, .{ .phase = .enter, .x = x2, .y = 40 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the state layer: on_surface @ 0.08 AT the alpha (transparent
    // container) blended over the background
    try golden.expectPixelApprox(f, @intFromFloat(x2), 40, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, t.state.hover), 0xFFFFFFFF));
}

test "golden: a disabled segment paints the OnSurface@0.38 label + the @0.12 border" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    // the disabled segment is NOT selected (a transparent container: the ink
    // blends over the background)
    const n = try segmentedButton(a, &.{ .{ .label = "Day", .enabled = false }, .{ .label = "Week" } }, null, null, .{ .selected = 1, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 80);
    defer r.deinit();
    // half-pixel y: the 1dp border stroke then covers pixel row 20 exactly
    n.layout(.{ .x = 20, .y = 20.5, .w = 80, .h = 40 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the label ink: on_surface @ 0.38 over the background
    const dis = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), 0xFFFFFFFF);
    try std.testing.expect(f.countColorIn(.{ .x = 30, .y = 30, .w = 60, .h = 20 }, dis) > 0);
    // the border ink: on_surface @ 0.12 over the background (row 20 is the
    // first segment's straight top edge)
    const boc = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.12), 0xFFFFFFFF);
    try golden.expectPixelApprox(f, 50, 20, boc);
}

test "segmented_button: RTL mirrors the row (the first segment sits at the end side)" {
    const a = std.testing.allocator;
    const i18n = try ui.i18n.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    const n = try segmentedButton(a, &.{ .{ .label = "A" }, .{ .label = "B" } }, null, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 116, .h = 40 }); // 2 segments of 58 (min width)
    // in RTL the FIRST segment is at the END side: a click at the right end
    // selects index 0
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 100, .y = 20, .raw_x = 100, .raw_y = 20 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 100, .y = 20, .raw_x = 100, .raw_y = 20 });
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n));
}
