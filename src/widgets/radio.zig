// RadioButton (Phase 2d.2 PR B2, M3E) — the M3E radio button. A radio group
// is a shared Signal(usize): each radio carries its `index`; checked =
// (signal == index); a click selects it.
//
// Spec: m3.material.io/components/radio-button + Compose RadioButtonTokens /
// RadioButton.kt:
//   - circle 20dp (IconSize), outline 2dp (RadioStrokeWidth), the stroke is
//     centered on a 9dp radius → the outer diameter is 20
//   - checked: the dot fills (RadioButtonDotSize 12 minus the stroke half →
//     a 10dp filled circle)
//   - colors: selected → Primary; unselected → outline OnSurfaceVariant
//     (hover/focus/pressed: OnSurface); disabled → OnSurface@0.38
//   - state layer: a 40dp circle (StateLayerSize) centered on the circle,
//     the circle's current color @ hover 0.08 / focus 0.10 / pressed 0.12
//   - hit target: 48x48 centered on the circle (the a11y floor is the hit
//     area, never the painted circle)
//
// v1 deviations (documented, fixed later):
//   - Keyboard: Enter/Space select; arrow-key group navigation (selection
//     follows focus) lands with the focus/navigation polish pass.
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
const Theme = theme_mod.Theme;

/// M3E measurement tokens (RadioButtonTokens + RadioButton.kt).
const circle_size: f32 = 20;
const circle_radius: f32 = 9; // IconSize/2 - strokeWidth/2 (the stroke is centered)
const stroke_width: f32 = 2;
const dot_size: f32 = 10; // RadioButtonDotSize (12) minus the stroke half
const state_layer_size: f32 = 40;
/// Compose minimumInteractiveComponentSize (the a11y hit-target floor).
const min_target: f32 = 48;

pub const RadioOptions = struct {
    enabled: bool = true,
    /// The accessible name (a radio is usually paired with a visible label
    /// built by the app; this is the control's own name).
    a11y_label: []const u8 = "",
    theme: Theme = theme_mod.light,
};

const RadioState = struct {
    opts: RadioOptions,
    sig: *ui.state.Signal(usize),
    index: u32,
    pressed: bool = false,
    hovered: bool = false,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — see PointerEvent.raw_x/raw_y).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
};

fn stateOf(n: *Node) *RadioState {
    return @ptrCast(@alignCast(n.state.?));
}

fn isChecked(s: *RadioState) bool {
    return s.sig.peek() == s.index;
}

/// The circle color + the state layer's on-color for the current state.
const RColors = struct { circle: Color, on: Color };

fn currentColors(n: *Node, s: *RadioState) RColors {
    const cs = s.opts.theme.colors;
    if (!s.opts.enabled) return .{ .circle = ui.paint.withAlphaScaled(cs.on_surface, 0.38), .on = ui.paint.withAlphaScaled(cs.on_surface, 0.38) };
    if (isChecked(s)) return .{ .circle = cs.primary, .on = cs.primary };
    // hover/focus/pressed darkens the unselected outline (Unselected*IconColor)
    const interacting = s.hovered or s.pressed or input.isFocused(n);
    const c = if (interacting) cs.on_surface else cs.on_surface_variant;
    return .{ .circle = c, .on = c };
}

fn radioMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = circle_size, .h = circle_size });
}

/// The interactive target: 48x48 centered on the circle.
fn radioHitBounds(n: *Node) Rect {
    const b = n.bounds;
    return .{
        .x = b.x + (b.w - min_target) / 2,
        .y = b.y + (b.h - min_target) / 2,
        .w = min_target,
        .h = min_target,
    };
}

fn radioPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const cc = currentColors(n, s);
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    // state layer (enabled only): a 40dp circle, the circle color @ the state alpha
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
            ui.paint.fillRRect(ctx, cx - state_layer_size / 2, cy - state_layer_size / 2, state_layer_size, state_layer_size, state_layer_size / 2, ui.paint.withAlphaScaled(cc.on, alpha));
        }
    }
    // the circle outline (inset by half the stroke → the outer diameter is 20)
    ui.paint.strokeRRect(ctx, b.x + stroke_width / 2, b.y + stroke_width / 2, b.w - stroke_width, b.h - stroke_width, circle_radius, stroke_width, cc.circle);
    // the dot (checked)
    if (isChecked(s)) {
        ui.paint.fillRRect(ctx, cx - dot_size / 2, cy - dot_size / 2, dot_size, dot_size, dot_size / 2, cc.circle);
    }
}

fn radioOnPointer(n: *Node, ev: input.PointerEvent) bool {
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
            // 20dp circle (the a11y floor is the interactive area)
            if (was_pressed and radioHitBounds(n).contains(ev.x, ev.y)) {
                s.sig.set(s.index);
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

/// Keyboard activation (Phase 2c): Enter/Space select the focused radio.
fn radioOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            s.sig.set(s.index);
            return true;
        },
        else => {},
    }
    return false;
}

/// Signal-driven repaint + semantic checked sync.
fn radioSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    if (n.semantics) |sem| sem.checked = isChecked(stateOf(n));
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the value changed
}

fn radioDeinit(n: *Node) void {
    const s = stateOf(n);
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = radioSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const radio_vtable = ui.node.VTable{
    .measure = radioMeasure,
    .layout = null_layout,
    .paint = radioPaint,
    .deinit = radioDeinit,
    .on_pointer = radioOnPointer,
    .on_key = radioOnKey,
    .hit_bounds = radioHitBounds,
};

fn null_layout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: bounds come from the parent
}

/// An M3E radio button bound to the group's shared `sig` (a click or
/// Enter/Space selects it: `sig.set(index)`; the visual + semantic state
/// follows the signal).
pub fn radio(allocator: std.mem.Allocator, sig: *ui.state.Signal(usize), index: u32, opts: RadioOptions) !*Node {
    const node = try Node.create(allocator, &radio_vtable);
    errdefer allocator.destroy(node); // no state yet
    const s = try allocator.create(RadioState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .sig = sig, .index = index };
    node.state = s;
    ui.semantics.attach(node, .{
        .role = .radio,
        .label = opts.a11y_label,
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
        .checked = isChecked(s),
        .actions = ui.semantics.Actions.initOne(.activate),
    });
    sig.subscribe(.{ .callback = .{ .fn_ptr = radioSyncCb, .userdata = node } }); // visual + semantic updates on set
    return node;
}

// --- tests ---

test "radio: measures the 20dp circle; the 48dp floor is the hit target" {
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sig.deinit();
    const b = try radio(std.testing.allocator, sig, 0, .{ .a11y_label = "x" });
    defer b.deinit();
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(circle_size, m.w);
    try std.testing.expectEqual(circle_size, m.h);
    b.layout(.{ .x = 100, .y = 100, .w = 20, .h = 20 });
    const hb = b.vtable.hit_bounds.?(b);
    try std.testing.expectEqual(min_target, hb.w);
    try std.testing.expectEqual(@as(f32, 100 - 14), hb.x); // (20-48)/2
}

test "radio: click and Enter/Space select the radio (the group signal)" {
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sig.deinit();
    const a = try radio(std.testing.allocator, sig, 0, .{ .a11y_label = "A" });
    defer a.deinit();
    const b = try radio(std.testing.allocator, sig, 1, .{ .a11y_label = "B" });
    defer b.deinit();
    a.layout(.{ .x = 0, .y = 0, .w = 20, .h = 20 });
    b.layout(.{ .x = 40, .y = 0, .w = 20, .h = 20 });
    try std.testing.expect(isChecked(stateOf(a)));
    try std.testing.expect(!isChecked(stateOf(b)));
    // click B (from the hit margin: the hit target is 48 wide centered on B)
    const on_pointer = b.vtable.on_pointer.?;
    _ = on_pointer(b, .{ .phase = .down, .x = 60, .y = 10, .raw_x = 60, .raw_y = 10 });
    _ = on_pointer(b, .{ .phase = .up, .x = 60, .y = 10, .raw_x = 60, .raw_y = 10 });
    try std.testing.expectEqual(@as(usize, 1), sig.peek());
    try std.testing.expect(!isChecked(stateOf(a))); // the semantic state followed
    try std.testing.expect(isChecked(stateOf(b)));
    // keyboard on A
    const on_key = a.vtable.on_key.?;
    try std.testing.expect(on_key(a, .{ .kind = .key_down, .key = .enter }));
    try std.testing.expectEqual(@as(usize, 0), sig.peek());
    try std.testing.expect(!on_key(a, .{ .kind = .key_down, .key = .left }));
}

test "radio: semantics — role radio, checked sync, disabled" {
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 2);
    defer sig.deinit();
    const b = try radio(std.testing.allocator, sig, 2, .{ .a11y_label = "Two" });
    defer b.deinit();
    try std.testing.expectEqual(ui.semantics.Role.radio, b.semantics.?.role);
    try std.testing.expectEqual(true, b.semantics.?.checked);
    try std.testing.expectEqualStrings("Two", b.semantics.?.label);
    sig.set(0);
    try std.testing.expectEqual(false, b.semantics.?.checked);
    const dis = try radio(std.testing.allocator, sig, 2, .{ .enabled = false, .a11y_label = "x" });
    defer dis.deinit();
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
}

test "golden: selected radio paints the primary circle + the dot" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sig.deinit();
    const b = try radio(std.testing.allocator, sig, 0, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 48, 48);
    defer r.deinit();
    b.layout(.{ .x = 14, .y = 14, .w = 20, .h = 20 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the dot center: primary
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(24, 24));
    // the circle outline: primary ink present (the circle's edge is curved —
    // AA — so assert presence, not an exact pixel)
    try std.testing.expect(f.countColorIn(.{ .x = 14, .y = 14, .w = 20, .h = 20 }, t.colors.primary) > 0);
    // outside the circle + the 40dp state layer (idle): bg
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(2, 2));
}

test "golden: unselected radio strokes the OnSurfaceVariant circle, no dot" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 1);
    defer sig.deinit();
    const b = try radio(std.testing.allocator, sig, 0, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 48, 48);
    defer r.deinit();
    b.layout(.{ .x = 14.5, .y = 14.5, .w = 20, .h = 20 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the circle outline: on_surface_variant ink present
    try std.testing.expect(f.countColorIn(.{ .x = 14, .y = 14, .w = 20, .h = 20 }, t.colors.on_surface_variant) > 0);
    // the center: no dot → transparent → bg
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(24, 24));
}
