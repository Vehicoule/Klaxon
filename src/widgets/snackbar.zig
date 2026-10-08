// SnackBar (Phase 2d.1 PR B, M3E batch 1) — snackbar with action, dismiss
// icon and auto-dismiss timeout.
//
// Spec: m3.material.io/components/snackbar + Compose SnackbarTokens /
// Snackbar.kt (OneRowSnackbar):
//   - container: inverse_surface, CornerExtraSmall (4dp), elevation level3
//     (not drawn in v1), max width 600, min height 48 (single line)
//   - text: body_medium, inverse_on_surface, 14dp vertical padding, 16dp
//     start padding
//   - action: a text button, inverse_primary, label_large
//   - dismiss action: a 24dp icon button, inverse_on_surface; container end
//     padding 8dp without a dismiss action, 0 with one
//   - motion: slide-up + fade (M3); v1 animates with a tween, snaps without
//     a timeline
//   - behavior: shown/hidden by a Signal(bool); auto-dismisses after
//     timeout_ms (default 4000, M3) via a timeline ticker (the host wakes for
//     pending timed work — the timeout fires even at idle). The action press
//     and the dismiss icon both hide it; on_dismiss fires on any dismissal.
//
// Structure: the snackbar node holds an internal background child (the
// container surface — inside the slide/fade transform) and internal content
// children: the text, the optional action button, the optional dismiss icon
// button. The widget SELF-POSITIONS: it is meant to be a fill child of a Stack
// (its bounds may be the whole window) and lays its content out at the
// bottom-center with a 12dp margin (Compose SnackbarHost's job). Hit-testing
// covers the content rect only — an overlay snackbar never shadows the
// content below it.
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

/// M3E measurement tokens (Compose SnackbarTokens / Snackbar.kt).
const max_width: f32 = 600;
const min_height: f32 = 48;
const corner: f32 = 4;
const start_padding: f32 = 16;
const end_padding: f32 = 8; // TextEndExtraSpacing (0 when a dismiss action)
const vertical_padding: f32 = 14; // SnackbarVerticalPadding
const action_gap: f32 = 8;
const slide_ms: u32 = 200;

pub const SnackBarOptions = struct {
    text: []const u8 = "",
    action_label: ?[]const u8 = null,
    dismiss: bool = true, // show the dismiss icon button
    timeout_ms: u32 = 4000, // 0 = no auto-dismiss
    bottom_margin: f32 = 12, // from the parent's bottom edge (SnackbarHost)
    theme: Theme = theme_mod.light,
};

const Callback = ui.state.Callback;

const SnackBarState = struct {
    sig: *ui.state.Signal(bool),
    opts: SnackBarOptions,
    on_action: ?Callback = null,
    on_dismiss: ?Callback = null,
    bg: *Node, // internal background child
    content: Rect = .{}, // the content rect within the (possibly full-window) bounds
    progress: f32 = 0, // 0 = hidden, 1 = shown (animated)
    anim_to: f32 = 0,
    laid_out: bool = false,
    anim_channel: u8 = 0, // channel marker (stable address)
    ticker: anim.Timeline.Ticker = .{ .fn_ptr = struct {
        fn noop(_: ?*anyopaque, _: u64) void {}
    }.noop, .userdata = null },
    timeout_armed: bool = false, // a deadline is being counted (ticker)
    timeout_deadline: ?u64 = null,
};

fn stateOf(n: *Node) *SnackBarState {
    return @ptrCast(@alignCast(n.state.?));
}

// --- measure / layout ---

fn snackMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    var content_w: f32 = 0;
    var content_h: f32 = 0;
    for (n.children.items) |child| {
        if (child == s.bg) continue;
        const cs = child.measure(.{ .max_w = c.max_w, .max_h = c.max_h });
        content_w += cs.w;
        content_h = @max(content_h, cs.h);
    }
    // one gap, before the action (the dismiss icon button has its own padding)
    const gaps: f32 = if (s.opts.action_label != null) action_gap else 0;
    const end_pad: f32 = if (s.opts.dismiss) 0 else end_padding;
    const w = start_padding + content_w + gaps + end_pad;
    const h = @max(min_height, vertical_padding * 2 + content_h);
    return c.constrain(.{ .w = @min(w, max_width), .h = h });
}

fn snackLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    // Self-positioning: the content rect sits at the bottom-center of the
    // given bounds (which may be the whole window — a fill child of a Stack)
    // with the bottom margin.
    const ms = snackMeasure(n, .{ .max_w = bounds.w, .max_h = bounds.h });
    const cw = @min(ms.w, bounds.w);
    const ch = @min(ms.h, bounds.h);
    s.content = .{
        .x = bounds.x + (bounds.w - cw) / 2,
        .y = bounds.y + bounds.h - s.opts.bottom_margin - ch,
        .w = cw,
        .h = ch,
    };
    const b = s.content;
    // background fills the content rect
    s.bg.layout(b);
    // content row: text start-aligned, action + dismiss end-aligned
    // (Compose OneRowSnackbar), vertically centered.
    // Children: [bg, text, (action), (dismiss)].
    const mid_y = b.y + b.h / 2;
    const end_pad: f32 = if (s.opts.dismiss) 0 else end_padding;
    var end_x = b.x + b.w - end_pad;
    // walk the content children from the end: dismiss, then action
    var i = n.children.items.len;
    while (i > 1) {
        i -= 1;
        const child = n.children.items[i];
        const cs = child.measure(.{ .max_w = b.w, .max_h = b.h });
        end_x -= cs.w;
        if (i == 2 and s.opts.action_label != null) end_x -= action_gap; // gap between action and dismiss
        child.layout(.{ .x = end_x, .y = mid_y - cs.h / 2, .w = cs.w, .h = cs.h });
    }
    // the text (index 1) at the start
    const text = n.children.items[1];
    const cs = text.measure(.{ .max_w = b.w, .max_h = b.h });
    text.layout(.{ .x = b.x + start_padding, .y = mid_y - cs.h / 2, .w = cs.w, .h = cs.h });
    const target: f32 = if (s.sig.peek()) 1 else 0;
    if (!s.laid_out) {
        s.anim_to = target;
        applyProgress(n, s, target);
        s.laid_out = true;
    } else if (target != s.anim_to) {
        animateProgress(n, s, target);
    }
}

fn snackPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx; // transparent chrome: the background child paints (transformed)
}

/// The slide + fade transform wraps the children (bg + content): own save so
/// the restore never pops a caller's canvas state. The slide offset is the
/// CONTENT height (the node's bounds may be the whole window).
fn snackPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    ui.paint.save(ctx);
    const s = stateOf(n);
    ui.paint.translate(ctx, 0, s.content.h * (1 - s.progress));
    ui.paint.layerAlpha(ctx, s.progress);
}

fn snackPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.restore(ctx);
}

fn snackMapPaintRect(n: *Node, r: Rect) Rect {
    const s = stateOf(n);
    const dy = s.content.h * (1 - s.progress);
    return .{ .x = r.x, .y = r.y + dy, .w = r.w, .h = r.h };
}

fn snackPreChildrenHit(n: *Node, px: f32, py: f32) node_mod.HitPoint {
    const s = stateOf(n);
    const dy = s.content.h * (1 - s.progress);
    return .{ .x = px, .y = py - dy };
}

/// Hit-testing covers the CONTENT rect only (translated by the slide) — an
/// overlay snackbar never shadows the content below it.
fn snackHitBounds(n: *Node) Rect {
    const s = stateOf(n);
    const b = s.content;
    const dy = b.h * (1 - s.progress);
    return .{ .x = b.x, .y = b.y + dy, .w = b.w, .h = b.h };
}

fn snackDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| {
        tl.cancelChannel(@ptrCast(&s.anim_channel));
        if (s.opts.timeout_ms > 0) tl.removeTicker(s.ticker);
    }
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = snackSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const snack_vtable = ui.node.VTable{
    .measure = snackMeasure,
    .layout = snackLayout,
    .paint = snackPaint,
    .pre_children_paint = snackPreChildrenPaint,
    .post_children_paint = snackPostChildrenPaint,
    .map_paint_rect = snackMapPaintRect,
    .hit_bounds = snackHitBounds,
    .pre_children_hit = snackPreChildrenHit,
    .deinit = snackDeinit,
};

// --- background child ---

fn bgPaint(n: *Node, ctx: *kx.Ctx) void {
    const b = n.bounds;
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, corner, stateOf(n.parent.?).opts.theme.colors.inverse_surface);
}

const bg_vtable = ui.node.VTable{
    .measure = struct {
        fn m(n: *Node, c: Constraints) Size {
            _ = n;
            return c.constrain(.{});
        }
    }.m,
    .layout = struct {
        fn l(n: *Node, b: Rect) void {
            _ = n;
            _ = b;
        }
    }.l,
    .paint = bgPaint,
};

// --- animation + timeout ---

fn animateProgress(n: *Node, s: *SnackBarState, to: f32) void {
    s.anim_to = to;
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.tweenAnim(.{ to, 0, 0, 0 }, slide_ms, .{ .ease = .standard }),
            .from = .{ s.progress, 0, 0, 0 },
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = snackAnimUpdateCb, .userdata = n },
            .on_complete = .{ .fn_ptr = snackAnimCompleteCb, .userdata = n },
        });
    } else {
        applyProgress(n, s, to);
    }
}

fn applyProgress(n: *Node, s: *SnackBarState, progress: f32) void {
    s.progress = progress;
    n.visible = progress > 0.001;
    n.markDirty();
}

fn snackAnimUpdateCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    applyProgress(n, stateOf(n), value[0]);
}

fn snackAnimCompleteCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    applyProgress(n, s, s.anim_to);
}

/// Open state changed (app set the signal): animate (or snap before the
/// first layout — the first layout applies the current state directly).
fn snackSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.sig.peek()) {
        s.timeout_armed = s.opts.timeout_ms > 0; // the ticker counts the deadline
    } else {
        s.timeout_armed = false;
        s.timeout_deadline = null;
        if (s.on_dismiss) |cb| cb.fn_ptr(cb.userdata);
    }
    if (!s.laid_out) return;
    const target: f32 = if (s.sig.peek()) 1 else 0;
    if (target != s.anim_to) animateProgress(n, s, target);
}

/// The auto-dismiss ticker: arms the deadline on the first tick after show,
/// hides the snackbar when it passes. has_pending keeps the host awake (the
/// timeout fires even at true idle).
fn snackTickerCb(userdata: ?*anyopaque, now_ms: u64) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (!s.timeout_armed) return;
    if (s.timeout_deadline == null) {
        s.timeout_deadline = now_ms + s.opts.timeout_ms;
        return;
    }
    if (now_ms >= s.timeout_deadline.?) {
        s.sig.set(false); // snackSyncCb fires on_dismiss + hides
    }
}

fn snackTickerPendingCb(userdata: ?*anyopaque) bool {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    return s.timeout_armed;
}

fn hideSnack(n: *Node) void {
    const s = stateOf(n);
    s.sig.set(false); // snackSyncCb fires on_dismiss + animates out
}

// --- factories ---

const text_w = @import("text.zig");
const input_w = @import("input.zig");
const icon_w = @import("icon.zig");

/// A snackbar. `visible` is app-owned; the snackbar subscribes (slide/fade +
/// auto-dismiss) and unsubscribes at deinit. `on_action` fires when the action
/// is pressed (the press also dismisses); `on_dismiss` fires on any dismissal
/// (timeout, dismiss icon, action).
pub fn snackBar(allocator: std.mem.Allocator, visible: *ui.state.Signal(bool), on_action: ?Callback, on_dismiss: ?Callback, opts: SnackBarOptions) !*Node {
    const node = try Node.create(allocator, &snack_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(SnackBarState);
    errdefer allocator.destroy(s);
    const t = opts.theme;
    // Internal background (the container surface, inside the transform).
    const bg = try Node.create(allocator, &bg_vtable);
    errdefer allocator.destroy(bg);
    // Text content (body_medium, inverse_on_surface).
    const label = try text_w.text(allocator, opts.text, .{
        .size = t.type_scale.body_medium.size,
        .color = t.colors.inverse_on_surface,
    });
    node.add(bg);
    node.add(label);
    // Optional action: a text button (inverse_primary label_large, state layer).
    if (opts.action_label) |action_label| {
        const on_press: Callback = .{
            .fn_ptr = struct {
                fn cb(ud: ?*anyopaque) void {
                    const n: *Node = @ptrCast(@alignCast(ud.?));
                    const st = stateOf(n);
                    if (st.on_action) |a| a.fn_ptr(a.userdata);
                    hideSnack(n); // M3: the action press dismisses the snackbar
                }
            }.cb,
            .userdata = node,
        };
        const btn = try input_w.button(allocator, on_press, .{
            .bg = 0x00000000,
            .bg_hover = theme_mod.stateLayer(t.colors.inverse_surface, t.colors.inverse_primary, t.state.hover),
            .bg_pressed = theme_mod.stateLayer(t.colors.inverse_surface, t.colors.inverse_primary, t.state.pressed),
            .padding = ui.layout.EdgeInsets.symmetric(8, 4),
        });
        btn.add(try text_w.text(allocator, action_label, .{
            .size = t.type_scale.label_large.size,
            .color = t.colors.inverse_primary,
        }));
        node.add(btn);
    }
    // Optional dismiss icon button (24dp close icon, inverse_on_surface).
    if (opts.dismiss) {
        const on_press: Callback = .{ .fn_ptr = struct {
            fn cb(ud: ?*anyopaque) void {
                hideSnack(@ptrCast(@alignCast(ud.?)));
            }
        }.cb, .userdata = node };
        const btn = try input_w.button(allocator, on_press, .{
            .bg = 0x00000000,
            .bg_hover = theme_mod.stateLayer(t.colors.inverse_surface, t.colors.inverse_on_surface, t.state.hover),
            .bg_pressed = theme_mod.stateLayer(t.colors.inverse_surface, t.colors.inverse_on_surface, t.state.pressed),
            .padding = ui.layout.EdgeInsets.all(12),
        });
        btn.add(try icon_w.icon(allocator, .close, .{ .size = 24, .color = t.colors.inverse_on_surface }));
        node.add(btn);
    }
    s.* = .{ .sig = visible, .opts = opts, .on_action = on_action, .on_dismiss = on_dismiss, .bg = bg };
    node.state = s;
    // Auto-dismiss ticker (registered once; no-ops while disarmed).
    if (anim.timeline()) |tl| {
        if (opts.timeout_ms > 0) {
            s.ticker = .{ .fn_ptr = snackTickerCb, .userdata = node, .has_pending = snackTickerPendingCb };
            tl.addTicker(s.ticker);
        }
    }
    ui.semantics.attach(node, .{ .role = .alert, .label = opts.text }); // Phase 2c
    visible.subscribe(.{ .callback = .{ .fn_ptr = snackSyncCb, .userdata = node } });
    return node;
}

// --- tests ---

const layout_w = @import("layout.zig");

test "snackbar: content-sized, min height 48, capped at 600 wide" {
    const visible = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer visible.deinit();
    const sb = try snackBar(std.testing.allocator, visible, null, null, .{ .text = "Saved" });
    defer sb.deinit();
    const m = sb.measure(.{ .max_w = 900, .max_h = 400 });
    try std.testing.expect(m.h >= min_height);
    try std.testing.expect(m.w <= max_width);
    try std.testing.expect(m.w > start_padding);
}

test "snackbar: hidden by default; show snaps (no timeline); dismiss icon closes it" {
    const visible = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer visible.deinit();
    var dismissed: u32 = 0;
    const on_dismiss: Callback = .{ .fn_ptr = struct {
        fn cb(ud: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ud.?));
            c.* += 1;
        }
    }.cb, .userdata = &dismissed };
    const sb = try snackBar(std.testing.allocator, visible, null, on_dismiss, .{
        .text = "Saved",
    });
    defer sb.deinit();
    sb.layout(.{ .x = 0, .y = 100, .w = 200, .h = 48 });
    try std.testing.expect(!sb.visible);
    // show: snaps (no timeline)
    visible.set(true);
    sb.layout(.{ .x = 0, .y = 100, .w = 200, .h = 48 });
    try std.testing.expect(sb.visible);
    try std.testing.expectEqual(@as(f32, 1), stateOf(sb).progress);
    // the dismiss icon button (last child) closes it
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const dismiss_btn = sb.children.items[sb.children.items.len - 1];
    const bb = dismiss_btn.bounds;
    router.dispatchPointer(sb, .{ .phase = .down, .x = bb.x + bb.w / 2, .y = bb.y + bb.h / 2 });
    router.dispatchPointer(sb, .{ .phase = .up, .x = bb.x + bb.w / 2, .y = bb.y + bb.h / 2 });
    try std.testing.expect(!visible.peek());
    try std.testing.expectEqual(@as(u32, 1), dismissed);
    sb.layout(.{ .x = 0, .y = 100, .w = 200, .h = 48 });
    try std.testing.expect(!sb.visible);
}

test "snackbar: the action press fires on_action and dismisses" {
    const visible = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer visible.deinit();
    var acted: u32 = 0;
    var dismissed: u32 = 0;
    const on_action: Callback = .{ .fn_ptr = struct {
        fn cb(ud: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ud.?));
            c.* += 1;
        }
    }.cb, .userdata = &acted };
    const on_dismiss: Callback = .{ .fn_ptr = struct {
        fn cb(ud: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ud.?));
            c.* += 1;
        }
    }.cb, .userdata = &dismissed };
    const sb = try snackBar(std.testing.allocator, visible, on_action, on_dismiss, .{
        .text = "Deleted",
        .action_label = "Undo",
        .timeout_ms = 0, // no auto-dismiss in this test
    });
    defer sb.deinit();
    sb.layout(.{ .x = 0, .y = 100, .w = 260, .h = 48 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // the action button is the 3rd child (bg, text, action, dismiss)
    const action_btn = sb.children.items[2];
    const bb = action_btn.bounds;
    router.dispatchPointer(sb, .{ .phase = .down, .x = bb.x + bb.w / 2, .y = bb.y + bb.h / 2 });
    router.dispatchPointer(sb, .{ .phase = .up, .x = bb.x + bb.w / 2, .y = bb.y + bb.h / 2 });
    try std.testing.expectEqual(@as(u32, 1), acted);
    try std.testing.expect(!visible.peek());
    try std.testing.expectEqual(@as(u32, 1), dismissed);
}

test "golden: snackbar paints the inverse_surface container with the text" {
    const t = theme_mod.light;
    const visible = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer visible.deinit();
    const sb = try snackBar(std.testing.allocator, visible, null, null, .{ .text = "Saved", .theme = t });
    defer sb.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 240, 80);
    defer r.deinit();
    // the snackbar self-positions: given a 200x48 area at (20,20), the content
    // rect sits at the bottom-center with a 12dp margin
    sb.layout(.{ .x = 20, .y = 20, .w = 200, .h = 48 });
    const c = stateOf(sb).content;
    r.paint(sb, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the container is inverse_surface — minus the text/dismiss ink, the
    // corner + edge AA (the RRect edges fall between pixels: ~300px)
    const cr: ui.node.Rect = .{ .x = c.x, .y = c.y, .w = c.w, .h = c.h };
    try std.testing.expect(@as(f32, @floatFromInt(f.countColorIn(cr, t.colors.inverse_surface))) > c.w * c.h - 600);
    try std.testing.expectEqual(t.colors.inverse_surface, f.pixelAt(@intFromFloat(c.x + 4), @intFromFloat(c.y + c.h - 4))); // interior, off the ink
    // hidden: nothing painted
    visible.set(false);
    sb.layout(.{ .x = 20, .y = 20, .w = 200, .h = 48 });
    r.paint(sb, 0x000000FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(@as(Color, 0x000000FF), f2.pixelAt(@intFromFloat(c.x + 4), @intFromFloat(c.y + c.h - 4)));
}
