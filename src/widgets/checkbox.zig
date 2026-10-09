// Checkbox (Phase 2d.2 PR B2, M3E) — the M3E checkbox (with the error
// variant).
//
// Spec: m3.material.io/components/checkbox + Compose CheckboxTokens /
// Checkbox.kt:
//   - box 18x18 (ContainerSize), corner radius 2, outline 2dp
//     (UnselectedOutlineWidth)
//   - unselected: transparent box, outline OnSurfaceVariant (hover/focus/
//     pressed: OnSurface); selected: box Primary, checkmark OnPrimary
//   - error variant: selected box Error / checkmark OnError; unselected
//     outline Error
//   - disabled: selected box OnSurface@0.38 + checkmark Surface; unselected
//     outline OnSurface@0.38
//   - state layer: a 40dp circle (StateLayerSize, CornerFull) centered on the
//     box, indicator color @ hover 0.08 / focus 0.10 / pressed 0.12 —
//     indicator = Primary (checked) / OnSurfaceVariant (unchecked), Error in
//     the error variant
//   - the checkmark is a 2dp round-capped polyline (kx_stroke_polyline)
//   - hit target: 48x48 centered on the box (minimumInteractiveComponentSize —
//     the a11y floor is the hit area, never the painted box)
//
// v1 deviations (documented, fixed later):
//   - The indeterminate state (a dash instead of a checkmark) is not modeled —
//     v1 is binary (on/off). The animated check draw lands with Phase 3.
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

/// M3E measurement tokens (CheckboxTokens + Checkbox.kt).
const box_size: f32 = 18;
const box_radius: f32 = 2;
const outline_width: f32 = 2;
const check_stroke: f32 = 2;
const state_layer_size: f32 = 40;
/// Compose minimumInteractiveComponentSize (the a11y hit-target floor).
const min_target: f32 = 48;

pub const CheckboxOptions = struct {
    enabled: bool = true,
    /// The error variant (Error container / outline).
    @"error": bool = false,
    /// The accessible name (a checkbox is usually paired with a visible label
    /// built by the app; this is the control's own name).
    a11y_label: []const u8 = "",
    theme: Theme = theme_mod.light,
};

const CheckboxState = struct {
    opts: CheckboxOptions,
    sig: *ui.state.Signal(bool),
    on_changed: ?Callback = null,
    pressed: bool = false,
    hovered: bool = false,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — see PointerEvent.raw_x/raw_y).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
};

fn stateOf(n: *Node) *CheckboxState {
    return @ptrCast(@alignCast(n.state.?));
}

fn isChecked(s: *CheckboxState) bool {
    return s.sig.peek();
}

/// The box color (selected), outline color (unselected), checkmark color and
/// the state layer's indicator color for the current state.
const CBColors = struct { box: Color, outline: Color, check: Color, indicator: Color };

fn currentColors(n: *Node, s: *CheckboxState) CBColors {
    const cs = s.opts.theme.colors;
    const err = s.opts.@"error";
    if (!s.opts.enabled) {
        if (isChecked(s)) {
            return .{
                .box = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
                .outline = 0x00000000,
                .check = cs.surface,
                .indicator = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
            };
        }
        return .{
            .box = 0x00000000,
            .outline = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
            .check = 0x00000000,
            .indicator = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
        };
    }
    // hover/focus/pressed darkens the unselected outline (Unselected*OutlineColor)
    const interacting = s.hovered or s.pressed or input.isFocused(n);
    if (isChecked(s)) {
        const c = if (err) cs.@"error" else cs.primary;
        return .{ .box = c, .outline = 0x00000000, .check = if (err) cs.on_error else cs.on_primary, .indicator = c };
    }
    const outline = if (interacting or err) (if (err) cs.@"error" else cs.on_surface) else cs.on_surface_variant;
    const indicator = if (err) cs.@"error" else cs.on_surface_variant;
    return .{ .box = 0x00000000, .outline = outline, .check = 0x00000000, .indicator = indicator };
}

fn checkboxMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = box_size, .h = box_size });
}

/// The interactive target: 48x48 centered on the box.
fn checkboxHitBounds(n: *Node) Rect {
    const b = n.bounds;
    return .{
        .x = b.x + (b.w - min_target) / 2,
        .y = b.y + (b.h - min_target) / 2,
        .w = min_target,
        .h = min_target,
    };
}

fn checkboxPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const cc = currentColors(n, s);
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    // state layer (enabled only): a 40dp circle, indicator @ the state alpha
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
            ui.paint.fillRRect(ctx, cx - state_layer_size / 2, cy - state_layer_size / 2, state_layer_size, state_layer_size, state_layer_size / 2, ui.paint.withAlphaScaled(cc.indicator, alpha));
        }
    }
    // the box
    if (isChecked(s)) {
        ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, box_radius, cc.box);
        // the checkmark: a round-capped polyline inside the 18dp box
        const xs = [_]f32{ b.x + 4, b.x + 7.5, b.x + 14 };
        const ys = [_]f32{ b.y + 9.5, b.y + 13, b.y + 6.5 };
        ui.paint.strokePolyline(ctx, &xs, &ys, check_stroke, true, cc.check);
    } else {
        ui.paint.strokeRRect(ctx, b.x, b.y, b.w, b.h, box_radius, outline_width, cc.outline);
    }
}

fn checkboxOnPointer(n: *Node, ev: input.PointerEvent) bool {
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
            // the click lands in the 48dp hit target, not necessarily in the
            // 18dp box (the a11y floor is the interactive area)
            if (was_pressed and checkboxHitBounds(n).contains(ev.x, ev.y)) {
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

/// Keyboard activation (Phase 2c): Enter/Space toggle the focused checkbox.
fn checkboxOnKey(n: *Node, ev: input.KeyEvent) bool {
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
fn checkboxSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    if (n.semantics) |sem| sem.checked = stateOf(n).sig.peek();
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the value changed
}

fn checkboxDeinit(n: *Node) void {
    const s = stateOf(n);
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = checkboxSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const checkbox_vtable = ui.node.VTable{
    .measure = checkboxMeasure,
    .layout = null_layout,
    .paint = checkboxPaint,
    .deinit = checkboxDeinit,
    .on_pointer = checkboxOnPointer,
    .on_key = checkboxOnKey,
    .hit_bounds = checkboxHitBounds,
};

fn null_layout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: bounds come from the parent
}

/// An M3E checkbox bound to `sig` (a click or Enter/Space flips it; the
/// visual + semantic state follows the signal).
pub fn checkbox(allocator: std.mem.Allocator, sig: *ui.state.Signal(bool), on_changed: ?Callback, opts: CheckboxOptions) !*Node {
    const node = try Node.create(allocator, &checkbox_vtable);
    errdefer allocator.destroy(node); // no state yet
    const s = try allocator.create(CheckboxState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .sig = sig, .on_changed = on_changed };
    node.state = s;
    ui.semantics.attach(node, .{
        .role = .checkbox,
        .label = opts.a11y_label,
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
        .checked = sig.peek(),
        .actions = ui.semantics.Actions.initOne(.activate),
    });
    sig.subscribe(.{ .callback = .{ .fn_ptr = checkboxSyncCb, .userdata = node } }); // visual + semantic updates on set
    return node;
}

// --- tests ---

test "checkbox: measures the 18dp box; the 48dp floor is the hit target" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try checkbox(std.testing.allocator, sig, null, .{ .a11y_label = "x" });
    defer b.deinit();
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(box_size, m.w);
    try std.testing.expectEqual(box_size, m.h);
    b.layout(.{ .x = 100, .y = 100, .w = 18, .h = 18 });
    const hb = b.vtable.hit_bounds.?(b);
    try std.testing.expectEqual(min_target, hb.w);
    try std.testing.expectEqual(min_target, hb.h);
    try std.testing.expectEqual(@as(f32, 100 - 15), hb.x); // (18-48)/2
    try std.testing.expectEqual(@as(f32, 100 - 15), hb.y);
}

test "checkbox: click and Enter/Space toggle the signal + fire the callback" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = struct {
        fn f(ud: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ud.?));
            c.* += 1;
        }
    }.f, .userdata = &count };
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try checkbox(std.testing.allocator, sig, cb, .{ .a11y_label = "x" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 18, .h = 18 });
    const on_pointer = b.vtable.on_pointer.?;
    // a drag past the slop cancels (a scroll, not a click)
    _ = on_pointer(b, .{ .phase = .down, .x = 9, .y = 9, .raw_x = 9, .raw_y = 9 });
    _ = on_pointer(b, .{ .phase = .move, .x = 9, .y = 30, .raw_x = 9, .raw_y = 30 });
    _ = on_pointer(b, .{ .phase = .up, .x = 9, .y = 9, .raw_x = 9, .raw_y = 9 });
    try std.testing.expect(!sig.peek());
    try std.testing.expectEqual(@as(u32, 0), count);
    // a plain click toggles — inside the 48dp hit target (the box is 18dp at
    // the origin, the hit target is centered on it: [-15, 33))
    _ = on_pointer(b, .{ .phase = .down, .x = 9, .y = 9, .raw_x = 9, .raw_y = 9 });
    _ = on_pointer(b, .{ .phase = .up, .x = 9, .y = 9, .raw_x = 9, .raw_y = 9 });
    try std.testing.expect(sig.peek());
    try std.testing.expectEqual(@as(u32, 1), count);
    _ = on_pointer(b, .{ .phase = .down, .x = 30, .y = 30, .raw_x = 30, .raw_y = 30 });
    _ = on_pointer(b, .{ .phase = .up, .x = 30, .y = 30, .raw_x = 30, .raw_y = 30 });
    try std.testing.expect(!sig.peek()); // toggled from the hit margin
    try std.testing.expectEqual(@as(u32, 2), count);
    _ = on_pointer(b, .{ .phase = .down, .x = 9, .y = 9, .raw_x = 9, .raw_y = 9 });
    _ = on_pointer(b, .{ .phase = .up, .x = 9, .y = 9, .raw_x = 9, .raw_y = 9 });
    try std.testing.expect(sig.peek());
    try std.testing.expectEqual(@as(u32, 3), count);
    // keyboard
    const on_key = b.vtable.on_key.?;
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .space }));
    try std.testing.expect(!sig.peek());
    try std.testing.expectEqual(@as(u32, 4), count);
    try std.testing.expect(!on_key(b, .{ .kind = .key_down, .key = .left }));
}

test "checkbox: semantics — role checkbox, checked sync, disabled" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const b = try checkbox(std.testing.allocator, sig, null, .{ .a11y_label = "Accept" });
    defer b.deinit();
    try std.testing.expectEqual(ui.semantics.Role.checkbox, b.semantics.?.role);
    try std.testing.expectEqual(true, b.semantics.?.checked);
    try std.testing.expectEqualStrings("Accept", b.semantics.?.label);
    sig.set(false);
    try std.testing.expectEqual(false, b.semantics.?.checked); // follows the signal
    const dis = try checkbox(std.testing.allocator, sig, null, .{ .enabled = false, .a11y_label = "x" });
    defer dis.deinit();
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
}

test "golden: checked checkbox paints the primary box + the checkmark ink" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const b = try checkbox(std.testing.allocator, sig, null, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 48, 48);
    defer r.deinit();
    b.layout(.{ .x = 15, .y = 15, .w = 18, .h = 18 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // inside the box, off the checkmark ink: primary
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(17, 17));
    // the checkmark stroke is on_primary ink somewhere along the check path
    try std.testing.expect(f.countColorIn(.{ .x = 15, .y = 15, .w = 18, .h = 18 }, t.colors.on_primary) > 0);
    // outside the box + the 40dp state layer (idle: none): bg
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(2, 2));
}

test "golden: unchecked checkbox strokes the OnSurfaceVariant outline, transparent inside" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const b = try checkbox(std.testing.allocator, sig, null, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 48, 48);
    defer r.deinit();
    // half-pixel offset: the 2dp outline is centered on the edge
    b.layout(.{ .x = 15.5, .y = 15.5, .w = 18, .h = 18 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the top outline, mid-edge: on_surface_variant
    try std.testing.expectEqual(t.colors.on_surface_variant, f.pixelAt(24, 15));
    // inside: transparent → bg
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(24, 24));
}

test "golden: disabled checked checkbox paints the OnSurface@0.38 box" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const b = try checkbox(std.testing.allocator, sig, null, .{ .enabled = false, .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 48, 48);
    defer r.deinit();
    b.layout(.{ .x = 15, .y = 15, .w = 18, .h = 18 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try golden.expectPixelApprox(f, 17, 17, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), 0xFFFFFFFF));
}
