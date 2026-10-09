// Switch (Phase 2d.2 PR B2, M3E) — the M3E switch (icon-less variant).
//
// Spec: m3.material.io/components/switch + Compose SwitchTokens / Switch.kt:
//   - track 52x32 (TrackWidth/Height), CornerFull (pill), outline 2dp when
//     unchecked (TrackOutlineWidth)
//   - handle (CornerFull circle): unchecked 16x16 at x=8 (minBound =
//     (32-16)/2), checked 24x24 at x=24 (maxBound = (52-24)-4), pressed 28x28
//     (checked → maxBound-2, unchecked → TrackOutlineWidth); vertically
//     centered (y = (32-w)/2)
//   - colors: unchecked — track SurfaceContainerHighest + outline Outline,
//     handle Outline (hover/pressed: OnSurfaceVariant); checked — track
//     Primary, handle OnPrimary (hover/pressed: PrimaryContainer); disabled
//     checked — track OnSurface@0.12, handle Surface; disabled unchecked —
//     track SurfaceContainerHighest, outline OnSurface@0.38, handle
//     OnSurface@0.38
//   - state layer: a 40dp circle (StateLayerSize) centered on the handle,
//     the handle color @ hover 0.08 / focus 0.10 / pressed 0.12
//   - hit target: max(52,48) x max(32,48) centered on the track (the a11y
//     floor is the hit area)
//   - RTL: the track mirrors (the checked handle moves to the start side)
//
// v1 deviations (documented, fixed later):
//   - No icon variant (the M3E switch with a check/cross icon in the handle
//     lands with the icon system); the handle grow/shrink animation lands
//     with Phase 3 (v1 switches sizes instantly).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

/// M3E measurement tokens (SwitchTokens + Switch.kt).
const track_w: f32 = 52;
const track_h: f32 = 32;
const outline_width: f32 = 2;
const handle_off: f32 = 16; // UnselectedHandleWidth/Height
const handle_on: f32 = 24; // SelectedHandleWidth/Height
const handle_pressed: f32 = 28; // PressedHandleWidth/Height
const state_layer_size: f32 = 40;
/// Compose minimumInteractiveComponentSize (the a11y hit-target floor).
const min_target: f32 = 48;

pub const SwitchOptions = struct {
    enabled: bool = true,
    /// The accessible name (a switch is usually paired with a visible label
    /// built by the app; this is the control's own name).
    a11y_label: []const u8 = "",
    theme: Theme = theme_mod.light,
};

const SwitchState = struct {
    opts: SwitchOptions,
    sig: *ui.state.Signal(bool),
    on_changed: ?Callback = null,
    pressed: bool = false,
    hovered: bool = false,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — see PointerEvent.raw_x/raw_y).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
};

fn stateOf(n: *Node) *SwitchState {
    return @ptrCast(@alignCast(n.state.?));
}

fn isChecked(s: *SwitchState) bool {
    return s.sig.peek();
}

/// The track color, outline color, handle color and the state layer's
/// on-color for the current state.
const SWColors = struct { track: Color, outline: Color, handle: Color, on: Color };

fn currentColors(n: *Node, s: *SwitchState) SWColors {
    const cs = s.opts.theme.colors;
    if (!s.opts.enabled) {
        if (isChecked(s)) {
            return .{ .track = ui.paint.withAlphaScaled(cs.on_surface, 0.12), .outline = 0x00000000, .handle = cs.surface, .on = cs.surface };
        }
        return .{
            .track = cs.surface_container_highest,
            .outline = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
            .handle = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
            .on = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
        };
    }
    const interacting = s.hovered or s.pressed or input.isFocused(n);
    if (isChecked(s)) {
        const h = if (interacting) cs.primary_container else cs.on_primary;
        return .{ .track = cs.primary, .outline = 0x00000000, .handle = h, .on = h };
    }
    const h = if (interacting) cs.on_surface_variant else cs.outline;
    return .{ .track = cs.surface_container_highest, .outline = cs.outline, .handle = h, .on = h };
}

/// The handle's rect (the Switch.kt thumb layout: minBound/maxBound, pressed
/// offsets, vertically centered; mirrored in RTL).
fn handleRect(n: *Node, s: *SwitchState) Rect {
    _ = n;
    const on = isChecked(s);
    const w: f32 = if (s.pressed) handle_pressed else if (on) handle_on else handle_off;
    const x: f32 = if (s.pressed)
        (if (on) track_w - handle_on - 4 - outline_width else outline_width) // maxBound-2 / TrackOutlineWidth
    else if (on)
        track_w - handle_on - 4 // maxBound
    else
        (track_h - handle_off) / 2; // minBound
    const xr = if (ui.i18n.direction() == .rtl) track_w - x - w else x;
    return .{ .x = xr, .y = (track_h - w) / 2, .w = w, .h = w };
}

fn switchMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = track_w, .h = track_h });
}

/// The interactive target: max(52,48) x max(32,48) centered on the track.
fn switchHitBounds(n: *Node) Rect {
    const b = n.bounds;
    const w = @max(b.w, min_target);
    const h = @max(b.h, min_target);
    return .{ .x = b.x + (b.w - w) / 2, .y = b.y + (b.h - h) / 2, .w = w, .h = h };
}

fn switchPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const cc = currentColors(n, s);
    // track (pill)
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, track_h / 2, cc.track);
    if (cc.outline & 0xFF != 0) {
        ui.paint.strokeRRect(ctx, b.x, b.y, b.w, b.h, track_h / 2, outline_width, cc.outline);
    }
    // handle (absolute within the track; mirrored by handleRect for RTL)
    const hr = handleRect(n, s);
    const h = Rect{ .x = b.x + hr.x, .y = b.y + hr.y, .w = hr.w, .h = hr.h };
    ui.paint.fillRRect(ctx, h.x, h.y, h.w, h.h, h.w / 2, cc.handle);
    // state layer (enabled only): a 40dp circle centered on the handle
    if (s.opts.enabled) {
        const alpha: f32 = if (s.pressed)
            s.opts.theme.state.pressed
        else if (input.isFocused(n))
            s.opts.theme.state.focus
        else if (s.hovered)
            s.opts.theme.state.hover
        else
            0;
        if (alpha > 0) {
            const cx = h.x + h.w / 2;
            const cy = h.y + h.h / 2;
            ui.paint.fillRRect(ctx, cx - state_layer_size / 2, cy - state_layer_size / 2, state_layer_size, state_layer_size, state_layer_size / 2, ui.paint.withAlphaScaled(cc.on, alpha));
        }
    }
}

fn switchOnPointer(n: *Node, ev: input.PointerEvent) bool {
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
            const was_pressed = s.pressed;
            s.pressed = false;
            n.markDirty();
            // the click lands in the hit target, not necessarily in the track
            if (was_pressed and switchHitBounds(n).contains(ev.x, ev.y)) {
                s.sig.set(!s.sig.peek());
                if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            }
            return true;
        },
        .move => {
            // a drag past the touch slop cancels the press (a scroll); the
            // move is NOT claimed so it keeps bubbling to scrollables
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

/// Keyboard activation (Phase 2c): Enter/Space toggle the focused switch.
fn switchOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            s.sig.set(!s.sig.peek());
            if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        else => {},
    }
    return false;
}

/// Signal-driven repaint + semantic checked sync.
fn switchSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    if (n.semantics) |sem| sem.checked = stateOf(n).sig.peek();
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the value changed
}

fn switchDeinit(n: *Node) void {
    const s = stateOf(n);
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = switchSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const switch_vtable = ui.node.VTable{
    .measure = switchMeasure,
    .layout = null_layout,
    .paint = switchPaint,
    .deinit = switchDeinit,
    .on_pointer = switchOnPointer,
    .on_key = switchOnKey,
    .hit_bounds = switchHitBounds,
};

fn null_layout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: bounds come from the parent
}

/// An M3E switch bound to `sig` (a click or Enter/Space flips it; the visual
/// + semantic state follows the signal).
pub fn @"switch"(allocator: std.mem.Allocator, sig: *ui.state.Signal(bool), on_changed: ?Callback, opts: SwitchOptions) !*Node {
    const node = try Node.create(allocator, &switch_vtable);
    errdefer allocator.destroy(node); // no state yet
    const s = try allocator.create(SwitchState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .sig = sig, .on_changed = on_changed };
    node.state = s;
    ui.semantics.attach(node, .{
        .role = .toggle,
        .label = opts.a11y_label,
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
        .checked = sig.peek(),
        .actions = ui.semantics.Actions.initOne(.activate),
    });
    sig.subscribe(.{ .callback = .{ .fn_ptr = switchSyncCb, .userdata = node } }); // visual + semantic updates on set
    return node;
}

// --- tests ---

fn changeCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "switch: measures the 52x32 track; the hit target floors at 48 high" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, null, .{ .a11y_label = "x" });
    defer b.deinit();
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(track_w, m.w);
    try std.testing.expectEqual(track_h, m.h);
    b.layout(.{ .x = 100, .y = 100, .w = 52, .h = 32 });
    const hb = b.vtable.hit_bounds.?(b);
    try std.testing.expectEqual(@as(f32, 52), hb.w);
    try std.testing.expectEqual(min_target, hb.h); // 32 -> 48
    try std.testing.expectEqual(@as(f32, 100 - 8), hb.y); // (32-48)/2
}

test "switch: the handle follows the state (off/on/pressed positions)" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, null, .{ .a11y_label = "x" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 52, .h = 32 });
    const s = stateOf(b);
    // off: 16x16 at (8, 8)
    var hr = handleRect(b, s);
    try std.testing.expectEqual(@as(f32, 8), hr.x);
    try std.testing.expectEqual(@as(f32, 8), hr.y);
    try std.testing.expectEqual(handle_off, hr.w);
    // on: 24x24 at (24, 4)
    sig.set(true);
    hr = handleRect(b, s);
    try std.testing.expectEqual(@as(f32, 24), hr.x);
    try std.testing.expectEqual(@as(f32, 4), hr.y);
    try std.testing.expectEqual(handle_on, hr.w);
    // pressed on: 28x28 at (22, 2)
    s.pressed = true;
    hr = handleRect(b, s);
    try std.testing.expectEqual(@as(f32, 22), hr.x);
    try std.testing.expectEqual(@as(f32, 2), hr.y);
    try std.testing.expectEqual(handle_pressed, hr.w);
}

test "switch: click and Enter/Space toggle the signal + fire the callback" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = changeCounterCb, .userdata = &count };
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, cb, .{ .a11y_label = "x" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 52, .h = 32 });
    const on_pointer = b.vtable.on_pointer.?;
    // a drag past the slop cancels (a scroll, not a click)
    _ = on_pointer(b, .{ .phase = .down, .x = 26, .y = 16, .raw_x = 26, .raw_y = 16 });
    _ = on_pointer(b, .{ .phase = .move, .x = 26, .y = 40, .raw_x = 26, .raw_y = 40 });
    _ = on_pointer(b, .{ .phase = .up, .x = 26, .y = 16, .raw_x = 26, .raw_y = 16 });
    try std.testing.expect(!sig.peek());
    try std.testing.expectEqual(@as(u32, 0), count);
    // a plain click (from the hit margin: the hit target is 48 high, centered
    // on the 32-high track → y in [-8, 40))
    _ = on_pointer(b, .{ .phase = .down, .x = 26, .y = 38, .raw_x = 26, .raw_y = 38 });
    _ = on_pointer(b, .{ .phase = .up, .x = 26, .y = 38, .raw_x = 26, .raw_y = 38 });
    try std.testing.expect(sig.peek());
    try std.testing.expectEqual(@as(u32, 1), count);
    // keyboard
    const on_key = b.vtable.on_key.?;
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .enter }));
    try std.testing.expect(!sig.peek());
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "switch: semantics — role toggle, checked sync, disabled" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, null, .{ .a11y_label = "Wi-Fi" });
    defer b.deinit();
    try std.testing.expectEqual(ui.semantics.Role.toggle, b.semantics.?.role);
    try std.testing.expectEqual(true, b.semantics.?.checked);
    try std.testing.expectEqualStrings("Wi-Fi", b.semantics.?.label);
    sig.set(false);
    try std.testing.expectEqual(false, b.semantics.?.checked);
    const dis = try @"switch"(std.testing.allocator, sig, null, .{ .enabled = false, .a11y_label = "x" });
    defer dis.deinit();
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
}

test "golden: checked switch paints the primary track + the on_primary handle" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, null, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    b.layout(.{ .x = 6, .y = 16, .w = 52, .h = 32 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the track, left of the handle: primary
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(10, 32));
    // the handle center (24x24 at (30, 20) in window coords): on_primary
    try std.testing.expectEqual(t.colors.on_primary, f.pixelAt(42, 32));
}

test "golden: unchecked switch paints the surface_container_highest track + outline handle" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, null, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    b.layout(.{ .x = 6, .y = 16, .w = 52, .h = 32 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the track, right of the handle: surface_container_highest
    try std.testing.expectEqual(t.colors.surface_container_highest, f.pixelAt(50, 32));
    // the handle center (16x16 at (14, 24) in window coords): outline
    try std.testing.expectEqual(t.colors.outline, f.pixelAt(22, 32));
}

test "golden: disabled checked switch paints the OnSurface@0.12 track" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const b = try @"switch"(std.testing.allocator, sig, null, .{ .enabled = false, .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    b.layout(.{ .x = 6, .y = 16, .w = 52, .h = 32 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try golden.expectPixelApprox(f, 10, 32, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.12), 0xFFFFFFFF));
}
