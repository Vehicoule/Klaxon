// Button (Phase 2d.2 PR A, M3E) — the five M3E button variants (filled,
// filled tonal, elevated, outlined, text) in the five M3E sizes (XS 32,
// S 40, M 56, L 96, XL 136).
//
// Spec: m3.material.io/components/buttons (+ /specs) + Compose M3E tokens
// (BaselineButtonTokens / Button{XSmall,Small,Medium,Large,XLarge}Tokens /
// {Filled,FilledTonal,Elevated,Outlined,Text}ButtonTokens + Button.kt):
//   - sizes: heights 32/40/56/96/136, icon 20/20/24/32/40, icon-label gap
//     8/8/8/12/16, content padding (h/v) 12/6, 16/8, 24/16, 48/32, 64/48
//   - shapes: round (default) = CornerFull (pill = height/2); square =
//     CornerMedium 12 (XS/S), CornerLarge 16 (M), CornerExtraLarge 28 (L/XL)
//   - shape morph: pressed = CornerSmall 8 (XS/S), CornerMedium 12 (M),
//     CornerLarge 16 (L/XL) — both round and square buttons
//   - label styles: label_large (XS/S), title_medium (M), headline_small (L),
//     headline_large (XL); text variant horizontal padding 12 (end 16 with
//     a trailing icon slot)
//   - min width 58dp (small, Compose ButtonDefaults.MinWidth); min height =
//     the container height (all sizes)
//   - colors per variant (see variantColors); disabled: container OnSurface
//     @0.10 (0.12 tonal), label/icon OnSurfaceVariant @0.38 (OnSurface @0.38
//     tonal), outlined border OutlineVariant @0.10; tonal small icon = 18dp
//   - state layers: the on-color blended over the container at hover 0.08 /
//     focus 0.10 / pressed 0.12 (theme.state); over a transparent container
//     (outlined/text) the layer is the on-color AT that alpha (lerping from
//     transparent black would double-scale the RGB in the src-over blend)
//   - input: a drag past the touch slop (ui/gestures.SLOP, raw coords) is a
//     scroll, not a press — the pressed state is cancelled and the move keeps
//     bubbling to scrollable ancestors; outside_down cancels too
//   - layout: the content row mirrors in RTL (the leading icon moves to the
//     end side); the children paint clipped to the button's bounds (a
//     constrained button never lets label ink cross the container edge)
//
// v1 deviations (documented, fixed later):
//   - Elevation: v1 draws flat colors (the raster shadow pass lands Phase 3)
//     — elevated renders SurfaceContainerLow without a shadow; the hover
//     elevation change is a visual no-op.
//   - Shape morph on press is instant (the animated morph lands with the
//     animation system, Phase 3).
//   - Text button label = Primary per the m3.material.io spec (the Compose
//     token says OnSurfaceVariant — the spec wins, ADR-0010).
//   - Label weight: the Text widget has a bold flag, not a weight axis —
//     weight >= 500 renders bold (label_large / title_medium), 400 renders
//     regular (headline_small / headline_large).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const text_w = @import("text.zig");
const icon_w = @import("icon.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const EdgeInsets = ui.layout.EdgeInsets;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

pub const ButtonVariant = enum { filled, filled_tonal, elevated, outlined, text };
pub const ButtonSize = enum { xsmall, small, medium, large, xlarge };
/// round = CornerFull (pill); square = the size's corner token.
pub const ButtonShape = enum { round, square };

pub const ButtonOptions = struct {
    variant: ButtonVariant = .filled,
    size: ButtonSize = .small,
    shape: ButtonShape = .round,
    enabled: bool = true,
    /// The label text (null = icon-only button). Rendered as internal chrome
    /// with the variant's label style/color — not document data.
    label: ?[]const u8 = null,
    /// Accessible name for icon-only buttons (a11y). The visible label wins
    /// when both are set.
    a11y_label: ?[]const u8 = null,
    /// Optional leading icon (rendered at the size's icon token, in the
    /// label color; mirrors to the end side in RTL).
    icon: ?icon_w.IconName = null,
    theme: Theme = theme_mod.light,
};

/// Per-size measurement tokens (Compose Button*Tokens + Button.kt paddings).
const Dims = struct {
    height: f32,
    icon: f32,
    icon_gap: f32,
    h_padding: f32,
    v_padding: f32,
    square_corner: f32,
    pressed_corner: f32,
    outline_width: f32,
};

fn dimsFor(size: ButtonSize) Dims {
    return switch (size) {
        .xsmall => .{ .height = 32, .icon = 20, .icon_gap = 8, .h_padding = 12, .v_padding = 6, .square_corner = 12, .pressed_corner = 8, .outline_width = 1 },
        .small => .{ .height = 40, .icon = 20, .icon_gap = 8, .h_padding = 16, .v_padding = 8, .square_corner = 12, .pressed_corner = 8, .outline_width = 1 },
        .medium => .{ .height = 56, .icon = 24, .icon_gap = 8, .h_padding = 24, .v_padding = 16, .square_corner = 16, .pressed_corner = 12, .outline_width = 1 },
        .large => .{ .height = 96, .icon = 32, .icon_gap = 12, .h_padding = 48, .v_padding = 32, .square_corner = 28, .pressed_corner = 16, .outline_width = 2 },
        .xlarge => .{ .height = 136, .icon = 40, .icon_gap = 16, .h_padding = 64, .v_padding = 48, .square_corner = 28, .pressed_corner = 16, .outline_width = 3 },
    };
}

/// Compose ButtonDefaults.MinWidth (small buttons).
const min_width: f32 = 58;
/// FilledTonalButtonTokens.IconSize (the small tonal icon is 18dp).
const tonal_icon_small: f32 = 18;

const VariantColors = struct {
    container: Color, // enabled (transparent for outlined/text)
    on: Color, // label/icon color + the state layer's on-color
    disabled_container: Color,
    disabled_on: Color,
    outline: Color, // outlined variant only
    disabled_outline: Color,
};

fn variantColors(t: Theme, variant: ButtonVariant) VariantColors {
    const cs = t.colors;
    const transparent: Color = 0x00000000;
    return switch (variant) {
        .filled => .{
            .container = cs.primary,
            .on = cs.on_primary,
            .disabled_container = ui.paint.withAlphaScaled(cs.on_surface, 0.10),
            .disabled_on = ui.paint.withAlphaScaled(cs.on_surface_variant, 0.38),
            .outline = transparent,
            .disabled_outline = transparent,
        },
        .filled_tonal => .{
            .container = cs.secondary_container,
            .on = cs.on_secondary_container,
            .disabled_container = ui.paint.withAlphaScaled(cs.on_surface, 0.12),
            .disabled_on = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
            .outline = transparent,
            .disabled_outline = transparent,
        },
        .elevated => .{
            .container = cs.surface_container_low,
            .on = cs.primary,
            .disabled_container = ui.paint.withAlphaScaled(cs.on_surface, 0.10),
            .disabled_on = ui.paint.withAlphaScaled(cs.on_surface_variant, 0.38),
            .outline = transparent,
            .disabled_outline = transparent,
        },
        .outlined => .{
            .container = transparent,
            .on = cs.on_surface_variant,
            .disabled_container = transparent,
            .disabled_on = ui.paint.withAlphaScaled(cs.on_surface_variant, 0.38),
            .outline = cs.outline_variant,
            .disabled_outline = ui.paint.withAlphaScaled(cs.outline_variant, 0.10),
        },
        .text => .{
            .container = transparent,
            .on = cs.primary, // m3.material.io spec (Compose token: OnSurfaceVariant)
            .disabled_container = ui.paint.withAlphaScaled(cs.on_surface, 0.10),
            .disabled_on = ui.paint.withAlphaScaled(cs.on_surface_variant, 0.38),
            .outline = transparent,
            .disabled_outline = transparent,
        },
    };
}

/// The label's type style per size (Compose ButtonDefaults.textStyleFor).
fn labelStyle(t: Theme, size: ButtonSize) theme_mod.TypeStyle {
    return switch (size) {
        .xsmall, .small => t.type_scale.label_large,
        .medium => t.type_scale.title_medium,
        .large => t.type_scale.headline_small,
        .xlarge => t.type_scale.headline_large,
    };
}

/// Content padding (Compose ButtonDefaults.<Size>ContentPadding; the text
/// variant uses TextButtonContentPadding: 12 horizontal, end 16 with icon).
fn contentPadding(opts: ButtonOptions) EdgeInsets {
    const d = dimsFor(opts.size);
    if (opts.variant == .text) {
        return .{
            .left = 12,
            .top = d.v_padding,
            .right = if (opts.icon != null) 16 else 12,
            .bottom = d.v_padding,
        };
    }
    return .{ .left = d.h_padding, .top = d.v_padding, .right = d.h_padding, .bottom = d.v_padding };
}

const ButtonState = struct {
    opts: ButtonOptions,
    on_pressed: ?Callback = null,
    pressed: bool = false,
    hovered: bool = false,
    /// The down position in raw (window) coordinates — drag deltas are
    /// physical finger motion, immune to the content scrolling under the
    /// finger (PointerEvent.raw_x/raw_y doc).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
};

fn stateOf(n: *Node) *ButtonState {
    return @ptrCast(@alignCast(n.state.?));
}

fn buttonMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const d = dimsFor(s.opts.size);
    const pad = contentPadding(s.opts);
    var content_w: f32 = 0;
    var content_h: f32 = 0;
    var first = true;
    for (n.children.items) |child| {
        const cs = child.measure(c.deflateEdge(pad));
        if (!first) content_w += d.icon_gap;
        content_w += cs.w;
        content_h = @max(content_h, cs.h);
        first = false;
    }
    var size = Size{ .w = content_w + pad.hSum(), .h = content_h + pad.vSum() };
    size.h = @max(size.h, d.height); // the container height is the minimum
    if (s.opts.size == .small) size.w = @max(size.w, min_width);
    return c.constrain(size);
}

fn buttonLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    const d = dimsFor(s.opts.size);
    const pad = contentPadding(s.opts);
    const inner = Rect{
        .x = bounds.x + pad.left,
        .y = bounds.y + pad.top,
        .w = @max(0, bounds.w - pad.hSum()),
        .h = @max(0, bounds.h - pad.vSum()),
    };
    // the content row: [icon, gap, label], centered in the padded box
    var sizes: [2]Size = .{ .{}, .{} };
    var content_w: f32 = 0;
    var content_h: f32 = 0;
    var count: usize = 0;
    for (n.children.items) |child| {
        const cs = child.measure(.{ .max_w = inner.w, .max_h = inner.h });
        sizes[count] = cs;
        content_w += cs.w;
        content_h = @max(content_h, cs.h);
        count += 1;
    }
    if (count > 1) content_w += d.icon_gap;
    var x = inner.x + (inner.w - content_w) / 2;
    for (n.children.items, 0..) |child, i| {
        const cs = sizes[i];
        child.layout(.{
            .x = x,
            .y = inner.y + (inner.h - cs.h) / 2,
            .w = cs.w,
            .h = cs.h,
        });
        x += cs.w;
        if (i + 1 < count) x += d.icon_gap;
    }
    // RTL: mirror the row around the inner box — the leading icon moves to
    // the end side (the gap is preserved)
    if (ui.i18n.direction() == .rtl) {
        for (n.children.items) |child| {
            child.bounds.x = inner.x + inner.w - (child.bounds.x - inner.x) - child.bounds.w;
        }
    }
}

/// The children (icon + label) paint clipped to the button's bounds: a
/// constrained button never lets its label ink cross the container edge.
fn buttonPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    ui.paint.clipRect(ctx, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h); // saves
}

fn buttonPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.clipReset(ctx); // restores
}

fn buttonPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const d = dimsFor(s.opts.size);
    const vc = variantColors(t, s.opts.variant);
    // shape morph: pressed = the pressed corner (round and square alike)
    const radius: f32 = if (s.pressed)
        d.pressed_corner
    else if (s.opts.shape == .round)
        b.h / 2 // CornerFull = pill
    else
        d.square_corner;
    // container
    const container = if (s.opts.enabled) vc.container else vc.disabled_container;
    if (container & 0xFF != 0) {
        ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, radius, container);
    }
    // state layer (enabled only): the on-color blended over the container.
    // Over a transparent container (outlined/text) the layer is the on-color
    // AT the state alpha — lerping from transparent black would scale the
    // RGB by the alpha twice in the src-over blend.
    if (s.opts.enabled) {
        const alpha: f32 = if (s.pressed)
            t.state.pressed
        else if (input.isFocused(n))
            t.state.focus
        else if (s.hovered)
            t.state.hover
        else
            0;
        if (alpha > 0) {
            const layer = if (container & 0xFF == 0)
                ui.paint.withAlphaScaled(vc.on, alpha)
            else
                theme_mod.stateLayer(container, vc.on, alpha);
            ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, radius, layer);
        }
    }
    // outline (outlined variant) — painted over the state layer
    if (s.opts.variant == .outlined) {
        const oc = if (s.opts.enabled) vc.outline else vc.disabled_outline;
        ui.paint.strokeRRect(ctx, b.x, b.y, b.w, b.h, radius, d.outline_width, oc);
    }
}

fn buttonOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    switch (ev.phase) {
        .down => {
            s.pressed = true;
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            n.markDirty();
            return true;
        },
        .up => {
            // Click = down + up on the same node (the router captured us).
            // A cancelled press (outside_down, or a drag past the touch
            // slop) must not fire on a later up.
            const was_pressed = s.pressed;
            s.pressed = false;
            n.markDirty();
            if (was_pressed and n.bounds.contains(ev.x, ev.y)) {
                if (s.on_pressed) |cb| cb.fn_ptr(cb.userdata);
            }
            return true;
        },
        .move => {
            // A drag beyond the touch slop is a scroll, not a press: cancel
            // the pressed state. The move is NOT claimed (return false) so
            // it keeps bubbling to scrollable ancestors (scroll_util.zig).
            if (s.pressed) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.pressed = false;
                    n.markDirty();
                }
            }
            return false;
        },
        // the pointer went down outside while we held the capture: cancel
        .outside_down => {
            s.pressed = false;
            n.markDirty();
            return true;
        },
        .enter => {
            s.hovered = true;
            n.markDirty();
            return true;
        },
        .leave => {
            s.hovered = false;
            n.markDirty();
            return true;
        },
        else => {},
    }
    return false;
}

/// Keyboard activation (Phase 2c): Enter/Space press the focused button.
fn buttonOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            if (s.on_pressed) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        else => {},
    }
    return false;
}

fn buttonDeinit(n: *Node) void {
    input.releaseNode(n);
    n.allocator.destroy(stateOf(n));
}

const button_vtable = ui.node.VTable{
    .measure = buttonMeasure,
    .layout = buttonLayout,
    .paint = buttonPaint,
    .deinit = buttonDeinit,
    .on_pointer = buttonOnPointer,
    .on_key = buttonOnKey,
    .pre_children_paint = buttonPreChildrenPaint,
    .post_children_paint = buttonPostChildrenPaint,
};

/// An M3E button. `on_pressed` fires on click (pointer up inside after a
/// down) and on Enter/Space while focused. The label and icon are internal
/// chrome built from the options (styled per the variant) — they are not
/// document children.
pub fn button(allocator: std.mem.Allocator, on_pressed: ?Callback, opts: ButtonOptions) !*Node {
    const node = try Node.create(allocator, &button_vtable);
    errdefer allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(ButtonState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .on_pressed = on_pressed };
    node.state = s;
    const t = opts.theme;
    const d = dimsFor(opts.size);
    const vc = variantColors(t, opts.variant);
    const fg = if (opts.enabled) vc.on else vc.disabled_on;
    const ic = if (opts.icon) |iname| try icon_w.icon(allocator, iname, .{
        .size = if (opts.variant == .filled_tonal and opts.size == .small) tonal_icon_small else d.icon,
        .color = fg,
    }) else null;
    errdefer if (ic) |icn| icn.deinit();
    const txt = if (opts.label) |label| try text_w.text(allocator, label, .{
        .size = labelStyle(t, opts.size).size,
        .color = fg,
        .bold = labelStyle(t, opts.size).weight >= 500,
    }) else null;
    errdefer if (txt) |txtn| txtn.deinit();
    if (ic) |icn| {
        icn.internal = true; // chrome: not document data (registry)
        icn.exclude_semantics = true; // decorative: the button's label is the a11y name
        node.add(icn);
    }
    if (txt) |txtn| {
        txtn.internal = true;
        node.add(txtn);
    }
    ui.semantics.attach(node, .{
        .role = .button,
        .label = opts.label orelse opts.a11y_label orelse "",
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
        .actions = ui.semantics.Actions.initOne(.activate),
    });
    return node;
}

// --- tests ---

fn pressCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "button: every size measures its M3E container height (minimum)" {
    const sizes = [_]ButtonSize{ .xsmall, .small, .medium, .large, .xlarge };
    for (sizes) |sz| {
        const b = try button(std.testing.allocator, null, .{ .size = sz, .label = "OK" });
        defer b.deinit();
        const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
        try std.testing.expectEqual(dimsFor(sz).height, m.h);
    }
}

test "button: small hugs the content + 16dp padding and enforces the 58dp min width" {
    const b = try button(std.testing.allocator, null, .{ .label = "Add to cart" });
    defer b.deinit();
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    // label_large (14, weight 500 → bold) + 16dp horizontal padding
    const tw = ui.paint.measureText("Add to cart", 14, true).width;
    try std.testing.expect(tw + 32 > min_width); // this label exceeds the min width
    try std.testing.expectEqual(tw + 32, m.w);
    // a short label clamps to the 58dp min width
    const short = try button(std.testing.allocator, null, .{ .label = "OK" });
    defer short.deinit();
    const ms = short.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(min_width, ms.w);
    // an empty small button still measures the 58dp min width
    const empty = try button(std.testing.allocator, null, .{});
    defer empty.deinit();
    const me = empty.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(min_width, me.w);
    try std.testing.expectEqual(@as(f32, 40), me.h);
}

test "button: icon + label lay out centered with the size's icon gap" {
    const b = try button(std.testing.allocator, null, .{ .label = "OK", .icon = .star });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 200, .h = 40 });
    try std.testing.expectEqual(@as(usize, 2), b.children.items.len);
    const ic = b.children.items[0];
    const lb = b.children.items[1];
    try std.testing.expectEqual(@as(f32, 20), ic.bounds.w); // small icon token
    try std.testing.expectEqual(@as(f32, 20), ic.bounds.h);
    // the row [icon, 8, label] is centered in the padded box (200-32 wide)
    const content_w = ic.bounds.w + 8 + lb.bounds.w;
    try std.testing.expectEqual(16 + (168 - content_w) / 2, ic.bounds.x);
    try std.testing.expectEqual(ic.bounds.x + 20 + 8, lb.bounds.x);
    // vertically centered in the padded box (40-16 high)
    try std.testing.expectEqual(8 + (24 - 20) / 2, ic.bounds.y);
    try std.testing.expectEqual(8 + (24 - lb.bounds.h) / 2, lb.bounds.y);
}

test "button: press fires the callback; release outside does not; outside_down cancels" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = pressCounterCb, .userdata = &count };
    const b = try button(std.testing.allocator, cb, .{ .label = "OK" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 100, .h = 40 });
    const on_pointer = b.vtable.on_pointer.?;
    // down + up inside → fired
    _ = on_pointer(b, .{ .phase = .down, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    try std.testing.expect(stateOf(b).pressed);
    _ = on_pointer(b, .{ .phase = .up, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expect(!stateOf(b).pressed);
    // down inside, up outside → not fired
    _ = on_pointer(b, .{ .phase = .down, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    _ = on_pointer(b, .{ .phase = .up, .x = 500, .y = 20, .raw_x = 500, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), count);
    // down, then the pointer goes down outside (capture held): the press is
    // cancelled and a later up must not fire
    _ = on_pointer(b, .{ .phase = .down, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    try std.testing.expect(stateOf(b).pressed);
    _ = on_pointer(b, .{ .phase = .outside_down, .x = 500, .y = 20, .raw_x = 500, .raw_y = 20 });
    try std.testing.expect(!stateOf(b).pressed);
    _ = on_pointer(b, .{ .phase = .up, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), count);
    // a drag past the touch slop is a scroll: the press is cancelled and the
    // move is NOT claimed (bubbles to scrollable ancestors)
    _ = on_pointer(b, .{ .phase = .down, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    try std.testing.expect(stateOf(b).pressed);
    try std.testing.expect(!on_pointer(b, .{ .phase = .move, .x = 50, .y = 40, .raw_x = 50, .raw_y = 40 })); // 20px > slop
    try std.testing.expect(!stateOf(b).pressed);
    _ = on_pointer(b, .{ .phase = .up, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), count);
    // a small move within the slop keeps the press
    _ = on_pointer(b, .{ .phase = .down, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    _ = on_pointer(b, .{ .phase = .move, .x = 53, .y = 23, .raw_x = 53, .raw_y = 23 }); // ~4px < slop
    try std.testing.expect(stateOf(b).pressed);
    _ = on_pointer(b, .{ .phase = .up, .x = 50, .y = 20, .raw_x = 50, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 2), count);
    // hover notifications toggle the hovered state
    _ = on_pointer(b, .{ .phase = .enter, .x = 50, .y = 20 });
    try std.testing.expect(stateOf(b).hovered);
    _ = on_pointer(b, .{ .phase = .leave, .x = 50, .y = 20 });
    try std.testing.expect(!stateOf(b).hovered);
}

test "button: icon-only buttons take their accessible name from a11y_label" {
    const b = try button(std.testing.allocator, null, .{ .icon = .star, .a11y_label = "Favorite" });
    defer b.deinit();
    try std.testing.expectEqualStrings("Favorite", b.semantics.?.label);
    try std.testing.expect(b.semantics.?.focusable);
    // no label, no a11y_label: empty name (the caller's responsibility)
    const bare = try button(std.testing.allocator, null, .{ .icon = .star });
    defer bare.deinit();
    try std.testing.expectEqualStrings("", bare.semantics.?.label);
    // the visible label wins over a11y_label
    const both = try button(std.testing.allocator, null, .{ .label = "OK", .a11y_label = "Other" });
    defer both.deinit();
    try std.testing.expectEqualStrings("OK", both.semantics.?.label);
}

test "button: RTL mirrors the content row (the leading icon moves to the end side)" {
    const i18n = try ui.i18n.I18n.init(std.testing.allocator, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    const b = try button(std.testing.allocator, null, .{ .label = "OK", .icon = .star });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 200, .h = 40 });
    const ic = b.children.items[0];
    const lb = b.children.items[1];
    // mirrored: the label is on the start (left) side, the icon on the end
    // (right) side, the 8dp gap preserved
    try std.testing.expect(ic.bounds.x > lb.bounds.x);
    try std.testing.expectEqual(lb.bounds.x + lb.bounds.w + 8, ic.bounds.x);
}

test "button: disabled swallows pointer input and fires nothing" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = pressCounterCb, .userdata = &count };
    const b = try button(std.testing.allocator, cb, .{ .label = "OK", .enabled = false });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 100, .h = 40 });
    const on_pointer = b.vtable.on_pointer.?;
    try std.testing.expect(!on_pointer(b, .{ .phase = .down, .x = 50, .y = 20 }));
    try std.testing.expect(!on_pointer(b, .{ .phase = .up, .x = 50, .y = 20 }));
    try std.testing.expect(!on_pointer(b, .{ .phase = .enter, .x = 50, .y = 20 }));
    try std.testing.expectEqual(@as(u32, 0), count);
    try std.testing.expect(!stateOf(b).pressed);
    try std.testing.expect(!stateOf(b).hovered);
}

test "button: Enter/Space activate the focused button (keyboard)" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = pressCounterCb, .userdata = &count };
    const b = try button(std.testing.allocator, cb, .{ .label = "OK" });
    defer b.deinit();
    const on_key = b.vtable.on_key.?;
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .enter }));
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .space }));
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expect(!on_key(b, .{ .kind = .key_down, .key = .left }));
    try std.testing.expect(!on_key(b, .{ .kind = .text_input, .key = .enter, .text = "x" }));
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "button: semantics — role button, focusable, disabled flag, activate action" {
    const b = try button(std.testing.allocator, null, .{ .label = "OK" });
    defer b.deinit();
    const sem = b.semantics.?;
    try std.testing.expectEqual(ui.semantics.Role.button, sem.role);
    try std.testing.expect(sem.focusable);
    try std.testing.expect(!sem.disabled);
    try std.testing.expectEqualStrings("OK", sem.label);
    try std.testing.expect(sem.actions.contains(.activate));
    const d = try button(std.testing.allocator, null, .{ .label = "OK", .enabled = false });
    defer d.deinit();
    try std.testing.expect(!d.semantics.?.focusable);
    try std.testing.expect(d.semantics.?.disabled);
}

test "golden: filled button paints the primary pill (round = height/2)" {
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    b.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // inside the pill, in the left padding zone (no label ink): primary
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(14, 30));
    // outside the pill: the top-left corner is clipped by the 20px radius
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(11, 11));
}

test "golden: outlined button strokes the outline_variant border, transparent inside" {
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .variant = .outlined, .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    // half-pixel offset: the 1dp stroke is centered on the edge → pixel-aligned
    b.layout(.{ .x = 10.5, .y = 10.5, .w = 100, .h = 40 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the top border, mid-edge: outline_variant
    try std.testing.expectEqual(t.colors.outline_variant, f.pixelAt(60, 10));
    // inside, away from the label ink: the container is transparent → bg
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(14, 30));
}

test "golden: hover paints the 0.08 state layer over the container" {
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    b.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    _ = b.vtable.on_pointer.?(b, .{ .phase = .enter, .x = 50, .y = 30 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try std.testing.expectEqual(
        theme_mod.stateLayer(t.colors.primary, t.colors.on_primary, t.state.hover),
        f.pixelAt(14, 30),
    );
}

test "golden: pressed morphs the round button to the pressed corner (8dp small)" {
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    b.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    // unpressed (radius 20): the (3,3) corner is outside the pill → bg
    r.paint(b, 0xFFFFFFFF);
    var f1 = try r.readback(std.testing.allocator);
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f1.pixelAt(13, 13));
    f1.deinit();
    // pressed (radius 8 + the 0.12 state layer): the corner is inside
    _ = b.vtable.on_pointer.?(b, .{ .phase = .down, .x = 50, .y = 30 });
    r.paint(b, 0xFFFFFFFF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(
        theme_mod.stateLayer(t.colors.primary, t.colors.on_primary, t.state.pressed),
        f2.pixelAt(13, 13),
    );
}

test "golden: disabled filled button paints the OnSurface@0.10 container" {
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .label = "OK", .enabled = false, .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    b.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    r.paint(b, 0xFFFFFFFF); // white bg
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // src-over blend of on_surface@0.10 over white
    try golden.expectPixelApprox(f, 14, 30, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.10), 0xFFFFFFFF));
}

test "golden: text button hover paints the on-color at the state alpha (transparent container)" {
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .variant = .text, .label = "OK", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    b.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    _ = b.vtable.on_pointer.?(b, .{ .phase = .enter, .x = 50, .y = 30 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the layer is primary AT 0.08 (NOT lerped from transparent black — the
    // RGB must stay the full primary in the src-over blend)
    try golden.expectPixelApprox(f, 14, 30, golden.blendOver(ui.paint.withAlphaScaled(t.colors.primary, t.state.hover), 0xFFFFFFFF));
}

test "golden: a constrained button clips its label ink to the container bounds" {
    const t = theme_mod.light;
    const b = try button(std.testing.allocator, null, .{ .label = "Add to cart", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 120, 60);
    defer r.deinit();
    // 60 wide: the label's natural width (~70px) overflows the bounds
    b.layout(.{ .x = 10, .y = 10, .w = 60, .h = 40 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // just outside the right edge: no label ink (the children paint clipped)
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(72, 30));
}
