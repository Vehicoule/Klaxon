// NavigationRail (Phase 2d.3 PR D4, M3E) — the Material 3 Expressive
// navigation rail: a Surface column of items driven by an external
// Signal(usize) (single choice = tab-group semantics: the arrow keys move
// AND select).
//
// Spec: m3.material.io/components/navigation-rail + Compose NavigationRail.kt
// (the collapsed rail + NavigationRailItem) / WideNavigationRail.kt +
// NavigationItem.kt (the expanded rail + the start-icon item) + the
// NavigationRail*Tokens:
//   - container: Surface, CornerNone; collapsed width 96 (ContainerWidth),
//     expanded width clamp(max item width, 220, 360) (ContainerWidthMinimum /
//     Maximum); content top padding 44 (TopSpace); items 56dp tall
//     (NavigationRailItemHeight = ActiveIndicatorWidth), 4dp apart
//     (ItemVerticalSpace)
//   - collapsed (icon-only): the active indicator is a 56x56 CIRCLE
//     (CornerFull; IndicatorVerticalPaddingNoLabel = (56-24)/2 = 16 → the
//     indicator is 24+32 = 56 tall), the 24dp icon centered on it
//   - expanded (icon + label row): the active indicator is a 56dp-tall pill
//     (CornerFull) of width label_w + 64 (icon 24 + IconLabelSpace 8 + label
//     + 2x16 FullWidthLeadingSpace), starting at x = 20
//     (WNRItemHorizontalPadding); the icon at pill_x + 16, the label
//     (LabelLarge 14/20/500) at icon_x + 24 + 8, both vertically centered
//   - colors: active indicator SecondaryContainer; active icon
//     OnSecondaryContainer; active label OnSecondaryContainer (start-icon
//     position — selectedTextColorStartIconPosition = ItemActiveIcon);
//     inactive icon + label OnSurfaceVariant; disabled OnSurfaceVariant @
//     0.38 (DisabledAlpha)
//   - state layer: OnSecondaryContainer over the INDICATOR only (the ripple
//     is mapped to the indicator) at hover 0.08 / focus 0.10 / pressed 0.12
//   - input: a click selects (and focuses the group); up/down arrows move
//     the selection, skipping disabled items and wrapping; a drag past the
//     touch slop (ui/gestures.SLOP, raw coords) is a scroll, not a press
//
// The widget is a LEAF: the items (icon + label + indicator) are internal
// chrome painted by the widget (skip_children — document children never
// serialize; the items come from the options array).
//
// v1 deviations (documented, fixed later):
//   - Collapsed = icon-only items (the collapsed-with-label top-icon layout,
//     56x32 pill + LabelMedium below, is a follow-up — alwaysShowLabel).
//   - No header (FAB) / footer slots, no modal variant (SurfaceContainer,
//     CornerLarge, Level2 + scrim), no collapsed<->expanded animation (the
//     state switch is instant, like the text field's label float).
//   - No item badges. RTL mirrors the expanded row; the label run stays LTR.
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

/// A rail item (the factory copies the label).
pub const NavRailItem = struct {
    label: []const u8,
    icon: icon_w.IconName = .home,
    enabled: bool = true,
};

pub const NavigationRailOptions = struct {
    /// Expanded rails show icon+label rows (220-360dp); collapsed rails are
    /// icon-only (96dp).
    expanded: bool = false,
    /// The fixed selection when no signal is given (with one, the signal is
    /// the source of truth and this is only the fallback).
    selected: usize = 0,
    theme: Theme = theme_mod.light,
};

// --- M3E tokens (the NavigationRail*Tokens + the WideNavigationRail vals) ---
const collapsed_w: f32 = 96; // ContainerWidth
const expanded_min_w: f32 = 220; // ContainerWidthMinimum
const expanded_max_w: f32 = 360; // ContainerWidthMaximum
const top_space: f32 = 44; // TopSpace
const item_gap: f32 = 4; // ItemVerticalSpace
const item_h: f32 = 56; // NavigationRailItemHeight (= ActiveIndicatorWidth)
const icon_size: f32 = 24;
// collapsed icon-only: the indicator is a 56x56 circle (CornerFull)
const circle_d: f32 = 56; // 24 + 2 * (56-24)/2
// expanded: the pill is 56 tall; the item leads 20; the icon pads 16 inside
// the pill; the icon-label gap is 8
const item_lead: f32 = 20; // WNRItemHorizontalPadding
const pill_icon_pad: f32 = 16; // FullWidthLeadingSpace
const icon_label_gap: f32 = 8; // HorizontalItemTokens.IconLabelSpace
const pill_h: f32 = 56; // HorizontalItemTokens.ActiveIndicatorHeight

const ItemDef = struct {
    label: [:0]const u8, // owned
    icon: icon_w.IconName,
    enabled: bool,
};

const RailState = struct {
    items: std.array_list.Managed(ItemDef), // owned defs
    opts: NavigationRailOptions,
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

fn stateOf(n: *Node) *RailState {
    return @ptrCast(@alignCast(n.state.?));
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

/// The item's rect in the widget's parent space (top-aligned stack).
fn itemRect(b: Rect, i: usize) Rect {
    return .{
        .x = b.x,
        .y = b.y + top_space + @as(f32, @floatFromInt(i)) * (item_h + item_gap),
        .w = b.w,
        .h = item_h,
    };
}

/// The item under the point (-1 = none), in the widget's parent space.
fn itemAt(s: *RailState, b: Rect, x: f32, y: f32) i32 {
    if (x < b.x or x >= b.x + b.w) return -1;
    const count = s.items.items.len;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const r = itemRect(b, i);
        if (y >= r.y and y < r.y + r.h) return @intCast(i);
    }
    return -1;
}

/// The expanded item's pill width (icon + gap + label + 2x16 padding).
fn pillWidth(s: *RailState, def: ItemDef) f32 {
    const ls = s.opts.theme.type_scale.label_large;
    const lw = ui.paint.measureText(def.label, ls.size, ls.weight >= 500).width;
    return icon_size + icon_label_gap + lw + pill_icon_pad * 2;
}

fn contentHeight(s: *RailState) f32 {
    const count: f32 = @floatFromInt(s.items.items.len);
    return top_space + count * item_h + (count - 1) * item_gap;
}

/// Select an item: the state + the signal (if any) + focus + the a11y
/// value, then on_change. Tab-group semantics: the selection follows.
fn railSelect(n: *Node, index: usize) void {
    const s = stateOf(n);
    if (index >= s.items.items.len) return;
    if (!s.items.items[index].enabled) return;
    s.selected = index;
    input.requestFocus(n); // a clicked/arrow-selected tab takes the focus
    if (s.sig) |sig| sig.set(index); // the sync callback re-reads (idempotent)
    n.markDirty();
    if (n.semantics) |sem| {
        sem.value = s.items.items[index].label; // a11y: the value follows
        ui.semantics.notifyControlChanged(n);
    }
    if (s.on_change) |cb| cb.fn_ptr(cb.userdata);
}

/// The signal -> widget sync (the app moved the selection externally).
fn railSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const v = s.sig.?.peek();
    if (v < s.items.items.len and v != s.selected) {
        s.selected = v;
        if (n.semantics) |sem| {
            sem.value = s.items.items[v].label;
            ui.semantics.notifyControlChanged(n); // a11y follows external changes
        }
        n.markDirty();
    }
}

/// The last selected index (pub accessor).
pub fn selectedIndex(n: *Node) usize {
    return stateOf(n).selected;
}

fn railMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const h = if (std.math.isFinite(c.max_h)) c.max_h else contentHeight(s);
    if (s.opts.expanded) {
        var w: f32 = expanded_min_w;
        for (s.items.items) |def| {
            w = @max(w, item_lead + pillWidth(s, def));
        }
        return c.constrain(.{ .w = @min(w, expanded_max_w), .h = h });
    }
    return c.constrain(.{ .w = collapsed_w, .h = h });
}

fn railLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: the items are computed from the bounds at paint/hit
}

/// Paint an icon glyph centered in a 24x24 box.
fn paintIcon(ctx: *kx.Ctx, name: icon_w.IconName, x: f32, y: f32, color: Color) void {
    if (color & 0xFF == 0) return;
    var gbuf: [4]u8 = .{ 0, 0, 0, 0 };
    const glen = std.unicode.utf8Encode(icon_w.codepoint(name), &gbuf) catch return;
    const glyph: [:0]const u8 = gbuf[0..glen :0];
    const m = ui.paint.measureText(glyph, icon_size, false);
    const gx = x + (icon_size - m.width) / 2;
    const baseline = y + (icon_size - m.height) / 2 + m.ascent;
    ui.paint.text(ctx, glyph, gx, baseline, icon_size, false, color);
}

fn railPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const cs = t.colors;
    const rtl = ui.i18n.direction() == .rtl;
    const mx = struct {
        fn f(bx: f32, bw: f32, x: f32, w: f32, rtl_flag: bool) f32 {
            return if (rtl_flag) bx + bw - (x - bx) - w else x;
        }
    }.f;
    const ls = t.type_scale.label_large;
    const bold = ls.weight >= 500;
    const group_focused = input.isFocused(n);

    // the container
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, cs.surface);

    for (s.items.items, 0..) |def, i| {
        const idx: i32 = @intCast(i);
        const ir = itemRect(b, i);
        const selected = i == s.selected;
        const lm = ui.paint.measureText(def.label, ls.size, bold);
        // content colors
        const fg: Color = if (!def.enabled)
            ui.paint.withAlphaScaled(cs.on_surface_variant, 0.38)
        else if (selected)
            cs.on_secondary_container
        else
            cs.on_surface_variant;
        // the indicator geometry (LTR, then mirrored per element in RTL)
        var ind_x: f32 = undefined;
        var ind_y: f32 = undefined;
        var ind_w: f32 = undefined;
        var ind_h: f32 = undefined;
        var icon_x: f32 = undefined;
        var label_x: f32 = 0;
        if (s.opts.expanded) {
            const pw = pillWidth(s, def);
            const pill_ltr = ir.x + item_lead;
            ind_x = mx(b.x, b.w, pill_ltr, pw, rtl);
            ind_y = ir.y;
            ind_w = pw;
            ind_h = pill_h;
            icon_x = mx(b.x, b.w, pill_ltr + pill_icon_pad, icon_size, rtl);
            label_x = mx(b.x, b.w, pill_ltr + pill_icon_pad + icon_size + icon_label_gap, lm.width, rtl);
        } else {
            ind_x = ir.x + (ir.w - circle_d) / 2;
            ind_y = ir.y + (ir.h - circle_d) / 2;
            ind_w = circle_d;
            ind_h = circle_d;
            icon_x = ir.x + (ir.w - icon_size) / 2;
        }
        // the active indicator (CornerFull: a circle collapsed, a pill expanded)
        if (selected) {
            ui.paint.fillRRect(ctx, ind_x, ind_y, ind_w, ind_h, ind_h / 2, cs.secondary_container);
        }
        // the state layer over the indicator (enabled only)
        if (def.enabled) {
            const alpha: f32 = if (s.pressed == idx)
                t.state.pressed
            else if (group_focused and selected)
                t.state.focus
            else if (s.hovered == idx)
                t.state.hover
            else
                0;
            if (alpha > 0) {
                const base = if (selected) cs.secondary_container else cs.surface;
                ui.paint.fillRRect(ctx, ind_x, ind_y, ind_w, ind_h, ind_h / 2, theme_mod.stateLayer(base, cs.on_secondary_container, alpha));
            }
        }
        // the icon (24dp, vertically centered)
        const icon_y = ir.y + (ir.h - icon_size) / 2;
        paintIcon(ctx, def.icon, icon_x, icon_y, fg);
        // the label (expanded only; LabelLarge, vertically centered, clipped)
        if (s.opts.expanded) {
            ui.paint.clipRect(ctx, ir.x, ir.y, ir.w, ir.h);
            ui.paint.text(ctx, def.label, label_x, ir.y + (ir.h - lm.height) / 2 + lm.ascent, ls.size, bold, fg);
            ui.paint.clipReset(ctx);
        }
    }
}

fn railOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    const idx = itemAt(s, n.bounds, ev.x, ev.y);
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
            if (was >= 0 and idx == was) railSelect(n, @intCast(was));
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
        // moving across items within the leaf emits hover_move (not
        // enter/leave): re-resolve the item under the pointer
        .hover_move => {
            const h = itemAt(s, n.bounds, ev.x, ev.y);
            if (h != s.hovered) {
                s.hovered = h;
                n.markDirty();
            }
            return true;
        },
        .leave => {
            s.hovered = -1;
            n.markDirty();
            return true;
        },
    }
    return false;
}

/// Keyboard: the rail is a focusable group; up/down move AND select
/// (tab-group semantics), skipping disabled items and wrapping.
fn railOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind != .key_down) return false;
    const count: i32 = @intCast(s.items.items.len);
    if (count == 0) return false;
    switch (ev.key) {
        .up, .down => {
            const step: i32 = if (ev.key == .down) 1 else -1;
            var i: i32 = @intCast(@min(s.selected, s.items.items.len - 1));
            var guard: i32 = 0;
            while (guard < count) : (guard += 1) {
                i = @mod(i + step, count);
                if (s.items.items[@intCast(i)].enabled) break;
            }
            railSelect(n, @intCast(i));
            return true;
        },
        else => {},
    }
    return false;
}

fn railDeinit(n: *Node) void {
    const s = stateOf(n);
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = railSyncCb, .userdata = n } });
    input.releaseNode(n);
    for (s.items.items) |*def| n.allocator.free(def.label);
    s.items.deinit();
    n.allocator.destroy(s);
}

const rail_vtable = ui.node.VTable{
    .measure = railMeasure,
    .layout = railLayout,
    .paint = railPaint,
    .deinit = railDeinit,
    .on_pointer = railOnPointer,
    .on_key = railOnKey,
};

/// An M3E navigation rail. The items are internal chrome painted by the
/// widget (a leaf — no document children). `items` are copied (the labels
/// are owned). `sig` drives the selection (round-trips); `on_change` fires
/// with `selectedIndex(n)` valid after a click or an arrow-key selection.
pub fn navigationRail(allocator: std.mem.Allocator, items: []const NavRailItem, sig: ?*ui.state.Signal(usize), on_change: ?Callback, opts: NavigationRailOptions) !*Node {
    const node = try Node.create(allocator, &rail_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(RailState);
    errdefer allocator.destroy(s);
    s.* = .{
        .items = std.array_list.Managed(ItemDef).init(allocator),
        .opts = opts,
        .sig = sig,
        .on_change = on_change,
        .selected = opts.selected,
    };
    // One ownership boundary: on ANY failure this errdefer frees the
    // appended defs' labels (railDeinit owns them only once returned).
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
        sg.subscribe(.{ .callback = .{ .fn_ptr = railSyncCb, .userdata = node } });
        const v = sg.peek();
        if (v < s.items.items.len) s.selected = v; // the signal wins
    }
    if (s.selected >= s.items.items.len) s.selected = 0; // clamp bad data
    ui.semantics.attach(node, .{
        .role = .group, // a tab group (single choice)
        .label = "Navigation rail",
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

test "navigation_rail: measures the collapsed 96dp width; expanded clamps to [220, 360]; height fills" {
    const a = std.testing.allocator;
    const t = theme_mod.light;
    const items = [_]NavRailItem{ .{ .label = "Home", .icon = .home }, .{ .label = "Music", .icon = .play } };
    const c = try navigationRail(a, &items, null, null, .{ .theme = t });
    defer c.deinit();
    const m = c.measure(.{ .max_w = 2000, .max_h = std.math.inf(f32) });
    try std.testing.expectEqual(collapsed_w, m.w);
    try std.testing.expectEqual(contentHeight(stateOf(c)), m.h); // 44 + 2*56 + 4
    // fills a bounded height
    const mf = c.measure(.{ .max_w = 2000, .max_h = 400 });
    try std.testing.expectEqual(@as(f32, 400), mf.h);
    // expanded: max(label_w + 84) clamped to [220, 360]
    const e = try navigationRail(a, &items, null, null, .{ .expanded = true, .theme = t });
    defer e.deinit();
    const ls = t.type_scale.label_large;
    const lw = ui.paint.measureText("Music", ls.size, true).width;
    const em = e.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(@max(expanded_min_w, item_lead + icon_size + icon_label_gap + lw + pill_icon_pad * 2), em.w, 0.001);
    // a long label clamps at 360
    const long = try navigationRail(a, &.{.{ .label = "A very long destination label that overflows" }}, null, null, .{ .expanded = true, .theme = t });
    defer long.deinit();
    try std.testing.expectEqual(expanded_max_w, long.measure(.{ .max_w = 2000, .max_h = 2000 }).w);
}

test "navigation_rail: click selects (signal + on_change + focus); arrows move AND select; a11y follows" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = changeCounterCb, .userdata = &count };
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sig.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try navigationRail(a, &.{
        .{ .label = "Home", .icon = .home },
        .{ .label = "Music", .icon = .play, .enabled = false },
        .{ .label = "Books", .icon = .star },
    }, sig, cb, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 96, .h = 400 });
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n));
    try std.testing.expectEqualStrings("Home", n.semantics.?.value);
    // click the 3rd item (the 2nd is disabled): y = 44 + 2*60 + 28
    const y3 = top_space + 2 * (item_h + item_gap) + item_h / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 48, .y = y3, .raw_x = 48, .raw_y = y3 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 48, .y = y3, .raw_x = 48, .raw_y = y3 });
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(n));
    try std.testing.expectEqual(@as(usize, 2), sig.peek()); // the signal round-trips
    try std.testing.expectEqual(@as(u32, 1), count); // on_change fired
    try std.testing.expect(input.isFocused(n)); // the click focused the group
    try std.testing.expectEqualStrings("Books", n.semantics.?.value); // a11y follows
    // keyboard: up wraps AND selects (skipping the disabled middle item)
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .up });
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n)); // wrapped from 2 (1 disabled)
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(n)); // 0 -> skips 1 -> 2
    try std.testing.expectEqual(@as(u32, 3), count);
    // the external signal moves the selection too
    sig.set(0);
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(n));
    try std.testing.expectEqualStrings("Home", n.semantics.?.value);
}

test "navigation_rail: semantics — role group, focusable, value follows the selection" {
    const a = std.testing.allocator;
    const n = try navigationRail(a, &.{ .{ .label = "A" }, .{ .label = "B" } }, null, null, .{ .selected = 1 });
    defer n.deinit();
    try std.testing.expectEqual(ui.semantics.Role.group, n.semantics.?.role);
    try std.testing.expect(n.semantics.?.focusable);
    try std.testing.expectEqualStrings("B", n.semantics.?.value);
    try std.testing.expectEqual(@as(usize, 1), selectedIndex(n));
}

test "golden: collapsed — the selected item paints the 56x56 circle indicator + OnSecondaryContainer icon" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try navigationRail(a, &.{
        .{ .label = "Home", .icon = .home },
        .{ .label = "Music", .icon = .play },
    }, null, null, .{ .selected = 0, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(a, 120, 200);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 96, .h = 180 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    // the rail background: surface
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(15, 15));
    // the first item's circle: centered (x = 10 + (96-56)/2 = 30), y = 10 + 44 = 54
    const cx = 10 + (96 - circle_d) / 2 + circle_d / 2;
    const cy = 10 + top_space + circle_d / 2;
    // the circle's interior (4dp inside the left edge — the edge itself is
    // AA'd and Skia's rrect fill rounding differs ±1): secondary_container
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(@as(i32, @intFromFloat(cx - circle_d / 2)) + 4, @intFromFloat(cy)));
    // the exact circle corner stays background (a circle, not a square)
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(@intFromFloat(cx - circle_d / 2), @intFromFloat(cy - circle_d / 2)));
    // the icon ink (on_secondary_container) at the center
    try std.testing.expect(f.countColorIn(.{ .x = cx - 12, .y = cy - 12, .w = 24, .h = 24 }, t.colors.on_secondary_container) > 0);
    // the second (unselected) item: no indicator — plain surface at its center
    const cy2 = 10 + top_space + (item_h + item_gap) + item_h / 2;
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(@intFromFloat(cx), @intFromFloat(cy2 - circle_d / 2)));
    // the unselected icon ink (on_surface_variant)
    try std.testing.expect(f.countColorIn(.{ .x = cx - 12, .y = cy2 - 12, .w = 24, .h = 24 }, t.colors.on_surface_variant) > 0);
}

test "golden: expanded — the selected item paints the pill (label_w + 64) at x = 20 + icon + label ink" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try navigationRail(a, &.{
        .{ .label = "Home", .icon = .home },
        .{ .label = "Music", .icon = .play },
    }, null, null, .{ .expanded = true, .selected = 1, .theme = t });
    defer n.deinit();
    const ls = t.type_scale.label_large;
    const lw = ui.paint.measureText("Music", ls.size, true).width;
    const pw = icon_size + icon_label_gap + lw + pill_icon_pad * 2;
    var r = try golden.Renderer.init(a, 300, 200);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 260, .h = 180 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    // the second item's row: y = 10 + 44 + 60 = 114
    const iy = 10 + top_space + (item_h + item_gap);
    // the pill: x = 10 + 20 = 30, w = pw, h = 56 → its interior midpoints
    // (4dp inside the edges — the edges themselves are AA'd)
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(34, @intFromFloat(iy + pill_h / 2)));
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(@as(i32, @intFromFloat(30 + pw)) - 4, @intFromFloat(iy + pill_h / 2)));
    // just past the pill: surface again
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(@as(i32, @intFromFloat(30 + pw)) + 4, @intFromFloat(iy + pill_h / 2)));
    // the icon ink (on_secondary_container) at pill_x + 16
    try std.testing.expect(f.countColorIn(.{ .x = 30 + pill_icon_pad, .y = iy + 16, .w = 24, .h = 24 }, t.colors.on_secondary_container) > 0);
    // the label ink (on_secondary_container, start-icon position) at icon_x + 32
    try std.testing.expect(f.countColorIn(.{ .x = 30 + pill_icon_pad + icon_size + icon_label_gap, .y = iy + 18, .w = lw, .h = 20 }, t.colors.on_secondary_container) > 0);
    // the first (unselected) item: no pill
    const iy0 = 10 + top_space;
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(30, @intFromFloat(iy0 + pill_h / 2)));
    // the unselected label ink (on_surface_variant)
    try std.testing.expect(f.countColorIn(.{ .x = 30 + pill_icon_pad + icon_size + icon_label_gap, .y = iy0 + 18, .w = 60, .h = 20 }, t.colors.on_surface_variant) > 0);
}

test "golden: a hovered item paints the OnSecondaryContainer state layer over the indicator" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try navigationRail(a, &.{ .{ .label = "Home", .icon = .home }, .{ .label = "Music", .icon = .play } }, null, null, .{ .selected = 0, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(a, 120, 200);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 96, .h = 180 });
    // hover the 2nd (unselected) item: y = 10 + 44 + 60 + 28
    const y2 = 10 + top_space + (item_h + item_gap) + item_h / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .enter, .x = 58, .y = y2 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    // the state layer: on_secondary_container @ 0.08 over the surface, at
    // the circle's left edge midpoint (the unselected indicator zone)
    const cx = 10 + (96 - circle_d) / 2;
    try golden.expectPixelApprox(f, @intFromFloat(cx), @intFromFloat(y2), golden.blendOver(theme_mod.stateLayer(t.colors.surface, t.colors.on_secondary_container, t.state.hover), 0xFFFFFFFF));
}

test "navigation_rail: hover_move re-resolves the item under the pointer" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try navigationRail(a, &.{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } }, null, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 96, .h = 400 });
    // hover the 1st item, then move across to the 3rd within the leaf
    router.dispatchPointer(n, .{ .phase = .move, .x = 48, .y = top_space + 10 });
    try std.testing.expectEqual(@as(i32, 0), stateOf(n).hovered);
    const y3 = top_space + 2 * (item_h + item_gap) + 10;
    router.dispatchPointer(n, .{ .phase = .move, .x = 48, .y = y3 });
    try std.testing.expectEqual(@as(i32, 2), stateOf(n).hovered);
    // moving above the items clears the highlight (leave)
    router.dispatchPointer(n, .{ .phase = .move, .x = 48, .y = 10 });
    try std.testing.expectEqual(@as(i32, -1), stateOf(n).hovered);
}

test "navigation_rail: RTL mirrors the expanded row (the icon sits at the end side)" {
    const a = std.testing.allocator;
    const i18n = try ui.i18n.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    const t = theme_mod.light;
    const n = try navigationRail(a, &.{.{ .label = "Home", .icon = .home }}, null, null, .{ .expanded = true, .selected = 0, .theme = t });
    defer n.deinit();
    const ls = t.type_scale.label_large;
    const lw = ui.paint.measureText("Home", ls.size, true).width;
    const pw = icon_size + icon_label_gap + lw + pill_icon_pad * 2;
    var r = try golden.Renderer.init(a, 300, 200);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 260, .h = 180 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(a);
    defer f.deinit();
    const iy = 10 + top_space;
    // the pill is mirrored: x = 10 + 260 - 20 - pw (interior midpoint — the
    // edges are AA'd)
    const pill_x = 10 + 260 - item_lead - pw;
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(@as(i32, @intFromFloat(pill_x)) + 4, @intFromFloat(iy + pill_h / 2)));
    // the icon ink moved to the end side (pill end - 16 - 24)
    try std.testing.expect(f.countColorIn(.{ .x = pill_x + pw - pill_icon_pad - icon_size, .y = iy + 16, .w = 24, .h = 24 }, t.colors.on_secondary_container) > 0);
}
