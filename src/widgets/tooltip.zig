// Tooltip (Phase 2d.1 PR B, M3E batch 1) — plain tooltip on hover.
//
// Spec: m3.material.io/components/tooltips + Compose PlainTooltipTokens /
// Tooltip.kt:
//   - container: inverse_surface, CornerExtraSmall (4dp), max width 200,
//     min height 24, min width 40, content padding 8dp horizontal / 4dp
//     vertical, text inverse_on_surface body_small
//   - placement: above the anchor, horizontally centered, 4dp spacing
//     (TooltipAnchorPosition.Above, SpacingBetweenTooltipAndAnchor)
//   - motion: fade in/out (~150ms); v1 shows on hover enter without the
//     M3 hover delay and hides on leave (delay lands with touch long-press)
//
// Structure: the wrapper holds an internal bubble (child 0, `internal` —
// skipped by registry serialization, rebuilt by the factory) and the anchor
// (document data — the wrapper finds it as its first non-internal child, so
// child order does not matter). The bubble paints OUTSIDE the wrapper's bounds
// (above the anchor) and is not hit-testable (hit_bounds = empty rect), so
// moving the pointer onto it reads as leaving the anchor. The fade is a
// layer-alpha around the bubble's children (ABI 0.4.0, save-balanced).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const anim = ui.anim;
const node_mod = ui.node;
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

/// M3E measurement tokens (Compose PlainTooltipTokens / Tooltip.kt).
const max_width: f32 = 200;
const min_height: f32 = 24;
const min_width: f32 = 40;
const padding_h: f32 = 8;
const padding_v: f32 = 4;
const anchor_spacing: f32 = 4;
const corner: f32 = 4;
const fade_ms: u32 = 150;

pub const TooltipOptions = struct {
    text: []const u8 = "",
    theme: Theme = theme_mod.light,
};

const TooltipState = struct {
    opts: TooltipOptions,
    bubble: *Node, // internal bubble node
    alpha: f32 = 0, // 0 = hidden, 1 = shown
    anim_to: f32 = 0,
    anim_channel: u8 = 0, // channel marker (stable address)
};

fn stateOf(n: *Node) *TooltipState {
    return @ptrCast(@alignCast(n.state.?));
}

// --- wrapper (anchor + bubble) ---

/// The anchor: the first non-internal child (the bubble is internal chrome;
/// child order does not matter — the registry appends document children).
fn anchorOf(n: *Node) ?*Node {
    for (n.children.items) |child| {
        if (!child.internal) return child;
    }
    return null;
}

fn tooltipMeasure(n: *Node, c: Constraints) Size {
    // the wrapper is the anchor's size — the bubble never expands it
    const anchor = anchorOf(n) orelse return c.constrain(.{});
    return anchor.measure(c);
}

fn tooltipLayout(n: *Node, bounds: Rect) void {
    const anchor = anchorOf(n) orelse return;
    anchor.layout(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bounds.h });
    const s = stateOf(n);
    const bubble = s.bubble;
    // measure the bubble (capped at max width), place it above the anchor,
    // horizontally centered, 4dp spacing
    const cs = bubble.measure(.{ .max_w = max_width, .max_h = 400 });
    const bw = @min(@max(min_width, cs.w), max_width);
    const bh = @max(min_height, cs.h);
    bubble.layout(.{
        .x = bounds.x + (bounds.w - bw) / 2,
        .y = bounds.y - anchor_spacing - bh,
        .w = bw,
        .h = bh,
    });
}

fn tooltipOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    switch (ev.phase) {
        .enter, .hover_move => {
            // hover_move: the deepest node under the pointer changed within
            // the anchor's subtree — still hovering the anchor
            setShown(n, s, true);
            return true;
        },
        .leave => {
            setShown(n, s, false);
            return true;
        },
        else => return false,
    }
}

fn tooltipDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel));
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const tooltip_vtable = ui.node.VTable{
    .measure = tooltipMeasure,
    .layout = tooltipLayout,
    .paint = struct {
        fn p(n: *Node, ctx: *kx.Ctx) void {
            _ = n;
            _ = ctx; // transparent: the anchor child paints
        }
    }.p,
    .on_pointer = tooltipOnPointer,
    .deinit = tooltipDeinit,
};

/// Show/hide: fade the bubble's alpha (tween; snaps without a timeline).
fn setShown(n: *Node, s: *TooltipState, shown: bool) void {
    const target: f32 = if (shown) 1 else 0;
    if (target == s.anim_to) return;
    s.anim_to = target;
    s.bubble.visible = true; // paint while fading (even out)
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.tweenAnim(.{ target, 0, 0, 0 }, fade_ms, .{ .ease = .standard }),
            .from = .{ s.alpha, 0, 0, 0 },
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = tooltipAlphaCb, .userdata = n },
            .on_complete = .{ .fn_ptr = tooltipAlphaDoneCb, .userdata = n },
        });
    } else {
        s.alpha = target;
        if (!shown) s.bubble.visible = false;
        s.bubble.markDirty();
    }
}

fn tooltipAlphaCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.alpha = value[0];
    s.bubble.markDirty();
}

fn tooltipAlphaDoneCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.anim_to < 0.5) s.bubble.visible = false; // faded out: skip the paint
}

// --- bubble (internal): container + text, faded via a layer alpha ---

fn bubblePreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    // own save + the layer's save (saveLayerAlphaf pushes one): both are
    // restored in post_children_paint so a caller's canvas state survives
    ui.paint.save(ctx);
    const s = stateOf(n.parent.?);
    ui.paint.layerAlpha(ctx, s.alpha);
}

fn bubblePostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.restore(ctx); // pops the layer
    ui.paint.restore(ctx); // pops the own save
}

fn bubbleHitBounds(n: *Node) Rect {
    _ = n;
    return .{}; // not hit-testable: the pointer over the bubble reads as left
}

fn bubbleDeinit(n: *Node) void {
    _ = n; // children freed by Node.deinit; no state
}

const bubble_vtable = ui.node.VTable{
    .measure = struct {
        fn m(n: *Node, c: Constraints) Size {
            // content (text) + padding; the wrapper caps the width
            var size = Size{};
            for (n.children.items) |child| {
                const cs = child.measure(c);
                size = .{ .w = @max(size.w, cs.w), .h = @max(size.h, cs.h) };
            }
            return c.constrain(.{
                .w = size.w + padding_h * 2,
                .h = @max(min_height, size.h + padding_v * 2),
            });
        }
    }.m,
    .layout = struct {
        fn l(n: *Node, bounds: Rect) void {
            for (n.children.items) |child| {
                const cs = child.measure(.{ .max_w = bounds.w - padding_h * 2, .max_h = bounds.h - padding_v * 2 });
                child.layout(.{
                    .x = bounds.x + (bounds.w - cs.w) / 2,
                    .y = bounds.y + (bounds.h - cs.h) / 2,
                    .w = cs.w,
                    .h = cs.h,
                });
            }
        }
    }.l,
    .paint = struct {
        fn p(n: *Node, ctx: *kx.Ctx) void {
            const b = n.bounds;
            ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, corner, tooltipBubbleColor(n));
        }
    }.p,
    .pre_children_paint = bubblePreChildrenPaint,
    .post_children_paint = bubblePostChildrenPaint,
    .hit_bounds = bubbleHitBounds,
    .deinit = bubbleDeinit,
};

fn tooltipBubbleColor(n: *Node) Color {
    const s = stateOf(n.parent.?);
    return s.opts.theme.colors.inverse_surface;
}

/// A plain tooltip over `anchor`: hover shows the bubble above the anchor
/// (fade), leaving hides it. The anchor is the document child; the bubble is
/// internal chrome (rebuilt by this factory, skipped by serialization).
pub fn tooltip(allocator: std.mem.Allocator, anchor: *Node, opts: TooltipOptions) !*Node {
    const node = try tooltipShell(allocator, opts);
    errdefer allocator.destroy(node);
    node.add(anchor);
    return node;
}

/// The tooltip wrapper without the anchor (the registry builds document
/// children after the node — the wrapper finds the anchor as its first
/// non-internal child).
pub fn tooltipShell(allocator: std.mem.Allocator, opts: TooltipOptions) !*Node {
    const node = try Node.create(allocator, &tooltip_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(TooltipState);
    errdefer allocator.destroy(s);
    // Internal bubble: inverse_surface container + the label text.
    const bubble = try Node.create(allocator, &bubble_vtable);
    errdefer allocator.destroy(bubble);
    bubble.internal = true; // registry: not document data
    bubble.visible = false; // hidden until the first hover
    const text_w = @import("text.zig");
    const t = opts.theme;
    bubble.add(try text_w.text(allocator, opts.text, .{
        .size = t.type_scale.body_small.size,
        .color = t.colors.inverse_on_surface,
    }));
    ui.semantics.attach(bubble.children.items[0], .{ .role = .text, .label = opts.text }); // Phase 2c
    s.* = .{ .opts = opts, .bubble = bubble };
    node.state = s;
    node.add(bubble);
    return node;
}

// --- tests ---

const layout_w = @import("layout.zig");

test "tooltip: the wrapper measures the anchor; the bubble sits above it" {
    const t = theme_mod.light;
    const anchor = try golden.solidBox(std.testing.allocator, 80, 24, 0x112233FF);
    const tip = try tooltip(std.testing.allocator, anchor, .{ .text = "Save", .theme = t });
    defer tip.deinit();
    const m = tip.measure(.{ .max_w = 400, .max_h = 400 });
    try std.testing.expectEqual(@as(f32, 80), m.w);
    try std.testing.expectEqual(@as(f32, 24), m.h);
    tip.layout(.{ .x = 100, .y = 100, .w = 80, .h = 24 });
    const s = stateOf(tip);
    const bb = s.bubble.bounds;
    // above the anchor, horizontally centered, 4dp spacing, min height 24
    try std.testing.expect(bb.y + bb.h <= 100 - anchor_spacing + 0.01);
    try std.testing.expect(bb.h >= min_height);
    try std.testing.expect(bb.w >= min_width);
    try std.testing.expect(bb.w <= max_width);
    try std.testing.expect(std.math.approxEqAbs(f32, 100 + 40, bb.x + bb.w / 2, 0.01)); // centered on the anchor
    // hidden until hovered; the bubble is internal (not document data)
    try std.testing.expect(!s.bubble.visible);
    try std.testing.expect(s.bubble.internal);
}

test "tooltip: hover shows the bubble (snap without a timeline), leave hides it" {
    const anchor = try golden.solidBox(std.testing.allocator, 80, 24, 0x112233FF);
    const tip = try tooltip(std.testing.allocator, anchor, .{ .text = "Save" });
    defer tip.deinit();
    tip.layout(.{ .x = 0, .y = 100, .w = 80, .h = 24 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const s = stateOf(tip);
    try std.testing.expect(!s.bubble.visible);
    // hover the anchor: the router hit-tests the anchor (deepest node), the
    // enter bubbles to the wrapper
    router.dispatchPointer(tip, .{ .phase = .move, .x = 40, .y = 112 });
    try std.testing.expect(s.bubble.visible);
    try std.testing.expectEqual(@as(f32, 1), s.alpha);
    // leave: hidden again
    router.dispatchPointer(tip, .{ .phase = .move, .x = 40, .y = 200 });
    try std.testing.expect(!s.bubble.visible);
    try std.testing.expectEqual(@as(f32, 0), s.alpha);
}

test "golden: the tooltip bubble paints the inverse surface over the anchor" {
    const t = theme_mod.light;
    const anchor = try golden.solidBox(std.testing.allocator, 80, 24, 0x112233FF);
    const tip = try tooltip(std.testing.allocator, anchor, .{ .text = "Save", .theme = t });
    defer tip.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 200);
    defer r.deinit();
    tip.layout(.{ .x = 60, .y = 100, .w = 80, .h = 24 });
    const s = stateOf(tip);
    // force the shown state (no timeline in tests: snap)
    setShown(tip, s, true);
    r.paint(tip, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const bb = s.bubble.bounds;
    // the bubble's center is the inverse surface color (the text ink sits on top)
    const cx: i32 = @intFromFloat(bb.x + 4);
    const cy: i32 = @intFromFloat(bb.y + bb.h / 2);
    try std.testing.expectEqual(t.colors.inverse_surface, f.pixelAt(cx, cy));
    // the anchor still paints at its own position
    try std.testing.expectEqual(@as(Color, 0x112233FF), f.pixelAt(100, 112));
}
