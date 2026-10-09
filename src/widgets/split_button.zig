// An M3E split button (filled style): a leading action button + a trailing
// toggle button (the dropdown arrow), joined with a 2dp gap; both are
// Primary/OnPrimary pills whose INNER corners (where they meet) are
// ExtraSmall (4dp).
//
// Spec: m3.material.io/components/split-buttons + Compose SplitButton.kt
// (SplitButtonLayout / SplitButtonDefaults.LeadingButton / TrailingButton)
// + SplitButton{XSmall,Small,Medium,Large,XLarge}Tokens:
//   - sizes (height / leading pad L+R / trailing icon / trailing pad L=R):
//     XS 32 / 12+10 / 22 / 13; S 40 / 16+12 / 22 / 13; M 56 / 24+24 / 26 / 15;
//     L 96 / 48+48 / 38 / 29; XL 136 / 64+64 / 50 / 43
//   - BetweenSpace = 2dp; LeadingButtonMinWidth = TrailingButtonMinWidth = 48
//   - leading button: label label_large + optional 20dp leading icon (8dp
//     gap), centered; trailing button: the trailing icon centered
//   - shapes: both CornerFull (pill = h/2) on the OUTER corners; the inner
//     corners (leading's end / trailing's start) = ExtraSmall 4dp. On
//     hover/pressed the inner corners morph to Medium 12dp (the M3E quirk —
//     v1 keeps them static, Phase 3)
//   - colors: filled = Primary container + OnPrimary content; disabled =
//     container OnSurface @ 0.10, content OnSurfaceVariant @ 0.38 (same as
//     the M3E filled button)
//   - state layer: OnPrimary @ hover 0.08 / focus 0.10 / pressed 0.12 over
//     the container, per half
//   - input: each half is its own press zone (a drag past the touch slop is
//     a scroll, not a press); Enter/Space fires the LEADING action (the
//     trailing half is pointer-only in v1 — two a11y actions land with the
//     action system)
//
// v1 deviations (documented, fixed later):
//   - Filled style only (tonal / elevated / outlined variants are
//     follow-ups — same structure, different colors).
//   - Static inner corners (no hover/press morph to Medium — Phase 3).
//   - No embedded menu: the trailing button fires `on_trailing` and the app
//     opens a menu (the M3E menu widget, PR D2).
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

pub const SplitButtonSize = enum { xsmall, small, medium, large, xlarge };

pub const SplitButtonOptions = struct {
    size: SplitButtonSize = .small,
    enabled: bool = true,
    label: []const u8 = "",
    /// Optional leading icon (20dp, in the label color; mirrors to the end
    /// side in RTL).
    leading_icon: ?icon_w.IconName = null,
    trailing_icon: icon_w.IconName = .arrow_down,
    theme: Theme = theme_mod.light,
};

/// Per-size tokens (SplitButton*Tokens).
const Dims = struct {
    height: f32,
    lead_pad_l: f32,
    lead_pad_r: f32,
    trail_icon: f32,
    trail_pad: f32,
};

fn dimsFor(size: SplitButtonSize) Dims {
    return switch (size) {
        .xsmall => .{ .height = 32, .lead_pad_l = 12, .lead_pad_r = 10, .trail_icon = 22, .trail_pad = 13 },
        .small => .{ .height = 40, .lead_pad_l = 16, .lead_pad_r = 12, .trail_icon = 22, .trail_pad = 13 },
        .medium => .{ .height = 56, .lead_pad_l = 24, .lead_pad_r = 24, .trail_icon = 26, .trail_pad = 15 },
        .large => .{ .height = 96, .lead_pad_l = 48, .lead_pad_r = 48, .trail_icon = 38, .trail_pad = 29 },
        .xlarge => .{ .height = 136, .lead_pad_l = 64, .lead_pad_r = 64, .trail_icon = 50, .trail_pad = 43 },
    };
}

const min_w: f32 = 48; // LeadingButtonMinWidth = TrailingButtonMinWidth
const between: f32 = 2; // BetweenSpace
const inner_corner: f32 = 4; // ExtraSmall (static in v1)
const lead_icon_size: f32 = 20; // ButtonSmallTokens.IconSize
const lead_icon_gap: f32 = 8;

const SplitState = struct {
    label: [:0]const u8, // owned
    opts: SplitButtonOptions,
    on_press: ?Callback = null,
    on_trailing: ?Callback = null,
    /// The pressed half: 0 = none, 1 = leading, 2 = trailing.
    pressed: u8 = 0,
    hovered: u8 = 0,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — gestures.SLOP).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
};

fn stateOf(n: *Node) *SplitState {
    return @ptrCast(@alignCast(n.state.?));
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

/// The trailing half's width (fixed: max(48, 2*pad + icon)).
fn trailWidth(s: *SplitState) f32 {
    const d = dimsFor(s.opts.size);
    return @max(min_w, d.trail_pad * 2 + d.trail_icon);
}

/// The press zone under the point: 0 = none, 1 = leading, 2 = trailing.
fn zoneAt(s: *SplitState, b: Rect, x: f32, y: f32) u8 {
    if (y < b.y or y >= b.y + b.h) return 0;
    const rtl = ui.i18n.direction() == .rtl;
    const lx = if (rtl) b.x + b.w - (x - b.x) else x; // the point in LTR space
    const tw = trailWidth(s);
    const lead_w = b.w - between - tw;
    if (lx < b.x + lead_w) return 1;
    return 2;
}

fn splitMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const t = s.opts.theme;
    const d = dimsFor(s.opts.size);
    const ls = t.type_scale.label_large;
    const bold = ls.weight >= 500;
    var lead_w = d.lead_pad_l + d.lead_pad_r + ui.paint.measureText(s.label, ls.size, bold).width;
    if (s.opts.leading_icon != null) lead_w += lead_icon_size + lead_icon_gap;
    lead_w = @max(lead_w, min_w);
    const tw = trailWidth(s);
    return c.constrain(.{ .w = lead_w + between + tw, .h = d.height });
}

fn splitLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: the halves are computed from the bounds at paint/hit
}

/// Paint an icon glyph centered in a size x size box.
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

fn splitPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const d = dimsFor(s.opts.size);
    const cs = t.colors;
    const rtl = ui.i18n.direction() == .rtl;
    const focused = input.isFocused(n);
    const half = b.h / 2; // CornerFull on the outer corners
    const tw = trailWidth(s);
    const lead_w = b.w - between - tw;
    // LTR: leading [0, lead_w), gap, trailing [lead_w + between, w)
    const lead_x = b.x;
    const trail_x = b.x + lead_w + between;
    const mirror = struct {
        fn f(bx: f32, bw: f32, x: f32, w: f32, rtl_flag: bool) f32 {
            return if (rtl_flag) bx + bw - (x - bx) - w else x;
        }
    }.f;
    const lx = mirror(b.x, b.w, lead_x, lead_w, rtl);
    const tx = mirror(b.x, b.w, trail_x, tw, rtl);
    const container: Color = if (s.opts.enabled) cs.primary else ui.paint.withAlphaScaled(cs.on_surface, 0.10);
    const fg: Color = if (s.opts.enabled) cs.on_primary else ui.paint.withAlphaScaled(cs.on_surface_variant, 0.38);
    const ls = t.type_scale.label_large;
    const bold = ls.weight >= 500;
    // --- the leading half: pill on the start side, ExtraSmall on the end
    {
        var tl: f32 = half;
        var tr: f32 = inner_corner;
        var br: f32 = inner_corner;
        var bl: f32 = half;
        if (rtl) {
            const t2 = tl;
            tl = tr;
            tr = t2;
            const b2 = bl;
            bl = br;
            br = b2;
        }
        if (container & 0xFF != 0) ui.paint.fillRRectCorners(ctx, lx, b.y, lead_w, b.h, tl, tr, br, bl, container);
        if (s.opts.enabled) {
            const alpha: f32 = if (s.pressed == 1)
                t.state.pressed
            else if (focused)
                t.state.focus
            else if (s.hovered == 1)
                t.state.hover
            else
                0;
            if (alpha > 0) {
                ui.paint.fillRRectCorners(ctx, lx, b.y, lead_w, b.h, tl, tr, br, bl, theme_mod.stateLayer(container, cs.on_primary, alpha));
            }
        }
        // content: [icon, gap, label] centered
        const lm = ui.paint.measureText(s.label, ls.size, bold);
        var content_w = lm.width;
        if (s.opts.leading_icon != null) content_w += lead_icon_size + lead_icon_gap;
        var cx = lx + (lead_w - content_w) / 2;
        const baseline = b.y + (b.h - lm.height) / 2 + lm.ascent;
        if (s.opts.leading_icon) |iname| {
            paintIcon(ctx, iname, cx, b.y + (b.h - lead_icon_size) / 2, lead_icon_size, fg);
            cx += lead_icon_size + lead_icon_gap;
        }
        ui.paint.text(ctx, s.label, cx, baseline, ls.size, bold, fg);
    }
    // --- the trailing half: ExtraSmall on the start side, pill on the end
    {
        var tl: f32 = inner_corner;
        var tr: f32 = half;
        var br: f32 = half;
        var bl: f32 = inner_corner;
        if (rtl) {
            const t2 = tl;
            tl = tr;
            tr = t2;
            const b2 = bl;
            bl = br;
            br = b2;
        }
        if (container & 0xFF != 0) ui.paint.fillRRectCorners(ctx, tx, b.y, tw, b.h, tl, tr, br, bl, container);
        if (s.opts.enabled) {
            const alpha: f32 = if (s.pressed == 2)
                t.state.pressed
            else if (focused)
                t.state.focus
            else if (s.hovered == 2)
                t.state.hover
            else
                0;
            if (alpha > 0) {
                ui.paint.fillRRectCorners(ctx, tx, b.y, tw, b.h, tl, tr, br, bl, theme_mod.stateLayer(container, cs.on_primary, alpha));
            }
        }
        paintIcon(ctx, s.opts.trailing_icon, tx + (tw - d.trail_icon) / 2, b.y + (b.h - d.trail_icon) / 2, d.trail_icon, fg);
    }
}

fn splitOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    const zone = zoneAt(s, n.bounds, ev.x, ev.y);
    switch (ev.phase) {
        .down => {
            if (zone == 0) return false;
            s.pressed = zone;
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            n.markDirty();
            return true;
        },
        .up => {
            const was = s.pressed;
            s.pressed = 0;
            n.markDirty();
            if (was != 0 and zone == was) {
                if (was == 1) {
                    if (s.on_press) |cb| cb.fn_ptr(cb.userdata);
                } else {
                    if (s.on_trailing) |cb| cb.fn_ptr(cb.userdata);
                }
            }
            return true;
        },
        .move => {
            // A drag beyond the touch slop is a scroll, not a press: cancel
            // the pressed state. The move is NOT claimed (return false) so
            // it keeps bubbling to scrollable ancestors.
            if (s.pressed != 0) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.pressed = 0;
                    n.markDirty();
                }
            }
            return false;
        },
        // the pointer went down outside while we held the capture: cancel
        .outside_down => {
            s.pressed = 0;
            n.markDirty();
            return true;
        },
        .enter => {
            s.hovered = zone;
            n.markDirty();
            return true;
        },
        .leave => {
            s.hovered = 0;
            n.markDirty();
            return true;
        },
        else => {},
    }
    return false;
}

/// Keyboard activation (Phase 2c): Enter/Space fire the LEADING action (the
/// primary action; the trailing half is pointer-only in v1).
fn splitOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            if (s.on_press) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        else => {},
    }
    return false;
}

fn splitDeinit(n: *Node) void {
    const s = stateOf(n);
    input.releaseNode(n);
    n.allocator.free(s.label);
    n.allocator.destroy(s);
}

const split_vtable = ui.node.VTable{
    .measure = splitMeasure,
    .layout = splitLayout,
    .paint = splitPaint,
    .deinit = splitDeinit,
    .on_pointer = splitOnPointer,
    .on_key = splitOnKey,
};

/// An M3E split button (filled style). The two halves are internal chrome
/// painted by the widget (a leaf — no document children). `on_press` fires
/// on a leading-half click (and on Enter/Space while focused);
/// `on_trailing` fires on a trailing-half click (the app opens a menu).
pub fn splitButton(allocator: std.mem.Allocator, on_press: ?Callback, on_trailing: ?Callback, opts: SplitButtonOptions) !*Node {
    const node = try Node.create(allocator, &split_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(SplitState);
    errdefer allocator.destroy(s);
    const label = try dupeZ(allocator, opts.label);
    errdefer allocator.free(label);
    s.* = .{
        .label = label,
        .opts = opts,
        .on_press = on_press,
        .on_trailing = on_trailing,
    };
    node.state = s;
    ui.semantics.attach(node, .{
        .role = .button,
        .label = s.label,
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
        .actions = ui.semantics.Actions.initOne(.activate),
    }); // Phase 2c
    return node;
}

// --- tests ---

fn pressCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "split_button: measures the two halves + the gap; the container height per size" {
    const a = std.testing.allocator;
    const n = try splitButton(a, null, null, .{ .label = "Save" });
    defer n.deinit();
    const t = theme_mod.light;
    const ls = t.type_scale.label_large;
    const d = dimsFor(.small);
    const lead_w = @max(min_w, d.lead_pad_l + d.lead_pad_r + ui.paint.measureText("Save", ls.size, true).width);
    const tw = @max(min_w, d.trail_pad * 2 + d.trail_icon);
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(lead_w + between + tw, sz.w, 0.001);
    try std.testing.expectEqual(d.height, sz.h);
    // every size's height
    const sizes = [_]SplitButtonSize{ .xsmall, .small, .medium, .large, .xlarge };
    const heights = [_]f32{ 32, 40, 56, 96, 136 };
    for (sizes, heights) |sz2, h| {
        const b = try splitButton(a, null, null, .{ .size = sz2, .label = "OK" });
        defer b.deinit();
        const m = b.measure(.{ .max_w = 4000, .max_h = 4000 });
        try std.testing.expectEqual(h, m.h);
    }
}

test "split_button: the leading and trailing halves fire their callbacks; keyboard fires the leading" {
    var lead: u32 = 0;
    var trail: u32 = 0;
    const cb_lead = Callback{ .fn_ptr = pressCounterCb, .userdata = &lead };
    const cb_trail = Callback{ .fn_ptr = pressCounterCb, .userdata = &trail };
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try splitButton(a, cb_lead, cb_trail, .{ .label = "Save" });
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    n.layout(.{ .x = 0, .y = 0, .w = sz.w, .h = sz.h });
    const tw = trailWidth(stateOf(n));
    const lead_w = sz.w - between - tw;
    // click the leading half
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = lead_w / 2, .y = 20, .raw_x = lead_w / 2, .raw_y = 20 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = lead_w / 2, .y = 20, .raw_x = lead_w / 2, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), lead);
    try std.testing.expectEqual(@as(u32, 0), trail);
    // click the trailing half
    const tx = lead_w + between + tw / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = tx, .y = 20, .raw_x = tx, .raw_y = 20 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = tx, .y = 20, .raw_x = tx, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), lead);
    try std.testing.expectEqual(@as(u32, 1), trail);
    // a click that crosses halves (down on leading, up on trailing) fires nothing
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = lead_w / 2, .y = 20, .raw_x = lead_w / 2, .raw_y = 20 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = tx, .y = 20, .raw_x = tx, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), lead);
    try std.testing.expectEqual(@as(u32, 1), trail);
    // keyboard: Enter fires the leading action
    input.requestFocus(n);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 2), lead);
    // disabled: no interaction
    const dis = try splitButton(a, cb_lead, cb_trail, .{ .label = "Save", .enabled = false });
    defer dis.deinit();
    dis.layout(.{ .x = 0, .y = 0, .w = sz.w, .h = sz.h });
    try std.testing.expect(!dis.vtable.on_pointer.?(dis, .{ .phase = .down, .x = lead_w / 2, .y = 20, .raw_x = lead_w / 2, .raw_y = 20 }));
}

test "golden: the split button paints two Primary halves with a gap and ExtraSmall inner corners" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try splitButton(a, null, null, .{ .label = "Save", .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 80);
    defer r.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    // integer width: the halves land on integer edges (exact corner pixels)
    n.layout(.{ .x = 20, .y = 20, .w = @round(sz.w), .h = sz.h });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const tw = trailWidth(stateOf(n));
    const lead_w = @round(sz.w) - between - tw;
    // the leading half's fill: Primary at its start side (clear of the
    // centered label ink)
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(24, 40));
    // the trailing half's fill: Primary near its end edge (clear of the
    // centered trailing icon)
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(20 + @as(i32, @intFromFloat(lead_w + between + tw)) - 4, 40));
    // the 2dp gap between the halves: background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20 + @as(i32, @intFromFloat(lead_w)) + 1, 40));
    // the leading half's outer (start) corner: pill (radius h/2 = 20) — the
    // exact corner stays background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20, 20));
    // the leading half's INNER (end) corner: ExtraSmall 4dp — the exact corner
    // is cut (background), 4dp down it is filled
    const lead_end = 20 + @as(i32, @intFromFloat(lead_w)); // the end edge
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(lead_end - 1, 20));
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(lead_end - 2, 24));
}

test "golden: a hovered trailing half paints the on_primary state layer" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try splitButton(a, null, null, .{ .label = "Save", .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 80);
    defer r.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    n.layout(.{ .x = 20, .y = 20, .w = sz.w, .h = sz.h });
    const tw = trailWidth(stateOf(n));
    const lead_w = sz.w - between - tw;
    const tx = lead_w + between + tw - 4; // near the trailing half's end edge (no icon ink)
    _ = n.vtable.on_pointer.?(n, .{ .phase = .enter, .x = 20 + tx, .y = 40 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try golden.expectPixelApprox(f, 20 + @as(i32, @intFromFloat(tx)), 40, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_primary, t.state.hover), t.colors.primary));
}

test "golden: a disabled split button paints the OnSurface@0.10 container + @0.38 content" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try splitButton(a, null, null, .{ .label = "Save", .enabled = false, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 80);
    defer r.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    n.layout(.{ .x = 20, .y = 20, .w = sz.w, .h = sz.h });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the container: on_surface @ 0.10 over the background (at the leading
    // half's start side — clear of the centered label ink)
    const cont = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.10), 0xFFFFFFFF);
    const tw = trailWidth(stateOf(n));
    const lead_w = sz.w - between - tw;
    try std.testing.expectEqual(cont, f.pixelAt(24, 40));
    // the label ink: on_surface_variant @ 0.38 over the container (a double
    // translucent blend — the raster's rounding is ±1, hence approx)
    const dis = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface_variant, 0.38), cont);
    try golden.expectPixelApprox(f, 38, 34, dis);
    try std.testing.expect(f.countColorApproxIn(.{ .x = 24, .y = 30, .w = lead_w, .h = 20 }, dis) > 0);
}
