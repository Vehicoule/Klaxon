// IconButton (Phase 2d.2 PR B1, M3E) — the four M3E icon button variants
// (standard / filled / filled tonal / outlined) in the five M3E sizes
// (XS 32 / S 40 / M 56 / L 96 / XL 136) and three widths (default / narrow /
// wide). Plain (sig = null) and toggle (sig drives the checked state).
//
// Spec: m3.material.io/components/icon-buttons (+ /specs) + Compose M3E
// (IconButton.kt / IconButtonDefaults.kt + IconButtonTokens /
// {Filled,FilledTonal,Outlined}IconButtonTokens / {XSmall,Small,Medium,Large,
// XLarge}IconButtonTokens):
//   - sizes: icon 20/24/24/32/40, container height 32/40/56/96/136
//   - widths (leading/trailing space): default 6/8/16/32/48, narrow 4/4/12/16/32,
//     wide 10/14/24/48/72 (XS/S/M/L/XL)
//   - shapes: round (default) = CornerFull (pill = h/2); square = CornerMedium
//     12 (XS/S), CornerLarge 16 (M), CornerExtraLarge 28 (L/XL)
//   - pressed morph: CornerSmall 8 (XS/S), CornerMedium 12 (M), CornerLarge 16
//     (L/XL)
//   - toggle morph (checked): selected round -> the square corner, selected
//     square -> CornerFull (the unselected/checked shapes swap)
//   - min target 48x48 (Compose minimumInteractiveComponentSize — a11y)
//   - colors: plain — filled Primary/OnPrimary, tonal
//     SecondaryContainer/OnSecondaryContainer, outlined transparent +
//     OutlineVariant border / OnSurfaceVariant, standard transparent /
//     OnSurfaceVariant; toggle — filled unselected SurfaceContainer/
//     OnSurfaceVariant -> checked Primary/OnPrimary, tonal unselected
//     SecondaryContainer/OnSecondaryContainer -> checked Secondary/OnSecondary,
//     standard transparent OnSurfaceVariant -> checked Primary, outlined
//     transparent + OutlineVariant -> checked InverseSurface/InverseOnSurface
//   - disabled: container OnSurface@0.10 (filled variants), icon
//     OnSurface@0.38, outlined border OutlineVariant@0.38
//   - state layers: the state's icon color @ hover 0.08 / focus 0.10 /
//     pressed 0.12 over the container (at alpha over a transparent container)
//
// v1 deviations (documented, fixed later):
//   - Flat colors (no elevation shadows — Phase 3); instant shape morphs.
//   - Checked + disabled (outlined toggle): container OnSurface@0.10, icon
//     OnSurface@0.38 (the token's SelectedDisabledContainer* + DisabledColor).
//   - The outlined border width follows the size token (1/1/1/2/3);
//     Compose's outlinedIconButtonBorder hardcodes the small 1dp.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const icon_w = @import("icon.zig");
const button_w = @import("button.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

pub const IconButtonVariant = enum { standard, filled, filled_tonal, outlined };
pub const IconButtonSize = enum { xsmall, small, medium, large, xlarge };
/// The horizontal padding family (Compose Leading/TrailingSpace per width).
pub const IconButtonWidth = enum { default, narrow, wide };

pub const IconButtonOptions = struct {
    variant: IconButtonVariant = .standard,
    size: IconButtonSize = .small,
    width: IconButtonWidth = .default,
    shape: button_w.ButtonShape = .round,
    enabled: bool = true,
    icon: icon_w.IconName = .star,
    /// The accessible name — an icon-only control has no visible label.
    a11y_label: []const u8 = "",
    theme: Theme = theme_mod.light,
};

/// Per-size measurement tokens (Compose *IconButtonTokens).
const Dims = struct {
    height: f32,
    icon: f32,
    space_default: f32, // leading = trailing
    space_narrow: f32,
    space_wide: f32,
    square_corner: f32,
    pressed_corner: f32,
    outline_width: f32,
};

fn dimsFor(size: IconButtonSize) Dims {
    return switch (size) {
        .xsmall => .{ .height = 32, .icon = 20, .space_default = 6, .space_narrow = 4, .space_wide = 10, .square_corner = 12, .pressed_corner = 8, .outline_width = 1 },
        .small => .{ .height = 40, .icon = 24, .space_default = 8, .space_narrow = 4, .space_wide = 14, .square_corner = 12, .pressed_corner = 8, .outline_width = 1 },
        .medium => .{ .height = 56, .icon = 24, .space_default = 16, .space_narrow = 12, .space_wide = 24, .square_corner = 16, .pressed_corner = 12, .outline_width = 1 },
        .large => .{ .height = 96, .icon = 32, .space_default = 32, .space_narrow = 16, .space_wide = 48, .square_corner = 28, .pressed_corner = 16, .outline_width = 2 },
        .xlarge => .{ .height = 136, .icon = 40, .space_default = 48, .space_narrow = 32, .space_wide = 72, .square_corner = 28, .pressed_corner = 16, .outline_width = 3 },
    };
}

/// Compose minimumInteractiveComponentSize — the a11y floor applies to the
/// HIT area (hit_bounds), never to the painted container.
const min_target: f32 = 48;

const IBColors = struct {
    container: Color, // unselected (plain: the fixed container)
    icon: Color,
    checked_container: Color, // toggle only
    checked_icon: Color,
    disabled_container: Color,
    disabled_icon: Color,
    outline: Color, // outlined variant only
    disabled_outline: Color,
};

fn variantColors(t: Theme, variant: IconButtonVariant, toggle: bool) IBColors {
    const cs = t.colors;
    const transparent: Color = 0x00000000;
    const dis_icon = ui.paint.withAlphaScaled(cs.on_surface, 0.38);
    const dis_container = ui.paint.withAlphaScaled(cs.on_surface, 0.10);
    const dis_outline = ui.paint.withAlphaScaled(cs.outline_variant, 0.38);
    if (!toggle) {
        return switch (variant) {
            .standard => .{ .container = transparent, .icon = cs.on_surface_variant, .checked_container = transparent, .checked_icon = cs.on_surface_variant, .disabled_container = transparent, .disabled_icon = dis_icon, .outline = transparent, .disabled_outline = transparent },
            .filled => .{ .container = cs.primary, .icon = cs.on_primary, .checked_container = cs.primary, .checked_icon = cs.on_primary, .disabled_container = dis_container, .disabled_icon = dis_icon, .outline = transparent, .disabled_outline = transparent },
            .filled_tonal => .{ .container = cs.secondary_container, .icon = cs.on_secondary_container, .checked_container = cs.secondary_container, .checked_icon = cs.on_secondary_container, .disabled_container = dis_container, .disabled_icon = dis_icon, .outline = transparent, .disabled_outline = transparent },
            .outlined => .{ .container = transparent, .icon = cs.on_surface_variant, .checked_container = transparent, .checked_icon = cs.on_surface_variant, .disabled_container = transparent, .disabled_icon = dis_icon, .outline = cs.outline_variant, .disabled_outline = dis_outline },
        };
    }
    // toggle: unselected -> checked colors per variant
    return switch (variant) {
        .standard => .{ .container = transparent, .icon = cs.on_surface_variant, .checked_container = transparent, .checked_icon = cs.primary, .disabled_container = transparent, .disabled_icon = dis_icon, .outline = transparent, .disabled_outline = transparent },
        .filled => .{ .container = cs.surface_container, .icon = cs.on_surface_variant, .checked_container = cs.primary, .checked_icon = cs.on_primary, .disabled_container = dis_container, .disabled_icon = dis_icon, .outline = transparent, .disabled_outline = transparent },
        .filled_tonal => .{ .container = cs.secondary_container, .icon = cs.on_secondary_container, .checked_container = cs.secondary, .checked_icon = cs.on_secondary, .disabled_container = dis_container, .disabled_icon = dis_icon, .outline = transparent, .disabled_outline = transparent },
        .outlined => .{ .container = transparent, .icon = cs.on_surface_variant, .checked_container = cs.inverse_surface, .checked_icon = cs.inverse_on_surface, .disabled_container = dis_container, .disabled_icon = dis_icon, .outline = cs.outline_variant, .disabled_outline = dis_outline },
    };
}

/// The colors of the current state: container, icon, and the state layer's
/// on-color (the icon color of the current state).
const CurrentColors = struct { container: Color, icon: Color, on: Color };

const IconButtonState = struct {
    opts: IconButtonOptions,
    /// null = plain button (fixed unselected colors); non-null = toggle (the
    /// checked state drives the colors + shape, the click flips it).
    sig: ?*ui.state.Signal(bool),
    on_pressed: ?Callback = null,
    pressed: bool = false,
    hovered: bool = false,
    /// The down position in raw (window) coordinates — drag deltas are
    /// physical finger motion, immune to the content scrolling under the
    /// finger (PointerEvent.raw_x/raw_y doc).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
};

fn stateOf(n: *Node) *IconButtonState {
    return @ptrCast(@alignCast(n.state.?));
}

fn isChecked(s: *IconButtonState) bool {
    return if (s.sig) |sig| sig.peek() else false;
}

fn currentColors(s: *IconButtonState, vc: IBColors) CurrentColors {
    if (!s.opts.enabled) return .{ .container = vc.disabled_container, .icon = vc.disabled_icon, .on = vc.disabled_icon };
    if (isChecked(s)) return .{ .container = vc.checked_container, .icon = vc.checked_icon, .on = vc.checked_icon };
    return .{ .container = vc.container, .icon = vc.icon, .on = vc.icon };
}

/// The corner radius for the current state (pressed > checked > unselected).
fn radiusFor(s: *IconButtonState, height: f32) f32 {
    const d = dimsFor(s.opts.size);
    if (s.pressed) return d.pressed_corner;
    if (isChecked(s)) {
        // toggle morph: selected round -> the square corner, selected square
        // -> CornerFull (the unselected/checked shapes swap)
        return if (s.opts.shape == .round) d.square_corner else height / 2;
    }
    return if (s.opts.shape == .round) height / 2 else d.square_corner;
}

fn iconButtonMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const d = dimsFor(s.opts.size);
    const sp = switch (s.opts.width) {
        .default => d.space_default,
        .narrow => d.space_narrow,
        .wide => d.space_wide,
    };
    // the painted container: icon + the width's spaces (the 48dp a11y floor
    // is the hit target, not the container — see iconButtonHitBounds)
    return c.constrain(.{ .w = d.icon + sp * 2, .h = d.height });
}

/// The interactive target: a 48x48 minimum centered on the container
/// (Compose minimumInteractiveComponentSize).
fn iconButtonHitBounds(n: *Node) Rect {
    const b = n.bounds;
    const w = @max(b.w, min_target);
    const h = @max(b.h, min_target);
    return .{ .x = b.x + (b.w - w) / 2, .y = b.y + (b.h - h) / 2, .w = w, .h = h };
}

fn iconButtonLayout(n: *Node, bounds: Rect) void {
    if (n.children.items.len == 0) return;
    // the icon is centered in the container
    const child = n.children.items[0];
    const cs = child.measure(.{ .max_w = bounds.w, .max_h = bounds.h });
    child.layout(.{
        .x = bounds.x + (bounds.w - cs.w) / 2,
        .y = bounds.y + (bounds.h - cs.h) / 2,
        .w = cs.w,
        .h = cs.h,
    });
}

fn iconButtonPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const d = dimsFor(s.opts.size);
    const vc = variantColors(t, s.opts.variant, s.sig != null);
    const cc = currentColors(s, vc);
    const radius = radiusFor(s, b.h);
    // container
    if (cc.container & 0xFF != 0) {
        ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, radius, cc.container);
    }
    // state layer (enabled only): the state's icon color blended over the
    // container — AT the state alpha over a transparent container (lerping
    // from transparent black would double-scale the RGB in src-over)
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
            const layer = if (cc.container & 0xFF == 0)
                ui.paint.withAlphaScaled(cc.on, alpha)
            else
                theme_mod.stateLayer(cc.container, cc.on, alpha);
            ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, radius, layer);
        }
    }
    // outline (outlined variant) — painted over the state layer
    if (s.opts.variant == .outlined) {
        const oc = if (s.opts.enabled) vc.outline else vc.disabled_outline;
        ui.paint.strokeRRect(ctx, b.x, b.y, b.w, b.h, radius, d.outline_width, oc);
    }
}

fn iconButtonOnPointer(n: *Node, ev: input.PointerEvent) bool {
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
                if (s.sig) |sig| sig.set(!sig.peek());
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

/// Keyboard activation (Phase 2c): Enter/Space press the focused control.
fn iconButtonOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            if (s.sig) |sig| sig.set(!sig.peek());
            if (s.on_pressed) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        else => {},
    }
    return false;
}

/// Signal-driven repaint + semantic checked sync + icon recolor (toggle).
fn iconButtonSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const vc = variantColors(s.opts.theme, s.opts.variant, true);
    const cc = currentColors(s, vc);
    if (n.children.items.len > 0) icon_w.setColor(n.children.items[0], cc.icon);
    if (n.semantics) |sem| sem.checked = s.sig.?.peek();
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the value changed
}

fn iconButtonDeinit(n: *Node) void {
    const s = stateOf(n);
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = iconButtonSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const icon_button_vtable = ui.node.VTable{
    .measure = iconButtonMeasure,
    .layout = iconButtonLayout,
    .paint = iconButtonPaint,
    .deinit = iconButtonDeinit,
    .on_pointer = iconButtonOnPointer,
    .on_key = iconButtonOnKey,
    .hit_bounds = iconButtonHitBounds,
};

/// An M3E icon button. `sig` = null → a plain button (fixed unselected
/// colors, role button); `sig` non-null → a toggle (the checked state drives
/// the colors + the shape morph, a click flips it, role toggle). `on_pressed`
/// fires on click (pointer up inside after a down) and on Enter/Space while
/// focused. The icon is internal chrome (decorative — the accessible name is
/// `a11y_label`).
pub fn iconButton(allocator: std.mem.Allocator, sig: ?*ui.state.Signal(bool), on_pressed: ?Callback, opts: IconButtonOptions) !*Node {
    const node = try Node.create(allocator, &icon_button_vtable);
    errdefer allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(IconButtonState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .sig = sig, .on_pressed = on_pressed };
    node.state = s;
    const vc = variantColors(opts.theme, opts.variant, sig != null);
    const cc = currentColors(s, vc);
    const ic = try icon_w.icon(allocator, opts.icon, .{
        .size = dimsFor(opts.size).icon,
        .color = cc.icon,
        .label = opts.a11y_label,
    });
    errdefer ic.deinit();
    ic.internal = true; // chrome: not document data (registry)
    ic.exclude_semantics = true; // decorative: the button's a11y_label is the name
    node.add(ic);
    if (sig) |sg| {
        ui.semantics.attach(node, .{
            .role = .toggle,
            .label = opts.a11y_label,
            .focusable = opts.enabled,
            .disabled = !opts.enabled,
            .checked = sg.peek(),
            .actions = ui.semantics.Actions.initOne(.activate),
        });
        sg.subscribe(.{ .callback = .{ .fn_ptr = iconButtonSyncCb, .userdata = node } }); // visual + semantic updates on set
    } else {
        ui.semantics.attach(node, .{
            .role = .button,
            .label = opts.a11y_label,
            .focusable = opts.enabled,
            .disabled = !opts.enabled,
            .actions = ui.semantics.Actions.initOne(.activate),
        });
    }
    return node;
}

// --- tests ---

fn pressCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "icon_button: sizes measure the container (icon + spaces, height token)" {
    const sizes = [_]IconButtonSize{ .xsmall, .small, .medium, .large, .xlarge };
    const heights = [_]f32{ 32, 40, 56, 96, 136 };
    for (sizes, heights) |sz, h| {
        const b = try iconButton(std.testing.allocator, null, null, .{ .size = sz, .a11y_label = "x" });
        defer b.deinit();
        const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
        const d = dimsFor(sz);
        try std.testing.expectEqual(h, m.h);
        try std.testing.expectEqual(d.icon + d.space_default * 2, m.w);
    }
}

test "icon_button: the 48dp a11y floor is the hit target, not the painted container" {
    const b = try iconButton(std.testing.allocator, null, null, .{ .size = .xsmall, .a11y_label = "x" });
    defer b.deinit();
    // XS default: 20 + 6*2 = 32 — the painted container stays 32x32
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(@as(f32, 32), m.w);
    try std.testing.expectEqual(@as(f32, 32), m.h);
    b.layout(.{ .x = 100, .y = 100, .w = 32, .h = 32 });
    // the hit target grows to 48x48, centered on the container
    const hb = b.vtable.hit_bounds.?(b);
    try std.testing.expectEqual(@as(f32, 48), hb.w);
    try std.testing.expectEqual(@as(f32, 48), hb.h);
    try std.testing.expectEqual(@as(f32, 100 - 8), hb.x); // (32-48)/2
    try std.testing.expectEqual(@as(f32, 100 - 8), hb.y);
    // a size above the floor keeps its bounds
    const big = try iconButton(std.testing.allocator, null, null, .{ .size = .medium, .a11y_label = "x" });
    defer big.deinit();
    big.layout(.{ .x = 0, .y = 0, .w = 56, .h = 56 });
    const hbb = big.vtable.hit_bounds.?(big);
    try std.testing.expectEqual(@as(f32, 56), hbb.w);
}

test "icon_button: the width families change the horizontal padding only" {
    const narrow = try iconButton(std.testing.allocator, null, null, .{ .size = .small, .width = .narrow, .a11y_label = "x" });
    defer narrow.deinit();
    const wide = try iconButton(std.testing.allocator, null, null, .{ .size = .small, .width = .wide, .a11y_label = "x" });
    defer wide.deinit();
    const def = try iconButton(std.testing.allocator, null, null, .{ .size = .small, .a11y_label = "x" });
    defer def.deinit();
    const mn = narrow.measure(.{ .max_w = 2000, .max_h = 2000 });
    const mw = wide.measure(.{ .max_w = 2000, .max_h = 2000 });
    const md = def.measure(.{ .max_w = 2000, .max_h = 2000 });
    // small: icon 24, spaces 8 (default) / 4 (narrow) / 14 (wide)
    try std.testing.expectEqual(@as(f32, 32), mn.w); // 24+8
    try std.testing.expectEqual(@as(f32, 52), mw.w); // 24+28
    try std.testing.expectEqual(@as(f32, 40), md.w); // 24+16
    // heights unchanged
    try std.testing.expectEqual(mn.h, md.h);
}

test "icon_button: the icon is centered in the container" {
    const b = try iconButton(std.testing.allocator, null, null, .{ .a11y_label = "x" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    const ic = b.children.items[0];
    try std.testing.expectEqual(@as(f32, 24), ic.bounds.w); // small icon token
    try std.testing.expectEqual(@as(f32, 12), ic.bounds.x); // (48-24)/2
    try std.testing.expectEqual(@as(f32, 12), ic.bounds.y);
}

test "icon_button: plain fires the callback; toggle flips its signal; disabled swallows input" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = pressCounterCb, .userdata = &count };
    // plain (sig = null): no flip, callback fires
    const plain = try iconButton(std.testing.allocator, null, cb, .{ .a11y_label = "x" });
    defer plain.deinit();
    plain.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    const on_pointer_plain = plain.vtable.on_pointer.?;
    _ = on_pointer_plain(plain, .{ .phase = .down, .x = 24, .y = 24, .raw_x = 24, .raw_y = 24 });
    _ = on_pointer_plain(plain, .{ .phase = .up, .x = 24, .y = 24, .raw_x = 24, .raw_y = 24 });
    try std.testing.expectEqual(@as(u32, 1), count);
    // toggle: the click flips the signal + fires the callback
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const tog = try iconButton(std.testing.allocator, sig, cb, .{ .a11y_label = "x" });
    defer tog.deinit();
    tog.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    const on_pointer = tog.vtable.on_pointer.?;
    _ = on_pointer(tog, .{ .phase = .down, .x = 24, .y = 24, .raw_x = 24, .raw_y = 24 });
    _ = on_pointer(tog, .{ .phase = .up, .x = 24, .y = 24, .raw_x = 24, .raw_y = 24 });
    try std.testing.expect(sig.peek());
    try std.testing.expectEqual(@as(u32, 2), count);
    // a drag past the slop cancels (a scroll, not a click)
    _ = on_pointer(tog, .{ .phase = .down, .x = 24, .y = 24, .raw_x = 24, .raw_y = 24 });
    _ = on_pointer(tog, .{ .phase = .move, .x = 24, .y = 50, .raw_x = 24, .raw_y = 50 });
    _ = on_pointer(tog, .{ .phase = .up, .x = 24, .y = 24, .raw_x = 24, .raw_y = 24 });
    try std.testing.expect(sig.peek()); // unchanged
    try std.testing.expectEqual(@as(u32, 2), count);
    // disabled: no toggle, no callback
    const dis = try iconButton(std.testing.allocator, sig, cb, .{ .enabled = false, .a11y_label = "x" });
    defer dis.deinit();
    dis.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    const on_pointer_dis = dis.vtable.on_pointer.?;
    try std.testing.expect(!on_pointer_dis(dis, .{ .phase = .down, .x = 24, .y = 24 }));
    try std.testing.expect(!on_pointer_dis(dis, .{ .phase = .up, .x = 24, .y = 24 }));
    try std.testing.expect(sig.peek());
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "icon_button: Enter/Space activate the focused control (keyboard)" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = pressCounterCb, .userdata = &count };
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try iconButton(std.testing.allocator, sig, cb, .{ .a11y_label = "x" });
    defer b.deinit();
    const on_key = b.vtable.on_key.?;
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .enter }));
    try std.testing.expect(sig.peek()); // toggled
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .space }));
    try std.testing.expect(!sig.peek()); // toggled back
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expect(!on_key(b, .{ .kind = .key_down, .key = .left }));
}

test "icon_button: semantics — toggle role + checked sync; plain role button; a11y_label" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const tog = try iconButton(std.testing.allocator, sig, null, .{ .a11y_label = "Favorite" });
    defer tog.deinit();
    try std.testing.expectEqual(ui.semantics.Role.toggle, tog.semantics.?.role);
    try std.testing.expectEqual(true, tog.semantics.?.checked);
    try std.testing.expectEqualStrings("Favorite", tog.semantics.?.label);
    // the checked state follows the signal
    sig.set(false);
    try std.testing.expectEqual(false, tog.semantics.?.checked);
    // plain: role button, activate action, no checked
    const plain = try iconButton(std.testing.allocator, null, null, .{ .a11y_label = "Search" });
    defer plain.deinit();
    try std.testing.expectEqual(ui.semantics.Role.button, plain.semantics.?.role);
    try std.testing.expect(plain.semantics.?.actions.contains(.activate));
    try std.testing.expectEqualStrings("Search", plain.semantics.?.label);
    try std.testing.expect(plain.semantics.?.checked == null);
    // disabled
    const dis = try iconButton(std.testing.allocator, null, null, .{ .enabled = false, .a11y_label = "x" });
    defer dis.deinit();
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
}

test "golden: filled icon button paints the primary circle (round = h/2)" {
    const t = theme_mod.light;
    const b = try iconButton(std.testing.allocator, null, null, .{ .variant = .filled, .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    b.layout(.{ .x = 8, .y = 8, .w = 48, .h = 48 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // inside the circle, off the glyph ink: primary
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(12, 32));
    // outside the circle (top-left corner is clipped by the 24px radius): bg
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(9, 9));
}

test "golden: outlined icon button strokes the outline_variant border, transparent inside" {
    const t = theme_mod.light;
    // square shape: the top edge is straight mid-span (a round circle's edge
    // is curved there — AA would blend the stroke into the bg)
    const b = try iconButton(std.testing.allocator, null, null, .{ .variant = .outlined, .shape = .square, .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    // half-pixel offset: the 1dp stroke is centered on the edge → pixel-aligned
    b.layout(.{ .x = 8.5, .y = 8.5, .w = 48, .h = 48 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the top border, mid-edge: outline_variant
    try std.testing.expectEqual(t.colors.outline_variant, f.pixelAt(32, 8));
    // inside, off the glyph ink: transparent → bg
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(12, 32));
}

test "golden: toggle — checked filled paints primary, unselected paints surface_container" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const b = try iconButton(std.testing.allocator, sig, null, .{ .variant = .filled, .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    b.layout(.{ .x = 8, .y = 8, .w = 48, .h = 48 });
    // checked: primary container
    r.paint(b, 0xFFFFFFFF);
    var f1 = try r.readback(std.testing.allocator);
    try std.testing.expectEqual(t.colors.primary, f1.pixelAt(12, 32));
    f1.deinit();
    // unselected: surface_container
    sig.set(false);
    r.paint(b, 0xFFFFFFFF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(t.colors.surface_container, f2.pixelAt(12, 32));
}

test "golden: disabled filled icon button paints the OnSurface@0.10 container" {
    const t = theme_mod.light;
    const b = try iconButton(std.testing.allocator, null, null, .{ .variant = .filled, .enabled = false, .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    b.layout(.{ .x = 8, .y = 8, .w = 48, .h = 48 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try golden.expectPixelApprox(f, 12, 32, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.10), 0xFFFFFFFF));
}
