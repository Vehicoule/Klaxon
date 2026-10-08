// Navigation drawer widget (Phase 2d.1, M3E batch 1) — modal drawer.
//
// Spec: m3.material.io/components/navigation-drawer (M3E) + Compose
// NavigationDrawerTokens (Modal*):
//   - container width 360 (max), height 100%, color surface_container_low,
//     elevation level1 (the raster shadow pass lands in Phase 3 — v1 draws
//     the flat container),
//   - container shape: 16dp corner radius on the END side only (CornerLargeEnd),
//   - scrim: the scrim token at 32% opacity, covering the body; a click on it
//     closes the drawer (M3 barrier),
//   - motion: the panel slides with the theme's SPATIAL spring; the scrim
//     alpha rides along. Without a timeline both snap.
//
// Structure: the drawer node holds three children — the `body` slot (the
// page content, behind), an internal scrim node, and an internal panel node
// (the `content` slot inside). The open/closed state is a Signal(bool) owned
// by the app; the drawer subscribes (animation) and unsubscribes at deinit.
// No edge-swipe in v1: the state is signal-driven (a hamburger button or a
// gesture detector sets it).
//
// Sizing: the drawer fills FINITE constraints — a modal is screen-height, so
// it measures to 100% of a bounded parent (window/overlay). Inside an
// unbounded parent (a scroll column), it would swallow all the remaining
// main-axis space: wrap it in a bounded box (e.g. constrainedBox with
// min_h = max_h) to give it a fixed stage.
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
const Callback = ui.state.Callback;

/// M3 modal drawer: scrim opacity 32%, end-side corner radius 16 (shape.large).
const scrim_max_alpha: f32 = 0.32;
const panel_radius: f32 = 16;

pub const DrawerOptions = struct {
    theme: Theme = theme_mod.light,
    width: f32 = 360, // M3 modal drawer container width
    label: []const u8 = "Navigation drawer", // panel semantic label (borrowed)
    content: ?*Node = null, // the panel content
    body: ?*Node = null, // the page content (behind the scrim)
};

const DrawerState = struct {
    sig: *ui.state.Signal(bool),
    opts: DrawerOptions,
    on_closed: ?Callback = null,
    panel: *Node, // internal panel node
    scrim: *Node, // internal scrim node
    progress: f32 = 0, // 0 = closed, 1 = open (animated)
    anim_to: f32 = 0, // current animation target
    laid_out: bool = false,
    panel_w: f32 = 0, // laid-out panel width (drives the slide offset)
    anim_channel: u8 = 0, // channel marker (stable address)
    back_registered: bool = false, // on the router's modal back stack while open
};

fn stateOf(n: *Node) *DrawerState {
    return @ptrCast(@alignCast(n.state.?));
}

/// The direction the panel hides towards when closed: -1 in LTR (off the
/// start side = left), +1 in RTL.
fn hideSign() f32 {
    return if (ui.i18n.direction() == .rtl) 1 else -1;
}

// --- internal panel node ---
//
// The panel is a transparent transform node (its pre_children_paint applies
// the animated slide): its children — an internal background node and the
// `content` slot — paint translated. The background is a child (not the
// panel's own paint) so the slide moves it too.

const PanelState = struct {
    drawer: *Node, // back-pointer (reads theme + width)
    offset_x: f32 = 0, // animated translation (paint-time)
};

fn panelStateOf(n: *Node) *PanelState {
    return @ptrCast(@alignCast(n.state.?));
}

fn panelMeasure(n: *Node, c: Constraints) Size {
    const s = panelStateOf(n);
    const opts = stateOf(s.drawer).opts;
    const w = if (std.math.isFinite(c.max_w)) @min(opts.width, c.max_w) else opts.width;
    const h = if (std.math.isFinite(c.max_h)) c.max_h else 0;
    return c.constrain(.{ .w = w, .h = h });
}
fn panelLayout(n: *Node, bounds: Rect) void {
    // Fill semantics: the background and the content slot fill the panel.
    for (n.children.items) |child| child.layout(bounds);
}
fn panelPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx; // transparent: the background child paints (translated)
}
fn panelPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    // Own save: the restore in post_children_paint must not pop a caller's
    // canvas state — an enclosing clip (scroll view, damage rect) survives.
    ui.paint.save(ctx);
    ui.paint.translate(ctx, panelStateOf(n).offset_x, 0);
}
fn panelPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.restore(ctx);
}
fn panelMapPaintRect(n: *Node, r: Rect) Rect {
    const dx = panelStateOf(n).offset_x;
    return .{ .x = r.x + dx, .y = r.y, .w = r.w, .h = r.h };
}
fn panelPreChildrenHit(n: *Node, px: f32, py: f32) node_mod.HitPoint {
    const dx = panelStateOf(n).offset_x;
    return .{ .x = px - dx, .y = py };
}
fn panelHitBounds(n: *Node) Rect {
    const b = n.bounds;
    const dx = panelStateOf(n).offset_x;
    return .{ .x = b.x + dx, .y = b.y, .w = b.w, .h = b.h };
}
fn panelDeinit(n: *Node) void {
    n.allocator.destroy(panelStateOf(n));
}
const panel_vtable = ui.node.VTable{
    .measure = panelMeasure,
    .layout = panelLayout,
    .paint = panelPaint,
    .deinit = panelDeinit,
    .pre_children_paint = panelPreChildrenPaint,
    .post_children_paint = panelPostChildrenPaint,
    .map_paint_rect = panelMapPaintRect,
    .hit_bounds = panelHitBounds,
    .pre_children_hit = panelPreChildrenHit,
};

// --- internal panel background node (the translated container surface) ---

const PanelBgState = struct { drawer: *Node };

fn panelBgStateOf(n: *Node) *PanelBgState {
    return @ptrCast(@alignCast(n.state.?));
}

fn panelBgMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = c.max_w, .h = c.max_h });
}
fn panelBgLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn panelBgPaint(n: *Node, ctx: *kx.Ctx) void {
    const t = stateOf(panelBgStateOf(n).drawer).opts.theme;
    const b = n.bounds;
    // Corner radius on the END side only: clip to the panel rect, then draw
    // a full pill shifted towards the start side — the start-side corners
    // land outside the clip and stay square.
    ui.paint.save(ctx);
    ui.paint.clipRect(ctx, b.x, b.y, b.w, b.h);
    const shift = hideSign() * panel_radius;
    ui.paint.fillRRect(ctx, b.x + shift, b.y, b.w + panel_radius, b.h, panel_radius, t.colors.surface_container_low);
    ui.paint.restore(ctx);
}
fn panelBgDeinit(n: *Node) void {
    n.allocator.destroy(panelBgStateOf(n));
}
const panel_bg_vtable = ui.node.VTable{
    .measure = panelBgMeasure,
    .layout = panelBgLayout,
    .paint = panelBgPaint,
    .deinit = panelBgDeinit,
};

// --- internal scrim node ---

const ScrimState = struct {
    drawer: *Node, // back-pointer (reads theme + close)
    alpha: f32 = 0, // 0..scrim_max_alpha (animated)
};

fn scrimStateOf(n: *Node) *ScrimState {
    return @ptrCast(@alignCast(n.state.?));
}

fn scrimMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = c.max_w, .h = c.max_h });
}
fn scrimLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn scrimPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = scrimStateOf(n);
    const t = stateOf(s.drawer).opts.theme;
    const b = n.bounds;
    const a: u32 = @intFromFloat(std.math.clamp(s.alpha, 0, 1) * 255);
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, (t.colors.scrim & 0xFFFFFF00) | a);
}
fn scrimOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = scrimStateOf(n);
    switch (ev.phase) {
        .down => return true, // capture the press
        .up => {
            if (n.bounds.contains(ev.x, ev.y)) closeDrawer(s.drawer);
            return true;
        },
        else => return true,
    }
}
fn scrimDeinit(n: *Node) void {
    input.releaseNode(n);
    n.allocator.destroy(scrimStateOf(n));
}
const scrim_vtable = ui.node.VTable{
    .measure = scrimMeasure,
    .layout = scrimLayout,
    .paint = scrimPaint,
    .deinit = scrimDeinit,
    .on_pointer = scrimOnPointer,
};

// --- drawer node ---

/// Snap to a progress value (first layout / no timeline): offset + alpha +
/// scrim visibility, then repaint both internals.
fn applyProgress(n: *Node, s: *DrawerState, progress: f32, alpha: f32) void {
    s.progress = progress;
    panelStateOf(s.panel).offset_x = hideSign() * (s.panel_w * (1 - progress));
    scrimStateOf(s.scrim).alpha = alpha;
    s.scrim.visible = progress > 0.01;
    markInternalsDirty(n, s);
}

/// Repaint the panel (covering the swept region) and the scrim.
fn markInternalsDirty(n: *Node, s: *DrawerState) void {
    _ = n;
    const b = s.panel.bounds;
    const dx = panelStateOf(s.panel).offset_x;
    const visual = Rect{ .x = b.x + dx, .y = b.y, .w = b.w, .h = b.h };
    s.panel.markDirtyRect(node_mod.rectUnion(b, visual));
    s.scrim.markDirty();
}

fn drawerAnimUpdateCb(userdata: ?*anyopaque, v: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.progress = v[0];
    panelStateOf(s.panel).offset_x = hideSign() * (s.panel_w * (1 - v[0]));
    scrimStateOf(s.scrim).alpha = v[1];
    s.scrim.visible = v[0] > 0.01;
    markInternalsDirty(n, s);
}

/// Springs settle within 0.1 units — snap to the exact target so no residue
/// remains on the panel offset / scrim alpha.
fn drawerAnimCompleteCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    applyProgress(n, s, s.anim_to, s.anim_to * scrim_max_alpha);
}

/// Slide the panel + fade the scrim to `to` (0/1) with the spatial spring;
/// without a timeline, snap.
fn animateProgress(n: *Node, s: *DrawerState, to: f32) void {
    s.anim_to = to;
    const from: anim.Vec4 = .{ s.progress, scrimStateOf(s.scrim).alpha, 0, 0 };
    const target: anim.Vec4 = .{ to, to * scrim_max_alpha, 0, 0 };
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.springAnim(from, target, s.opts.theme.motion.springs.spatial_spring, .{ 0, 0, 0, 0 }),
            .from = from,
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = drawerAnimUpdateCb, .userdata = n },
            .on_complete = .{ .fn_ptr = drawerAnimCompleteCb, .userdata = n },
        });
    } else {
        applyProgress(n, s, to, to * scrim_max_alpha);
    }
}

/// Open state changed (app set the signal): animate (or snap before the
/// first layout — the first layout applies the current state directly).
fn drawerSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    syncBackHandler(n, s); // before the laid_out gate: registration tracks state
    if (!s.laid_out) return;
    const target: f32 = if (s.sig.peek()) 1 else 0;
    if (target != s.anim_to) animateProgress(n, s, target);
}

fn closeDrawer(n: *Node) void {
    const s = stateOf(n);
    s.sig.set(false);
    if (s.on_closed) |cb| cb.fn_ptr(cb.userdata);
}

/// Escape / hardware-back while the drawer is open (the router consults the
/// modal back stack before the navigator — dispatchBack).
fn drawerBackCb(userdata: ?*anyopaque) bool {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (!s.sig.peek()) return false;
    closeDrawer(n); // the signal sync pops the handler
    return true;
}

/// Keep the router's modal back stack in sync with the open state: while open,
/// Escape dismisses the drawer even when keyboard focus is outside it.
fn syncBackHandler(n: *Node, s: *DrawerState) void {
    const want = s.sig.peek();
    if (want == s.back_registered) return;
    const router = input.current() orelse return;
    if (want) {
        if (router.pushBackHandler(.{ .fn_ptr = drawerBackCb, .userdata = n })) s.back_registered = true;
    } else {
        router.popBackHandler(n);
        s.back_registered = false;
    }
}

fn drawerMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    var size = Size{};
    if (s.opts.body) |body| size = body.measure(c);
    const w = if (std.math.isFinite(c.max_w)) c.max_w else size.w;
    const h = if (std.math.isFinite(c.max_h)) c.max_h else size.h;
    return c.constrain(.{ .w = w, .h = h });
}

fn drawerLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    s.panel_w = @min(s.opts.width, bounds.w);
    if (s.opts.body) |body| body.layout(bounds);
    s.scrim.layout(bounds);
    // The panel sits at the start side, full height (its paint-time
    // translation slides it in/out).
    const px = if (ui.i18n.direction() == .rtl) bounds.x + bounds.w - s.panel_w else bounds.x;
    s.panel.layout(.{ .x = px, .y = bounds.y, .w = s.panel_w, .h = bounds.h });
    const target: f32 = if (s.sig.peek()) 1 else 0;
    if (!s.laid_out) {
        s.anim_to = target;
        applyProgress(n, s, target, target * scrim_max_alpha);
        s.laid_out = true;
    } else if (target != s.anim_to) {
        animateProgress(n, s, target);
    }
}

fn drawerPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx; // transparent chrome: the body slot paints behind
}

fn drawerOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind == .key_down and ev.key == .escape and s.sig.peek()) {
        closeDrawer(n); // M3: Escape dismisses the modal drawer
        return true;
    }
    return false;
}

fn drawerDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel)); // the update cb points at this node
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = drawerSyncCb, .userdata = n } });
    if (s.back_registered) {
        if (input.current()) |r| r.popBackHandler(n); // destroyed while open
        s.back_registered = false;
    }
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const drawer_vtable = ui.node.VTable{
    .measure = drawerMeasure,
    .layout = drawerLayout,
    .paint = drawerPaint,
    .deinit = drawerDeinit,
    .on_key = drawerOnKey,
};

/// Modal navigation drawer (M3E). Slots: `content` (the panel), `body` (the
/// page behind). `open` is app-owned; the drawer subscribes (slide + scrim
/// animation) and unsubscribes at deinit. `on_closed` fires when the drawer
/// is dismissed (scrim click / Escape).
pub fn drawer(allocator: std.mem.Allocator, open: *ui.state.Signal(bool), on_closed: ?Callback, opts: DrawerOptions) !*Node {
    const node = try Node.create(allocator, &drawer_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(DrawerState);
    errdefer allocator.destroy(s);
    // Internal scrim.
    const scrim = try Node.create(allocator, &scrim_vtable);
    errdefer allocator.destroy(scrim);
    const ss = try allocator.create(ScrimState);
    errdefer allocator.destroy(ss);
    ss.* = .{ .drawer = node, .alpha = 0 };
    scrim.state = ss;
    // Internal panel + its background child (the translated container surface).
    const panel = try Node.create(allocator, &panel_vtable);
    errdefer allocator.destroy(panel);
    const ps = try allocator.create(PanelState);
    errdefer allocator.destroy(ps);
    ps.* = .{ .drawer = node, .offset_x = 0 };
    panel.state = ps;
    const panel_bg = try Node.create(allocator, &panel_bg_vtable);
    errdefer allocator.destroy(panel_bg);
    const bgs = try allocator.create(PanelBgState);
    errdefer allocator.destroy(bgs);
    bgs.* = .{ .drawer = node };
    panel_bg.state = bgs;
    panel.add(panel_bg);
    s.* = .{ .sig = open, .opts = opts, .on_closed = on_closed, .panel = panel, .scrim = scrim };
    node.state = s;
    // Paint order: body (behind), scrim, panel (front); the panel holds the
    // background child first, then the content slot.
    if (opts.body) |body| node.add(body);
    node.add(scrim);
    node.add(panel);
    if (opts.content) |content| panel.add(content);
    ui.semantics.attach(scrim, .{ .role = .button, .label = "Close drawer", .actions = ui.semantics.Actions.initOne(.activate) }); // Phase 2c
    ui.semantics.attach(panel, .{ .role = .group, .label = opts.label }); // Phase 2c
    open.subscribe(.{ .callback = .{ .fn_ptr = drawerSyncCb, .userdata = node } });
    syncBackHandler(node, s); // already open at build: register immediately
    return node;
}

// --- tests ---

const text_w = @import("text.zig");
const layout_w = @import("layout.zig");

test "drawer: closed by default — the scrim is hidden, the panel off-screen" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const d = try drawer(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
        .content = try text_w.text(std.testing.allocator, "Panel", .{}),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s = stateOf(d);
    try std.testing.expectEqual(@as(f32, 0), s.progress);
    try std.testing.expect(!s.scrim.visible);
    try std.testing.expectEqual(@as(f32, -320), panelStateOf(s.panel).offset_x); // panel_w = min(360, 320) = 320
    try std.testing.expectEqual(@as(f32, 0), scrimStateOf(s.scrim).alpha);
}

test "drawer: measure/layout fill the parent; the panel is 360 wide max" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const body = try golden.solidBox(std.testing.allocator, 100, 100, 0xFF);
    const d = try drawer(std.testing.allocator, open, null, .{ .body = body });
    defer d.deinit();
    const m = d.measure(.{ .max_w = 480, .max_h = 600 });
    try std.testing.expectEqual(@as(f32, 480), m.w);
    try std.testing.expectEqual(@as(f32, 600), m.h);
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 600 });
    const s = stateOf(d);
    try std.testing.expectEqual(@as(f32, 360), s.panel.bounds.w);
    try std.testing.expectEqual(@as(f32, 600), s.panel.bounds.h);
    try std.testing.expectEqual(@as(f32, 0), s.panel.bounds.x); // start side (LTR)
    try std.testing.expectEqual(@as(f32, 1), s.progress); // open: snapped at first layout
    try std.testing.expect(s.scrim.visible);
    try std.testing.expectApproxEqAbs(scrim_max_alpha, scrimStateOf(s.scrim).alpha, 1e-6);
}

test "drawer: without a timeline the panel snaps open/closed on the signal" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const d = try drawer(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0xFF),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s = stateOf(d);
    open.set(true);
    try std.testing.expectEqual(@as(f32, 1), s.progress);
    try std.testing.expectEqual(@as(f32, 0), panelStateOf(s.panel).offset_x);
    try std.testing.expect(s.scrim.visible);
    open.set(false);
    try std.testing.expectEqual(@as(f32, 0), s.progress);
    try std.testing.expectEqual(@as(f32, -320), panelStateOf(s.panel).offset_x);
    try std.testing.expect(!s.scrim.visible);
}

test "drawer: with a timeline the panel slides (spatial spring) and the scrim fades" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const d = try drawer(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0xFF),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s = stateOf(d);
    open.set(true); // launches the spring
    try std.testing.expect(tl.hasActive());
    tl.tick(0); // lazy start
    try std.testing.expectEqual(@as(f32, 0), s.progress);
    tl.tick(50); // mid-flight: strictly between closed and open
    try std.testing.expect(s.progress > 0 and s.progress < 1);
    try std.testing.expect(panelStateOf(s.panel).offset_x > -320 and panelStateOf(s.panel).offset_x < 0);
    try std.testing.expect(s.scrim.visible); // alpha > 0 as soon as progress > 0.01
    tl.tick(10_000); // settled: exactly open
    try std.testing.expectEqual(@as(f32, 1), s.progress);
    try std.testing.expectEqual(@as(f32, 0), panelStateOf(s.panel).offset_x);
    try std.testing.expectApproxEqAbs(scrim_max_alpha, scrimStateOf(s.scrim).alpha, 1e-4);
    try std.testing.expect(!tl.hasActive());
}

test "drawer: a scrim click closes it (and fires on_closed); Escape too" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    var closed: u32 = 0;
    const d = try drawer(std.testing.allocator, open, .{ .fn_ptr = struct {
        fn cb(ud: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ud.?));
            c.* += 1;
        }
    }.cb, .userdata = &closed }, .{
        .body = try golden.solidBox(std.testing.allocator, 480, 200, 0xFF),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    var router = input.InputRouter{};
    // the panel is 360 wide (start side): a click at x=400 hits the scrim
    router.dispatchPointer(d, .{ .phase = .down, .x = 400, .y = 100 });
    router.dispatchPointer(d, .{ .phase = .up, .x = 400, .y = 100 });
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 1), closed);
    // Escape closes too (the focus is inside the drawer's subtree)
    open.set(true);
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    var router2 = input.InputRouter{};
    input.setCurrent(&router2);
    defer input.setCurrent(null);
    const body_node = d.children.items[0];
    input.requestFocus(body_node);
    try std.testing.expect(router2.dispatchKey(.{ .kind = .key_down, .key = .escape }));
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 2), closed);
}

test "drawer: the global back path closes it even when focus is outside" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const d = try drawer(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 480, 200, 0xFF),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // a navigator back handler is registered (would pop a page)
    var popped: u32 = 0;
    router.setBackHandler(.{ .fn_ptr = struct {
        fn cb(ud: ?*anyopaque) bool {
            const p: *u32 = @ptrCast(@alignCast(ud.?));
            p.* += 1;
            return true;
        }
    }.cb, .userdata = &popped });
    // open the drawer with no focus inside it: it registers on the back stack
    open.set(true);
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    try std.testing.expectEqual(@as(usize, 1), router.back_stack_len);
    // back request: the drawer dismisses itself, the navigator is NOT popped
    try std.testing.expect(router.dispatchBack());
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 0), popped);
    try std.testing.expectEqual(@as(usize, 0), router.back_stack_len);
    // closed: back falls through to the navigator
    try std.testing.expect(router.dispatchBack());
    try std.testing.expectEqual(@as(u32, 1), popped);
}

test "golden: drawer paints the body, the scrim and the panel (open)" {
    const t = theme_mod.light;
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const body = try golden.solidBox(std.testing.allocator, 480, 200, 0x112233FF);
    const panel_content = try layout_w.padding(std.testing.allocator, .{ .left = 16, .top = 16, .right = 16, .bottom = 16 });
    panel_content.add(try text_w.text(std.testing.allocator, "Drawer", .{ .color = t.colors.on_surface }));
    const d = try drawer(std.testing.allocator, open, null, .{ .theme = t, .body = body, .content = panel_content });
    defer d.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 480, 200);
    defer r.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    r.paint(d, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // panel (360 wide, surface_container_low) on the start side
    try std.testing.expect(f.countColorIn(.{ .x = 0, .y = 0, .w = 360, .h = 200 }, t.colors.surface_container_low) > 300 * 180);
    // scrim over the body (right of the panel): the pure body color is gone
    // (blended with the 32% black scrim)
    try std.testing.expect(f.countColorIn(.{ .x = 400, .y = 100, .w = 60, .h = 80 }, 0x112233FF) == 0);
    try std.testing.expect(f.countNotIn(.{ .x = 400, .y = 100, .w = 60, .h = 80 }, 0x112233FF) > 60 * 80 - 40);
    // closed: no panel, no scrim — the body shows through
    open.set(false);
    d.layout(.{ .x = 0, .y = 0, .w = 480, .h = 200 });
    r.paint(d, 0x000000FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expect(f2.countColorIn(.{ .x = 0, .y = 0, .w = 360, .h = 200 }, t.colors.surface_container_low) == 0);
    try std.testing.expect(f2.countColorIn(.{ .x = 400, .y = 100, .w = 60, .h = 80 }, 0x112233FF) > 60 * 80 - 40);
}
