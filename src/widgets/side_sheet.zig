// Side sheet (Phase 2d.3 PR D5, M3E) — standard + modal side sheets: a
// panel docked to the start/end edge of its parent, full height.
//
// Spec: the M3 side sheet spec (m2.material.io/components/sheets-side — the
// M3E side sheet has no Compose port) + material-components-android
// sidesheet/ (SideSheetBehavior, styles.xml, tokens.xml):
//   - standard (modal = false): a Surface panel, CornerNone (flush to the
//     edge), coplanar (level0, flat in v1) — no scrim; toggled by the signal
//   - modal (modal = true): a scrim (scrim @ 32%) over the body + a
//     SurfaceContainerLow panel (level1, flat in v1), content-side corners
//     CornerLarge 16dp, edge-side corners square (the M3 spec image; MDA
//     applies CornerLarge uniformly — v1 follows the spec image, consistent
//     with the bottom sheet's content-side-only corners)
//   - width: 256dp default (m3_comp_sheet_side_docked_container_width); the
//     standard width is app-set (the m2 spec: multiples of the 64dp top app
//     bar height)
//   - the panel slides horizontally in/out with the theme's SPATIAL spring;
//     the scrim alpha rides along (modal only). Without a timeline both snap.
//   - `side` is LOGICAL: start/end flip with the layout direction (RTL)
//
// Structure (mirrors the drawer / bottom sheet): the sheet node holds the
// `body` slot (behind), an internal scrim (modal only — hidden otherwise),
// and an internal panel (a transparent transform node: an internal
// background child + the `content` slot). The open state is a Signal(bool)
// owned by the app; the sheet subscribes (animation) and unsubscribes at
// deinit. While a MODAL sheet is open it registers on the router's modal back
// stack (Escape / hardware back closes it even when focus is outside).
//
// Sizing: the sheet fills FINITE constraints — a sheet is screen-height, so
// it measures to 100% of a bounded parent (window/overlay). Inside an
// unbounded parent (a scroll column), wrap it in a bounded box (e.g.
// constrainedBox with min_h = max_h).
//
// v1 deviations (documented, fixed later):
//   - No detached variant (16dp margin, CornerLarge all corners), no
//     drag-to-dismiss swipe (the state is signal-driven), no elevation
//     shadows (the raster shadow pass lands in Phase 3), no body resize on
//     open (the app's responsive layout), no M3E loading-indicator variant.
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

/// The edge the sheet is anchored to (logical — flips with the layout
/// direction; the default `end` is the side opposite the nav drawer).
pub const Side = enum { start, end };

pub const SideSheetOptions = struct {
    body: ?*Node = null, // the page content (behind)
    content: ?*Node = null, // the sheet content (panel)
    side: Side = .end,
    /// Modal sheets show a scrim and dismiss on scrim click / Escape / back;
    /// standard sheets are coplanar (no scrim) and only signal-toggled.
    modal: bool = false,
    width: f32 = 256, // m3_comp_sheet_side_docked_container_width
    theme: Theme = theme_mod.light,
    label: []const u8 = "Side sheet",
};

/// M3E measurement tokens.
const corner: f32 = 16; // CornerLarge (the modal content-side corners)
const scrim_max_alpha: f32 = 0.32;

const SideSheetState = struct {
    sig: *ui.state.Signal(bool),
    opts: SideSheetOptions,
    on_closed: ?Callback = null,
    scrim: *Node, // internal scrim node
    panel: *Node, // internal panel node
    progress: f32 = 0, // 0 = closed, 1 = open (animated)
    anim_to: f32 = 0,
    laid_out: bool = false,
    panel_w: f32 = 0, // laid-out panel width (drives the slide offset)
    anim_channel: u8 = 0, // channel marker (stable address)
    back_registered: bool = false, // on the router's modal back stack while open
};

const Callback = ui.state.Callback;

fn stateOf(n: *Node) *SideSheetState {
    return @ptrCast(@alignCast(n.state.?));
}

/// Whether the sheet's panel is anchored to the physical RIGHT edge (LTR
/// end / RTL start).
fn anchoredRight(opts: SideSheetOptions) bool {
    const rtl = ui.i18n.direction() == .rtl;
    return if (opts.side == .end) !rtl else rtl;
}

/// The direction the panel hides towards when closed: +1 hides off the
/// physical right edge, -1 off the physical left edge.
fn hideSign(opts: SideSheetOptions) f32 {
    return if (anchoredRight(opts)) 1 else -1;
}

// --- scrim ---

const ScrimState = struct {
    sheet: *Node,
    alpha: f32 = 0, // final opacity, 0..scrim_max_alpha (animated)
};

fn scrimStateOf(n: *Node) *ScrimState {
    return @ptrCast(@alignCast(n.state.?));
}

fn scrimPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = scrimStateOf(n);
    const b = n.bounds;
    if (s.alpha <= 0) return;
    const t = stateOf(s.sheet).opts.theme;
    // s.alpha is the final opacity (0..scrim_max_alpha, applied once — at
    // storage; multiplying again here would square the scrim alpha)
    const r: u32 = (t.colors.scrim >> 24) & 0xFF;
    const g: u32 = (t.colors.scrim >> 16) & 0xFF;
    const bl: u32 = (t.colors.scrim >> 8) & 0xFF;
    const alpha: u32 = @intFromFloat(std.math.clamp(s.alpha, 0, 1) * 255);
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, (r << 24) | (g << 16) | (bl << 8) | alpha);
}

fn scrimOnPointer(n: *Node, ev: input.PointerEvent) bool {
    if (ev.phase != .up) return ev.phase == .down; // consume the press, act on release
    const s = scrimStateOf(n);
    if (stateOf(s.sheet).sig.peek()) {
        closeSheet(s.sheet); // M3 barrier: a scrim click dismisses
        return true;
    }
    return false;
}

fn scrimDeinit(n: *Node) void {
    n.allocator.destroy(scrimStateOf(n));
}

const scrim_vtable = ui.node.VTable{
    .measure = struct {
        fn m(n: *Node, c: Constraints) Size {
            _ = n;
            return c.constrain(.{}); // zero-size; the sheet lays the scrim out
        }
    }.m,
    .layout = struct {
        fn l(n: *Node, b: Rect) void {
            _ = n;
            _ = b;
        }
    }.l,
    .paint = scrimPaint,
    .on_pointer = scrimOnPointer,
    .deinit = scrimDeinit,
};

// --- panel background (translated with the slide) ---

const PanelBgState = struct {
    sheet: *Node,
};

fn panelBgStateOf(n: *Node) *PanelBgState {
    return @ptrCast(@alignCast(n.state.?));
}

fn panelBgPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(panelBgStateOf(n).sheet);
    const b = n.bounds;
    const t = s.opts.theme;
    if (s.opts.modal) {
        // content-side corners CornerLarge, edge-side corners square: the
        // panel is flush to its anchored edge — a right-anchored panel
        // rounds its LEFT (content-side) corners, a left-anchored panel its
        // RIGHT corners
        const right_anchored = anchoredRight(s.opts);
        const tl: f32 = if (right_anchored) corner else 0;
        const tr: f32 = if (right_anchored) 0 else corner;
        const br: f32 = if (right_anchored) 0 else corner;
        const bl: f32 = if (right_anchored) corner else 0;
        ui.paint.fillRRectCorners(ctx, b.x, b.y, b.w, b.h, tl, tr, br, bl, t.colors.surface_container_low);
    } else {
        // standard: Surface, CornerNone (flush to the edge)
        ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, t.colors.surface);
    }
}

const panel_bg_vtable = ui.node.VTable{
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
    .paint = panelBgPaint,
    .deinit = struct {
        fn d(n: *Node) void {
            n.allocator.destroy(panelBgStateOf(n));
        }
    }.d,
};

// --- panel (slides horizontally) ---

const PanelState = struct {
    sheet: *Node,
    offset_x: f32 = 0, // slide offset (towards the anchored edge when closed)
};

fn panelStateOf(n: *Node) *PanelState {
    return @ptrCast(@alignCast(n.state.?));
}

fn panelPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    // own save: the restore in post_children_paint must not pop a caller's
    // canvas state (enclosing clips survive)
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
    .paint = struct {
        fn p(n: *Node, ctx: *kx.Ctx) void {
            _ = n;
            _ = ctx; // transparent: the background child paints (translated)
        }
    }.p,
    .pre_children_paint = panelPreChildrenPaint,
    .post_children_paint = panelPostChildrenPaint,
    .map_paint_rect = panelMapPaintRect,
    .hit_bounds = panelHitBounds,
    .pre_children_hit = panelPreChildrenHit,
    .deinit = panelDeinit,
};

// --- sheet ---

fn sheetMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    var size = Size{};
    if (s.opts.body) |body| size = body.measure(c);
    const w = if (std.math.isFinite(c.max_w)) c.max_w else size.w;
    const h = if (std.math.isFinite(c.max_h)) c.max_h else size.h;
    return c.constrain(.{ .w = w, .h = h });
}

fn sheetLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    if (s.opts.body) |body| body.layout(bounds);
    s.scrim.layout(bounds);
    // The panel sits at the anchored side edge, full height.
    s.panel_w = @min(s.opts.width, bounds.w);
    const px = if (anchoredRight(s.opts)) bounds.x + bounds.w - s.panel_w else bounds.x;
    s.panel.layout(.{ .x = px, .y = bounds.y, .w = s.panel_w, .h = bounds.h });
    // The panel's children in factory order: the background (fills the
    // panel), then the content slot (fills the panel).
    if (s.panel.children.items.len > 0) {
        s.panel.children.items[0].layout(.{ .x = px, .y = bounds.y, .w = s.panel_w, .h = bounds.h }); // background
    }
    if (s.opts.content != null and s.panel.children.items.len > 1) {
        s.panel.children.items[1].layout(.{ .x = px, .y = bounds.y, .w = s.panel_w, .h = bounds.h });
    }
    const target: f32 = if (s.sig.peek()) 1 else 0;
    if (!s.laid_out) {
        s.anim_to = target;
        applyProgress(n, s, target, if (s.opts.modal) target * scrim_max_alpha else 0);
        s.laid_out = true;
    } else if (target != s.anim_to) {
        animateProgress(n, s, target);
    }
}

fn sheetPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx; // transparent chrome: the body slot paints behind
}

fn sheetOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    // Escape dismisses an open MODAL sheet (the back stack covers it globally;
    // this covers the focused chain too)
    if (s.opts.modal and ev.kind == .key_down and ev.key == .escape and s.sig.peek()) {
        closeSheet(n);
        return true;
    }
    return false;
}

fn sheetDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel));
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = sheetSyncCb, .userdata = n } });
    if (s.back_registered) {
        if (input.current()) |r| r.popBackHandler(n); // destroyed while open
        s.back_registered = false;
    }
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const sheet_vtable = ui.node.VTable{
    .measure = sheetMeasure,
    .layout = sheetLayout,
    .paint = sheetPaint,
    .deinit = sheetDeinit,
    .on_key = sheetOnKey,
};

/// Slide the panel + fade the scrim to `to` (0/1) with the spatial spring;
/// without a timeline, snap.
fn animateProgress(n: *Node, s: *SideSheetState, to: f32) void {
    s.anim_to = to;
    const scrim_to: f32 = if (s.opts.modal) to * scrim_max_alpha else 0;
    const from: anim.Vec4 = .{ s.progress, scrimStateOf(s.scrim).alpha, 0, 0 };
    const target: anim.Vec4 = .{ to, scrim_to, 0, 0 };
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.springAnim(from, target, s.opts.theme.motion.springs.spatial_spring, .{ 0, 0, 0, 0 }),
            .from = from,
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = sheetAnimUpdateCb, .userdata = n },
            .on_complete = .{ .fn_ptr = sheetAnimCompleteCb, .userdata = n },
        });
    } else {
        applyProgress(n, s, to, scrim_to);
    }
}

fn applyProgress(n: *Node, s: *SideSheetState, progress: f32, scrim_alpha: f32) void {
    s.progress = progress;
    scrimStateOf(s.scrim).alpha = scrim_alpha;
    // the scrim shows only for a modal sheet (standard sheets are coplanar)
    s.scrim.visible = s.opts.modal and scrim_alpha > 0.001;
    // the panel slides towards its anchored edge when closed
    panelStateOf(s.panel).offset_x = hideSign(s.opts) * (s.panel_w * (1 - progress));
    markInternalsDirty(n, s);
}

fn markInternalsDirty(n: *Node, s: *SideSheetState) void {
    _ = n;
    const b = s.panel.bounds;
    const dx = panelStateOf(s.panel).offset_x;
    const visual = Rect{ .x = b.x + dx, .y = b.y, .w = b.w, .h = b.h };
    s.panel.markDirtyRect(node_mod.rectUnion(b, visual));
    s.scrim.markDirty();
}

fn sheetAnimUpdateCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    applyProgress(n, stateOf(n), value[0], value[1]);
}

fn sheetAnimCompleteCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const scrim_to: f32 = if (s.opts.modal) s.anim_to * scrim_max_alpha else 0;
    applyProgress(n, s, s.anim_to, scrim_to);
}

/// Open state changed (app set the signal): animate (or snap before the
/// first layout — the first layout applies the current state directly).
fn sheetSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    syncBackHandler(n, s); // before the laid_out gate: registration tracks state
    if (!s.laid_out) return;
    const target: f32 = if (s.sig.peek()) 1 else 0;
    if (target != s.anim_to) animateProgress(n, s, target);
}

fn closeSheet(n: *Node) void {
    const s = stateOf(n);
    s.sig.set(false);
    if (s.on_closed) |cb| cb.fn_ptr(cb.userdata);
}

/// Escape / hardware-back while a MODAL sheet is open (the router consults
/// the modal back stack before the navigator — dispatchBack).
fn sheetBackCb(userdata: ?*anyopaque) bool {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (!s.opts.modal or !s.sig.peek()) return false;
    closeSheet(n); // the signal sync pops the handler
    return true;
}

/// Keep the router's modal back stack in sync with the open state (modal
/// sheets only — standard sheets are not modal barriers).
fn syncBackHandler(n: *Node, s: *SideSheetState) void {
    const want = s.opts.modal and s.sig.peek();
    if (want == s.back_registered) return;
    const router = input.current() orelse return;
    if (want) {
        if (router.pushBackHandler(.{ .fn_ptr = sheetBackCb, .userdata = n })) s.back_registered = true;
    } else {
        router.popBackHandler(n);
        s.back_registered = false;
    }
}

/// A side sheet (standard or modal). Slots: `content` (the panel), `body`
/// (the page behind). `open` is app-owned; the sheet subscribes (slide +
/// scrim animation) and unsubscribes at deinit. `on_closed` fires when a
/// modal sheet is dismissed (scrim click / Escape / back button).
pub fn sideSheet(allocator: std.mem.Allocator, open: *ui.state.Signal(bool), on_closed: ?Callback, opts: SideSheetOptions) !*Node {
    const node = try Node.create(allocator, &sheet_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(SideSheetState);
    errdefer allocator.destroy(s);
    // Internal scrim.
    const scrim = try Node.create(allocator, &scrim_vtable);
    errdefer allocator.destroy(scrim);
    const ss = try allocator.create(ScrimState);
    errdefer allocator.destroy(ss);
    ss.* = .{ .sheet = node, .alpha = 0 };
    scrim.state = ss;
    // Internal panel + its background child (the translated container surface).
    const panel = try Node.create(allocator, &panel_vtable);
    errdefer allocator.destroy(panel);
    const ps = try allocator.create(PanelState);
    errdefer allocator.destroy(ps);
    ps.* = .{ .sheet = node, .offset_x = 0 };
    panel.state = ps;
    const panel_bg = try Node.create(allocator, &panel_bg_vtable);
    errdefer allocator.destroy(panel_bg);
    const bgs = try allocator.create(PanelBgState);
    errdefer allocator.destroy(bgs);
    bgs.* = .{ .sheet = node };
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
    ui.semantics.attach(scrim, .{ .role = .button, .label = "Close sheet", .actions = ui.semantics.Actions.initOne(.activate) }); // Phase 2c
    ui.semantics.attach(panel, .{ .role = .group, .label = opts.label }); // Phase 2c
    open.subscribe(.{ .callback = .{ .fn_ptr = sheetSyncCb, .userdata = node } });
    syncBackHandler(node, s); // already open at build: register immediately
    return node;
}

// --- tests ---

const text_w = @import("text.zig");

test "side_sheet: closed by default — the scrim is hidden, the panel off-screen" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const d = try sideSheet(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
        .content = try text_w.text(std.testing.allocator, "Sheet", .{}),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s = stateOf(d);
    try std.testing.expect(!s.scrim.visible);
    try std.testing.expectEqual(@as(f32, 0), s.progress);
    // closed: the panel (end side, LTR) is translated fully off the right edge
    try std.testing.expectEqual(s.panel_w, panelStateOf(s.panel).offset_x);
}

test "side_sheet: the panel docks to the side edge, full height, width capped" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    // end side (LTR): the panel's right edge is the parent's right edge
    const d = try sideSheet(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
        .content = try text_w.text(std.testing.allocator, "Sheet", .{}),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s = stateOf(d);
    const pb = s.panel.bounds;
    try std.testing.expectEqual(@as(f32, 320), pb.x + pb.w); // right edge
    try std.testing.expectEqual(@as(f32, 200), pb.h); // full height
    try std.testing.expectEqual(@as(f32, 256), pb.w); // the default width (320 parent)
    try std.testing.expectEqual(@as(f32, 0), panelStateOf(s.panel).offset_x); // open: no slide
    // start side: the panel's left edge is the parent's left edge
    const st = try sideSheet(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
        .side = .start,
    });
    defer st.deinit();
    st.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    try std.testing.expectEqual(@as(f32, 0), stateOf(st).panel.bounds.x);
    // a narrow parent clamps the panel width
    d.layout(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    try std.testing.expectEqual(@as(f32, 200), stateOf(d).panel.bounds.w);
}

test "side_sheet: without a timeline the panel snaps open/closed on the signal" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const d = try sideSheet(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s = stateOf(d);
    open.set(true);
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    try std.testing.expectEqual(@as(f32, 1), s.progress);
    try std.testing.expectEqual(@as(f32, 0), panelStateOf(s.panel).offset_x);
    open.set(false);
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    try std.testing.expectEqual(@as(f32, 0), s.progress);
    try std.testing.expectEqual(s.panel_w, panelStateOf(s.panel).offset_x); // off-screen again
}

test "side_sheet: a modal sheet shows the scrim; a scrim click + Escape close it; a standard sheet never scrims" {
    var closed: u32 = 0;
    const cb = Callback{ .fn_ptr = struct {
        fn f(userdata: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(userdata.?));
            c.* += 1;
        }
    }.f, .userdata = &closed };
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    // modal: the scrim shows while open
    const m = try sideSheet(std.testing.allocator, open, cb, .{
        .modal = true,
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
    });
    defer m.deinit();
    m.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    try std.testing.expect(stateOf(m).scrim.visible);
    try std.testing.expect(stateOf(m).back_registered); // on the modal back stack
    // a scrim click closes (the scrim fills the parent; the panel covers the
    // right 256dp — click the left part)
    router.dispatchPointer(m, .{ .phase = .down, .x = 20, .y = 100, .raw_x = 20, .raw_y = 100 });
    router.dispatchPointer(m, .{ .phase = .up, .x = 20, .y = 100, .raw_x = 20, .raw_y = 100 });
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 1), closed); // on_closed fired
    // Escape closes too (the focus is inside the sheet's subtree, like the
    // drawer test)
    open.set(true);
    m.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    input.requestFocus(m.children.items[0]); // the body slot
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .escape });
    try std.testing.expect(!open.peek());
    // standard: no scrim, Escape does NOT close
    const so = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer so.deinit();
    const st = try sideSheet(std.testing.allocator, so, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
    });
    defer st.deinit();
    st.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    try std.testing.expect(!stateOf(st).scrim.visible);
    try std.testing.expect(!stateOf(st).back_registered);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .escape });
    try std.testing.expect(so.peek()); // standard sheets are not modal barriers
}

test "side_sheet: RTL flips the anchored side (end → the physical left edge)" {
    const i18n = try ui.i18n.I18n.init(std.testing.allocator, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const d = try sideSheet(std.testing.allocator, open, null, .{
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0x112233FF),
    });
    defer d.deinit();
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    const s = stateOf(d);
    // end side in RTL = the physical left edge
    try std.testing.expectEqual(@as(f32, 0), s.panel.bounds.x);
    // closed: the panel slides off the LEFT edge (negative offset)
    open.set(false);
    d.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    try std.testing.expectEqual(-s.panel_w, panelStateOf(s.panel).offset_x);
}

test "golden: a modal sheet paints the scrim + the SurfaceContainerLow panel with content-side rounded corners" {
    const t = theme_mod.light;
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const d = try sideSheet(std.testing.allocator, open, null, .{
        .modal = true,
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0xFFFFFFFF),
        .content = try text_w.text(std.testing.allocator, "Filters", .{}),
        .theme = t,
    });
    defer d.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 340, 220);
    defer r.deinit();
    d.layout(.{ .x = 10, .y = 10, .w = 320, .h = 200 });
    r.paint(d, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the scrim over the body (left of the panel): scrim @ 0.32 over white
    try golden.expectPixelApprox(f, 20, 100, golden.blendOver(ui.paint.withAlphaScaled(t.colors.scrim, scrim_max_alpha), 0xFFFFFFFF));
    // the panel (right edge, x = 10 + 320 - 256 = 74): surface_container_low
    try std.testing.expectEqual(t.colors.surface_container_low, f.pixelAt(200, 100));
    // the content-side (left) corners are rounded 16: the exact top-left
    // corner of the panel is outside the fill — the scrim (behind the
    // panel) shows through there
    try golden.expectPixelApprox(f, 74, 10, golden.blendOver(ui.paint.withAlphaScaled(t.colors.scrim, scrim_max_alpha), 0xFFFFFFFF));
    // the edge-side (right) corners are square: inside the corner the fill
    // is there (the panel's top-right corner at x = 330)
    try std.testing.expectEqual(t.colors.surface_container_low, f.pixelAt(329, 11));
    // the content slot paints inside the panel (the default text: black,
    // at the panel's top-left)
    try std.testing.expect(f.countColorIn(.{ .x = 80, .y = 12, .w = 120, .h = 24 }, 0x000000FF) > 0);
}

test "golden: a standard sheet paints a square Surface panel, no scrim" {
    const t = theme_mod.light;
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const d = try sideSheet(std.testing.allocator, open, null, .{
        .side = .start,
        .body = try golden.solidBox(std.testing.allocator, 320, 200, 0xFFFFFFFF),
        .theme = t,
    });
    defer d.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 340, 220);
    defer r.deinit();
    d.layout(.{ .x = 10, .y = 10, .w = 320, .h = 200 });
    r.paint(d, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the panel (start side, x = 10): surface
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(100, 100));
    // the panel's top-left corner is square (CornerNone)
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(11, 11));
    // no scrim: the body right of the panel is untouched white
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(300, 100));
}
