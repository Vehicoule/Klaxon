// Slider (Phase 2d.2 PR B2, M3E) — the M3E slider (horizontal, continuous).
//
// Spec: m3.material.io/components/slider + Compose SliderTokens / Slider.kt:
//   - track 16dp high (InactiveTrackHeight), CornerFull (pill), inset by half
//     the thumb width (the thumb marks the value, the track spans between)
//   - the active track (0 → value) Primary, the inactive track
//     SecondaryContainer
//   - the thumb: a 4x44 vertical bar (HandleWidth x HandleHeight), CornerFull,
//     centered on the value position; focus/pressed → 2dp wide
//   - disabled: active track OnSurface@0.38, inactive track OnSurface@0.12,
//     thumb OnSurface@0.38
//   - state layer: a 40dp circle centered on the thumb, Primary @ hover 0.08 /
//     focus 0.10 / pressed 0.12
//   - hit target: max(width,48) x max(44,48) (the a11y floor is the hit area)
//   - input: a down/drag sets the value from the pointer x (the drag IS the
//     interaction — no slop cancel); arrows adjust by ±0.05 (keyboard)
//
// v1 deviations (documented, fixed later):
//   - Continuous only (no steps/ticks — the stop indicators land with the
//     discrete slider); no value indicator (the bubble above the thumb);
//     vertical sliders and range sliders are separate widgets later.
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

/// M3E measurement tokens (SliderTokens + Slider.kt).
const track_h: f32 = 16;
const thumb_w: f32 = 4; // HandleWidth
const thumb_w_active: f32 = 2; // FocusHandleWidth / PressedHandleWidth
const thumb_h: f32 = 44; // HandleHeight
const inset: f32 = thumb_w / 2; // the track is inset by half the thumb width
const state_layer_size: f32 = 40;
const keyboard_step: f32 = 0.05;
/// Compose minimumInteractiveComponentSize (the a11y hit-target floor).
const min_target: f32 = 48;

pub const SliderOptions = struct {
    enabled: bool = true,
    /// The natural width when the parent does not constrain it.
    default_width: f32 = 160,
    /// The accessible name.
    a11y_label: []const u8 = "",
    theme: Theme = theme_mod.light,
};

const SliderState = struct {
    opts: SliderOptions,
    sig: *ui.state.Signal(f32),
    on_changed: ?Callback = null,
    pressed: bool = false,
    hovered: bool = false,
    /// Gesture arbitration (raw coords): a horizontal drag edits the value,
    /// a vertical drag is a scroll and bubbles to the scrollable.
    dragging: bool = false,
    scroll_won: bool = false,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — see PointerEvent.raw_x/raw_y).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
    /// The semantic value string ("42%") — borrowed by the semantics.
    value_buf: [16]u8 = std.mem.zeroes([16]u8),
    value_len: usize = 0,
};

fn stateOf(n: *Node) *SliderState {
    return @ptrCast(@alignCast(n.state.?));
}

fn clampedValue(s: *SliderState) f32 {
    return std.math.clamp(s.sig.peek(), 0, 1);
}

/// The active/inactive track colors + the thumb color for the current state.
const SLColors = struct { active: Color, inactive: Color, thumb: Color };

fn currentColors(s: *SliderState) SLColors {
    const cs = s.opts.theme.colors;
    if (!s.opts.enabled) {
        return .{
            .active = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
            .inactive = ui.paint.withAlphaScaled(cs.on_surface, 0.12),
            .thumb = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
        };
    }
    return .{ .active = cs.primary, .inactive = cs.secondary_container, .thumb = cs.primary };
}

fn sliderMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    return c.constrain(.{ .w = s.opts.default_width, .h = thumb_h });
}

/// The interactive target: max(width,48) x max(44,48) centered on the node.
fn sliderHitBounds(n: *Node) Rect {
    const b = n.bounds;
    const w = @max(b.w, min_target);
    const h = @max(b.h, min_target);
    return .{ .x = b.x + (b.w - w) / 2, .y = b.y + (b.h - h) / 2, .w = w, .h = h };
}

fn sliderPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const cc = currentColors(s);
    const v = clampedValue(s);
    // track: 16dp high, vertically centered, inset by half the thumb width
    const ty = b.y + (b.h - track_h) / 2;
    const tx = b.x + inset;
    const tw = @max(0, b.w - inset * 2);
    ui.paint.fillRRect(ctx, tx, ty, tw, track_h, track_h / 2, cc.inactive);
    const active_w = tw * v;
    if (active_w > 0) {
        ui.paint.fillRRect(ctx, tx, ty, active_w, track_h, track_h / 2, cc.active);
    }
    // thumb: a vertical bar centered on the value position
    const tw_thumb: f32 = if (s.pressed or input.isFocused(n)) thumb_w_active else thumb_w;
    const thumb_x = tx + active_w - tw_thumb / 2;
    ui.paint.fillRRect(ctx, thumb_x, b.y, tw_thumb, b.h, tw_thumb / 2, cc.thumb);
    // state layer (enabled only): a 40dp circle centered on the thumb
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
            const cx = thumb_x + tw_thumb / 2;
            const cy = b.y + b.h / 2;
            ui.paint.fillRRect(ctx, cx - state_layer_size / 2, cy - state_layer_size / 2, state_layer_size, state_layer_size, state_layer_size / 2, ui.paint.withAlphaScaled(cc.thumb, alpha));
        }
    }
}

/// The value for a pointer x (window coords): the track spans
/// [b.x + inset, b.x + w - inset].
fn valueAt(s: *SliderState, b: Rect, x: f32) f32 {
    _ = s;
    const tw = @max(0, b.w - inset * 2);
    if (tw <= 0) return 0;
    return std.math.clamp((x - b.x - inset) / tw, 0, 1);
}

fn sliderOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    switch (ev.phase) {
        .down => {
            s.pressed = true;
            s.dragging = false;
            s.scroll_won = false;
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            const v = valueAt(s, n.bounds, ev.x);
            s.sig.set(v);
            if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            n.markDirty();
            return true;
        },
        .move => {
            // the router only delivers move while we are captured (drag)
            if (s.scroll_won) return false; // the scroll owns the gesture
            if (!s.dragging) {
                // gesture arbitration: past the touch slop, the dominant axis
                // decides — horizontal = slider drag (claim), vertical =
                // scroll (release: bubble to the scrollable)
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    if (@abs(dy) > @abs(dx)) {
                        s.scroll_won = true;
                        s.pressed = false;
                        n.markDirty();
                        return false;
                    }
                    s.dragging = true;
                }
            }
            if (s.dragging) {
                s.pressed = true; // kept for the whole drag (pressed feedback)
                const v = valueAt(s, n.bounds, ev.x);
                s.sig.set(v);
                if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
                n.markDirty();
            }
            return s.dragging; // claim only the horizontal drag
        },
        .up => {
            const was_scrolling = s.scroll_won;
            s.pressed = false;
            s.dragging = false;
            s.scroll_won = false;
            n.markDirty();
            return !was_scrolling; // a scroll-owned gesture: the up bubbles
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

/// Keyboard (Phase 2c): arrows adjust the value.
fn sliderOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .left, .down => {
            s.sig.set(std.math.clamp(s.sig.peek() - keyboard_step, 0, 1));
            if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        .right, .up => {
            s.sig.set(std.math.clamp(s.sig.peek() + keyboard_step, 0, 1));
            if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        else => {},
    }
    return false;
}

/// Repaint + keep the semantic value in sync (Phase 2c). The announced value
/// is clamped — an out-of-range signal must not announce beyond 0-100.
fn sliderSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const str = std.fmt.bufPrint(&s.value_buf, "{d:.0}%", .{clampedValue(s) * 100}) catch return;
    s.value_len = str.len;
    if (n.semantics) |sem| sem.value = s.value_buf[0..s.value_len];
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the value changed
}

fn sliderDeinit(n: *Node) void {
    const s = stateOf(n);
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = sliderSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const slider_vtable = ui.node.VTable{
    .measure = sliderMeasure,
    .layout = null_layout,
    .paint = sliderPaint,
    .deinit = sliderDeinit,
    .on_pointer = sliderOnPointer,
    .on_key = sliderOnKey,
    .hit_bounds = sliderHitBounds,
};

fn null_layout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: bounds come from the parent
}

/// An M3E slider bound to `sig` (a value in 0..1). A down/drag sets the value
/// from the pointer x; the visual + semantic state follows the signal.
pub fn slider(allocator: std.mem.Allocator, sig: *ui.state.Signal(f32), on_changed: ?Callback, opts: SliderOptions) !*Node {
    const node = try Node.create(allocator, &slider_vtable);
    errdefer allocator.destroy(node); // no state yet
    const s = try allocator.create(SliderState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .sig = sig, .on_changed = on_changed };
    node.state = s;
    // the initial semantic value
    const str = std.fmt.bufPrint(&s.value_buf, "{d:.0}%", .{std.math.clamp(sig.peek(), 0, 1) * 100}) catch "";
    s.value_len = str.len;
    ui.semantics.attach(node, .{
        .role = .slider,
        .label = opts.a11y_label,
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
        .value = s.value_buf[0..s.value_len],
        .actions = ui.semantics.Actions.init(.{ .increment = true, .decrement = true }),
    });
    sig.subscribe(.{ .callback = .{ .fn_ptr = sliderSyncCb, .userdata = node } }); // visual + semantic updates on set
    return node;
}

// --- tests ---

fn changeCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "slider: measures default_width x 44; the hit target floors at 48 high" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "x" });
    defer b.deinit();
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(@as(f32, 160), m.w);
    try std.testing.expectEqual(thumb_h, m.h);
    b.layout(.{ .x = 0, .y = 0, .w = 160, .h = 44 });
    const hb = b.vtable.hit_bounds.?(b);
    try std.testing.expectEqual(@as(f32, 160), hb.w);
    try std.testing.expectEqual(min_target, hb.h); // 44 -> 48
    try std.testing.expectEqual(@as(f32, -2), hb.y); // (44-48)/2
}

test "slider: a down/drag sets the value from the pointer x (clamped)" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = changeCounterCb, .userdata = &count };
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, cb, .{ .a11y_label = "x" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 160, .h = 44 });
    const on_pointer = b.vtable.on_pointer.?;
    // down at the middle: (80-2)/156 = 0.5
    _ = on_pointer(b, .{ .phase = .down, .x = 80, .y = 22, .raw_x = 80, .raw_y = 22 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sig.peek(), 0.01);
    // drag to the left: (40-2)/156 ≈ 0.2436
    _ = on_pointer(b, .{ .phase = .move, .x = 40, .y = 22, .raw_x = 40, .raw_y = 22 });
    try std.testing.expectApproxEqAbs(@as(f32, 38.0 / 156.0), sig.peek(), 0.001);
    _ = on_pointer(b, .{ .phase = .up, .x = 40, .y = 22, .raw_x = 40, .raw_y = 22 });
    try std.testing.expectEqual(@as(u32, 2), count);
    // clamped at both ends
    _ = on_pointer(b, .{ .phase = .down, .x = 500, .y = 22 });
    try std.testing.expectEqual(@as(f32, 1), sig.peek());
    _ = on_pointer(b, .{ .phase = .down, .x = -50, .y = 22 });
    try std.testing.expectEqual(@as(f32, 0), sig.peek());
}

test "slider: gesture arbitration — a vertical drag is a scroll, not an edit" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "x" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 160, .h = 44 });
    const on_pointer = b.vtable.on_pointer.?;
    _ = on_pointer(b, .{ .phase = .down, .x = 80, .y = 22, .raw_x = 80, .raw_y = 22 });
    const v0 = sig.peek();
    // a vertical drag past the slop: the scroll wins (the move bubbles, the
    // value is frozen, the pressed feedback is dropped)
    try std.testing.expect(!on_pointer(b, .{ .phase = .move, .x = 80, .y = 45, .raw_x = 80, .raw_y = 45 }));
    try std.testing.expectEqual(v0, sig.peek());
    try std.testing.expect(!stateOf(b).pressed);
    try std.testing.expect(!on_pointer(b, .{ .phase = .move, .x = 80, .y = 60, .raw_x = 80, .raw_y = 60 }));
    try std.testing.expectEqual(v0, sig.peek());
    try std.testing.expect(!on_pointer(b, .{ .phase = .up, .x = 80, .y = 60, .raw_x = 80, .raw_y = 60 })); // bubbles
    // a horizontal drag edits the value and keeps the pressed feedback
    _ = on_pointer(b, .{ .phase = .down, .x = 80, .y = 22, .raw_x = 80, .raw_y = 22 });
    try std.testing.expect(on_pointer(b, .{ .phase = .move, .x = 100, .y = 22, .raw_x = 100, .raw_y = 22 }));
    try std.testing.expect(stateOf(b).pressed);
    try std.testing.expect(stateOf(b).dragging);
    try std.testing.expect(sig.peek() > v0);
    try std.testing.expect(on_pointer(b, .{ .phase = .up, .x = 100, .y = 22, .raw_x = 100, .raw_y = 22 }));
    try std.testing.expect(!stateOf(b).pressed);
}

test "slider: arrows adjust the value (keyboard)" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "x" });
    defer b.deinit();
    const on_key = b.vtable.on_key.?;
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .right }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), sig.peek(), 0.001);
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .left }));
    try std.testing.expect(on_key(b, .{ .kind = .key_down, .key = .left }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), sig.peek(), 0.001);
    try std.testing.expect(!on_key(b, .{ .kind = .key_down, .key = .enter }));
}

test "slider: semantics — role slider, value sync, increment/decrement actions" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "Volume" });
    defer b.deinit();
    try std.testing.expectEqual(ui.semantics.Role.slider, b.semantics.?.role);
    try std.testing.expectEqualStrings("50%", b.semantics.?.value);
    try std.testing.expectEqualStrings("Volume", b.semantics.?.label);
    try std.testing.expect(b.semantics.?.actions.contains(.increment));
    try std.testing.expect(b.semantics.?.actions.contains(.decrement));
    sig.set(0.25);
    try std.testing.expectEqualStrings("25%", b.semantics.?.value); // follows the signal
    const dis = try slider(std.testing.allocator, sig, null, .{ .enabled = false, .a11y_label = "x" });
    defer dis.deinit();
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
}

test "golden: slider paints the active/inactive track + the thumb at the value" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 160, 48);
    defer r.deinit();
    b.layout(.{ .x = 0, .y = 2, .w = 160, .h = 44 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // active track (0 → 50%): primary — mid-track height (y = 2+14..2+30)
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(40, 24));
    // inactive track (50% → 100%): secondary_container
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(120, 24));
    // the thumb (4x44 at x = 2 + 78 - 2 = 78): primary, above the track
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(80, 4));
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(80, 42));
}

test "golden: slider hover paints the state layer over the inactive track" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 160, 48);
    defer r.deinit();
    b.layout(.{ .x = 0, .y = 2, .w = 160, .h = 44 });
    _ = b.vtable.on_pointer.?(b, .{ .phase = .enter, .x = 80, .y = 24 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the 40dp state layer circle centered on the thumb (80, 24): 15px right
    // of the thumb center, over the inactive track → primary @ 0.08 blended
    try std.testing.expectEqual(
        theme_mod.stateLayer(t.colors.secondary_container, t.colors.primary, t.state.hover),
        f.pixelAt(95, 24),
    );
}

test "golden: disabled slider paints the OnSurface@0.38 active track" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0.5);
    defer sig.deinit();
    const b = try slider(std.testing.allocator, sig, null, .{ .enabled = false, .a11y_label = "x", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 160, 48);
    defer r.deinit();
    b.layout(.{ .x = 0, .y = 2, .w = 160, .h = 44 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the active track (OnSurface@0.38) is painted OVER the inactive track
    // (OnSurface@0.12 over white) — blend both layers
    const inactive_over_white = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.12), 0xFFFFFFFF);
    try golden.expectPixelApprox(f, 40, 24, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), inactive_over_white));
}
