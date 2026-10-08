// NavigatorView + Hero (Phase 2a) — renders the page stack (ui/navigator.zig)
// and animates the transitions between pages.
//
//   - NavigatorView wraps every page in a transform wrapper (translate +
//     scale + alpha layer). A push/pop/replace/reset starts a tween on the
//     process-global Timeline (300 ms, M3 standard curve by default); the
//     exiting page stays in the tree until the transition completes, then
//     leaves (unless an interrupted transition kept it in the stack).
//   - While a transition runs, only the top page is interactive.
//   - Hero: a shared element tagged in both pages. On a transition, the
//     entering page's hero child is reparented into a flight wrapper that
//     animates it from the source rect to the destination rect; the hero
//     wrapper keeps the destination size (placeholder — no layout jump).
//     The source hero is hidden while the element flies.
//   - Back: the view registers the input router's back handler (Android
//     hardware button / desktop Escape) and also answers Escape/back in its
//     on_key (focused-chain delivery).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const anim = @import("../ui/anim.zig");
const nav_mod = @import("../ui/navigator.zig");
const input_mod = @import("../ui/input.zig");
const golden = @import("../golden.zig");
const layout_w = @import("layout.zig");
const container_w = @import("container.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;

const Transition = nav_mod.Transition;

fn stateOf(comptime T: type, n: *Node) *T {
    return @ptrCast(@alignCast(n.state.?));
}

fn noopPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}

// --- Page wrapper (the per-page transform: translate + scale + alpha) ---

const PageState = struct {
    node: *Node,
    page_id: u32,
    transition: Transition,
    dx: f32 = 0,
    dy: f32 = 0,
    scale: f32 = 1, // uniform, around the bounds' center
    alpha: f32 = 1,
    hit_enabled: bool = true,
};

fn pageStateOf(n: *Node) *PageState {
    return stateOf(PageState, n);
}

/// The page's visual rect (bounds under translate + center-scale).
fn pageVisualRect(s: *const PageState) Rect {
    const b = s.node.bounds;
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    return .{
        .x = cx + (b.x + s.dx - cx) * s.scale,
        .y = cy + (b.y + s.dy - cy) * s.scale,
        .w = b.w * s.scale,
        .h = b.h * s.scale,
    };
}

/// Set the transform; the damage covers the swept region (old ∪ new).
fn pageSetTransform(s: *PageState, dx: f32, dy: f32, scale: f32, alpha: f32) void {
    const old = pageVisualRect(s);
    s.dx = dx;
    s.dy = dy;
    s.scale = scale;
    s.alpha = alpha;
    const new = pageVisualRect(s);
    s.node.markDirtyRect(ui.node.rectUnion(old, new));
}

fn pageMeasure(n: *Node, c: Constraints) Size {
    var size = Size{};
    if (n.children.items.len > 0) size = n.children.items[0].measure(c);
    return c.constrain(size);
}
fn pageLayout(n: *Node, bounds: Rect) void {
    if (n.children.items.len == 0) return;
    n.children.items[0].layout(bounds); // fill semantics
}
fn pagePrePaint(n: *Node, ctx: *kx.Ctx) void {
    const s = pageStateOf(n);
    ui.paint.save(ctx);
    ui.paint.translate(ctx, s.dx, s.dy);
    if (s.scale != 1) {
        const b = n.bounds;
        const cx = b.x + b.w / 2;
        const cy = b.y + b.h / 2;
        ui.paint.translate(ctx, cx, cy);
        ui.paint.scale(ctx, s.scale, s.scale);
        ui.paint.translate(ctx, -cx, -cy);
    }
    if (s.alpha < 1) ui.paint.layerAlpha(ctx, s.alpha);
}
fn pagePostPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = pageStateOf(n);
    // layerAlpha pushed a saveLayer (a save + a layer): pop the layer first,
    // then the wrapper's own save (canvas state stays balanced).
    if (s.alpha < 1) ui.paint.restore(ctx);
    ui.paint.restore(ctx);
}
/// The children paint transformed: the hit area follows. A disabled wrapper
/// (not the top page) is not hittable.
fn pageHitBounds(n: *Node) Rect {
    const s = pageStateOf(n);
    if (!s.hit_enabled) return .{ .w = 0, .h = 0 };
    return pageVisualRect(s);
}
fn pagePreChildrenHit(n: *Node, px: f32, py: f32) ui.node.HitPoint {
    const s = pageStateOf(n);
    const b = n.bounds;
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    return .{
        .x = cx + (px - s.dx - cx) / s.scale,
        .y = cy + (py - s.dy - cy) / s.scale,
    };
}
fn pageMapPaintRect(n: *Node, rect: Rect) Rect {
    const s = pageStateOf(n);
    const b = n.bounds;
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    return .{
        .x = cx + (rect.x + s.dx - cx) * s.scale,
        .y = cy + (rect.y + s.dy - cy) * s.scale,
        .w = rect.w * s.scale,
        .h = rect.h * s.scale,
    };
}
fn pageDeinit(n: *Node) void {
    n.allocator.destroy(pageStateOf(n));
}
const page_vtable = ui.node.VTable{
    .measure = pageMeasure,
    .layout = pageLayout,
    .paint = noopPaint,
    .deinit = pageDeinit,
    .pre_children_paint = pagePrePaint,
    .post_children_paint = pagePostPaint,
    .hit_bounds = pageHitBounds,
    .pre_children_hit = pagePreChildrenHit,
    .map_paint_rect = pageMapPaintRect,
};

fn pageWrapper(allocator: std.mem.Allocator, page: *const nav_mod.Page) !*Node {
    const node = try Node.create(allocator, &page_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(PageState);
    errdefer allocator.destroy(s);
    s.* = .{ .node = node, .page_id = page.id, .transition = page.route.transition };
    node.state = s;
    node.add(page.node);
    return node;
}

/// The page wrapper enclosing `node` (null when the node is not in a page).
fn pageWrapperOf(node: *Node) ?*Node {
    var cur = node.parent;
    while (cur) |c| : (cur = c.parent) {
        if (c.vtable == &page_vtable) return c;
    }
    return null;
}

// --- Hero (shared element) ---

pub const HeroOptions = struct {
    tag: []const u8,
};

const HeroState = struct {
    tag: []const u8, // owned
    node: *Node,
    nav: ?*NavViewState = null, // set at the first layout
    /// While the element flies: the hero keeps the destination size (the
    /// child is reparented into the flight wrapper — a placeholder avoids a
    /// layout jump in the entering page).
    flight_dst: ?Size = null,
};

fn heroStateOf(n: *Node) *HeroState {
    return stateOf(HeroState, n);
}

/// Hero — a shared element: during a transition between two pages containing
/// a hero with the same tag, the element "flies" from its source rect to its
/// destination rect (the NavigatorView drives the flight).
pub fn hero(allocator: std.mem.Allocator, opts: HeroOptions) !*Node {
    const node = try Node.create(allocator, &hero_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(HeroState);
    errdefer allocator.destroy(s);
    s.* = .{ .tag = try allocator.dupe(u8, opts.tag), .node = node };
    node.state = s;
    return node;
}

fn heroMeasure(n: *Node, c: Constraints) Size {
    const s = heroStateOf(n);
    if (s.flight_dst) |sz| return c.constrain(sz); // in flight: placeholder size
    var size = Size{};
    if (n.children.items.len > 0) size = n.children.items[0].measure(c);
    return c.constrain(size);
}
fn heroLayout(n: *Node, bounds: Rect) void {
    const s = heroStateOf(n);
    if (s.flight_dst == null and n.children.items.len > 0) n.children.items[0].layout(bounds);
    // Register with the enclosing NavigatorView (first layout) and keep the
    // rect fresh (a resize moves it).
    if (s.nav == null) s.nav = findNavState(n);
    if (s.nav) |ns| ns.registerHero(n, bounds);
}
fn heroDeinit(n: *Node) void {
    const s = heroStateOf(n);
    if (s.nav) |ns| ns.unregisterHero(n);
    n.allocator.free(s.tag);
    n.allocator.destroy(s);
}
const hero_vtable = ui.node.VTable{
    .measure = heroMeasure,
    .layout = heroLayout,
    .paint = noopPaint,
    .deinit = heroDeinit,
};

// --- Flight wrapper (the hero child's transform while it flies) ---

const FlightState = struct {
    node: *Node,
    dx: f32 = 0,
    dy: f32 = 0,
    sx: f32 = 1, // non-uniform: pivot = the bounds' top-left (bounds are
    sy: f32 = 1, // (0,0,dst.w,dst.h) during the flight)
};

fn flightStateOf(n: *Node) *FlightState {
    return stateOf(FlightState, n);
}

fn flightWrapper(allocator: std.mem.Allocator) !*Node {
    const node = try Node.create(allocator, &flight_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(FlightState);
    errdefer allocator.destroy(s);
    s.* = .{ .node = node };
    node.state = s;
    return node;
}

fn flightVisualRect(s: *const FlightState) Rect {
    const b = s.node.bounds;
    return .{ .x = b.x * s.sx + s.dx, .y = b.y * s.sy + s.dy, .w = b.w * s.sx, .h = b.h * s.sy };
}

fn flightMeasure(n: *Node, c: Constraints) Size {
    var size = Size{};
    if (n.children.items.len > 0) size = n.children.items[0].measure(c);
    return c.constrain(size);
}
fn flightLayout(n: *Node, bounds: Rect) void {
    if (n.children.items.len == 0) return;
    n.children.items[0].layout(bounds); // fill semantics
}
fn flightPrePaint(n: *Node, ctx: *kx.Ctx) void {
    const s = flightStateOf(n);
    ui.paint.save(ctx);
    ui.paint.translate(ctx, s.dx, s.dy);
    ui.paint.scale(ctx, s.sx, s.sy);
}
fn flightPostPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.restore(ctx);
}
fn flightHitBounds(n: *Node) Rect {
    return flightVisualRect(flightStateOf(n));
}
fn flightPreChildrenHit(n: *Node, px: f32, py: f32) ui.node.HitPoint {
    const s = flightStateOf(n);
    return .{ .x = (px - s.dx) / s.sx, .y = (py - s.dy) / s.sy };
}
fn flightMapPaintRect(n: *Node, rect: Rect) Rect {
    const s = flightStateOf(n);
    return .{ .x = rect.x * s.sx + s.dx, .y = rect.y * s.sy + s.dy, .w = rect.w * s.sx, .h = rect.h * s.sy };
}
fn flightDeinit(n: *Node) void {
    n.allocator.destroy(flightStateOf(n));
}
const flight_vtable = ui.node.VTable{
    .measure = flightMeasure,
    .layout = flightLayout,
    .paint = noopPaint,
    .deinit = flightDeinit,
    .pre_children_paint = flightPrePaint,
    .post_children_paint = flightPostPaint,
    .hit_bounds = flightHitBounds,
    .pre_children_hit = flightPreChildrenHit,
    .map_paint_rect = flightMapPaintRect,
};

// --- NavigatorView ---

pub const NavigatorOptions = struct {
    navigator: *nav_mod.Navigator,
    duration_ms: u32 = 300,
    curve: anim.Curve = .{ .ease = .standard }, // M3 standard
    parallax: f32 = 0.3, // the page below slides by this fraction (slide*)
};

const HeroEntry = struct {
    tag: []const u8, // owned
    hero: *Node,
    wrapper: *Node, // the page wrapper the hero lives in
    rect: Rect, // last laid-out rect (window space)
};

const HeroFlight = struct {
    hero: *Node, // the hero wrapper (stays in the entering page, placeholder)
    flight: *Node, // the flight wrapper (holds the child while it flies)
    child: *Node, // the hero's child (reparented into the flight wrapper)
    src: Rect,
    dst: Rect,
    out_hero: *Node, // the same-tag hero in the exiting page (hidden while flying)
};

const ActiveTransition = struct {
    kind: Transition,
    entering: *Node,
    exiting: ?*Node,
    reverse: bool,
    hero: ?HeroFlight = null,
};

const NavViewState = struct {
    opts: NavigatorOptions,
    node: *Node,
    nav: *nav_mod.Navigator,
    pages_ui: std.array_list.Managed(*Node), // page wrappers, same order as nav.pages
    heroes: std.array_list.Managed(HeroEntry),
    transition: ?ActiveTransition = null,
    channel: u8 = 0, // timeline channel: one transition at a time

    fn registerHero(s: *NavViewState, h: *Node, rect: Rect) void {
        const wrapper = pageWrapperOf(h) orelse return; // a hero outside a page never flies
        for (s.heroes.items) |*e| {
            if (e.hero == h) {
                e.rect = rect;
                return;
            }
        }
        s.heroes.append(.{
            .tag = s.node.allocator.dupe(u8, heroStateOf(h).tag) catch @panic("klaxon: out of memory"),
            .hero = h,
            .wrapper = wrapper,
            .rect = rect,
        }) catch @panic("klaxon: out of memory");
    }

    fn unregisterHero(s: *NavViewState, h: *Node) void {
        var i: usize = 0;
        while (i < s.heroes.items.len) {
            if (s.heroes.items[i].hero == h) {
                s.node.allocator.free(s.heroes.items[i].tag);
                _ = s.heroes.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// While a transition runs, only the top page is interactive — and
    /// keyboard focus follows the top page (a focused node in a page that is
    /// not on top loses focus).
    fn refreshHit(s: *NavViewState) void {
        for (s.pages_ui.items, 0..) |w, i| {
            pageStateOf(w).hit_enabled = (i == s.pages_ui.items.len - 1);
        }
        if (s.transition) |t| {
            if (t.exiting) |ex| pageStateOf(ex).hit_enabled = false;
        }
        if (input_mod.current()) |r| {
            if (r.focused) |f| {
                const top: ?*Node = if (s.pages_ui.items.len > 0)
                    s.pages_ui.items[s.pages_ui.items.len - 1]
                else
                    null;
                if (top == null or pageWrapperOf(f) != top) r.focus(null);
            }
        }
    }

    fn startTransition(s: *NavViewState, kind: Transition, entering: *Node, exiting: ?*Node, reverse: bool) void {
        // A transition is already running: finish it instantly (the new one
        // supersedes it — interrupted push/pop chains stay consistent).
        if (s.transition != null) s.finishTransition();
        if (kind == .none or exiting == null) {
            if (exiting) |ex| {
                if (!s.nav.containsPage(pageStateOf(ex).page_id)) {
                    _ = s.node.remove(ex);
                    ex.deinit();
                }
            }
            s.refreshHit();
            s.node.markDirty();
            return;
        }
        s.transition = .{ .kind = kind, .entering = entering, .exiting = exiting, .reverse = reverse };
        if (s.beginHeroFlight(entering, exiting.?)) |flight| {
            if (s.transition) |*t| t.hero = flight;
        }
        s.refreshHit();
        applyTransition(s, 0); // the first frame of the transition is already correct
        const tl = anim.timeline() orelse {
            applyTransition(s, 1); // no timeline (unit tests): snap
            s.finishTransition();
            return;
        };
        _ = tl.play(.{
            .kind = anim.Animation.tweenAnim(.{ 1, 0, 0, 0 }, s.opts.duration_ms, s.opts.curve),
            .from = .{ 0, 0, 0, 0 },
            .channel = @ptrCast(&s.channel),
            .on_update = .{ .fn_ptr = transitionUpdate, .userdata = s },
            .on_complete = .{ .fn_ptr = transitionComplete, .userdata = s },
        });
    }

    fn finishTransition(s: *NavViewState) void {
        const t = s.transition orelse return;
        // Hero: the flying child returns to its hero wrapper (at the destination).
        if (t.hero) |f| {
            _ = s.node.remove(f.flight);
            _ = f.flight.remove(f.child); // Node.add does not detach the old parent
            f.hero.add(f.child); // Hero is single-child: back at index 0
            heroStateOf(f.hero).flight_dst = null;
            f.flight.deinit(); // empty: the child was reparented
            f.out_hero.visible = true; // the source page may stay in the stack
        }
        // The exiting page leaves the tree — unless it is still in the stack
        // (an interrupted transition snaps it back into place). pages_ui is
        // kept in sync: a retired wrapper is removed from it too.
        if (t.exiting) |ex| {
            if (!s.nav.containsPage(pageStateOf(ex).page_id)) {
                for (s.pages_ui.items, 0..) |w, i| {
                    if (w == ex) {
                        _ = s.pages_ui.orderedRemove(i);
                        break;
                    }
                }
                _ = s.node.remove(ex);
                ex.deinit();
            } else {
                pageSetTransform(pageStateOf(ex), 0, 0, 1, 1);
            }
        }
        s.transition = null;
        s.refreshHit();
        s.node.markDirty();
    }

    /// Look for a hero shared by the two pages (same tag): the entering
    /// page's hero child is reparented into a flight wrapper (topmost).
    fn beginHeroFlight(s: *NavViewState, entering: *Node, exiting: *Node) ?HeroFlight {
        for (s.heroes.items) |out| {
            if (out.wrapper != exiting) continue;
            for (s.heroes.items) |in| {
                if (in.hero == out.hero) continue;
                if (in.wrapper != entering) continue;
                if (!std.mem.eql(u8, out.tag, in.tag)) continue;
                const src = out.rect;
                const dst = in.rect;
                if (src.w <= 0 or src.h <= 0 or dst.w <= 0 or dst.h <= 0) return null;
                const h = in.hero;
                if (h.children.items.len == 0) return null;
                const child = h.children.items[0];
                heroStateOf(h).flight_dst = .{ .w = dst.w, .h = dst.h };
                _ = h.remove(child); // the hero keeps the destination size (placeholder)
                const f = flightWrapper(s.node.allocator) catch @panic("klaxon: out of memory");
                f.add(child);
                s.node.add(f); // topmost: paints above both pages
                child.layout(.{ .x = 0, .y = 0, .w = dst.w, .h = dst.h });
                f.layout(.{ .x = 0, .y = 0, .w = dst.w, .h = dst.h });
                out.hero.visible = false; // the source hero leaves its page
                return .{ .hero = h, .flight = f, .child = child, .src = src, .dst = dst, .out_hero = out.hero };
            }
        }
        return null;
    }
};

/// Apply the transition at progression p ∈ [0,1] (p follows the tween).
fn applyTransition(s: *NavViewState, p: f32) void {
    const t = s.transition orelse return;
    const w = s.node.bounds.w;
    const h = s.node.bounds.h;
    const es = pageStateOf(t.entering);
    const xs: ?*PageState = if (t.exiting) |ex| pageStateOf(ex) else null;
    switch (t.kind) {
        .none => {},
        .slide => {
            if (t.reverse) {
                // pop: the page below comes back from the parallax offset
                pageSetTransform(es, -s.opts.parallax * w * (1 - p), 0, 1, 1);
                if (xs) |x| pageSetTransform(x, w * p, 0, 1, 1);
            } else {
                pageSetTransform(es, w * (1 - p), 0, 1, 1);
                if (xs) |x| pageSetTransform(x, -s.opts.parallax * w * p, 0, 1, 1);
            }
        },
        .slide_up => {
            if (t.reverse) {
                pageSetTransform(es, 0, -s.opts.parallax * h * (1 - p), 1, 1);
                if (xs) |x| pageSetTransform(x, 0, h * p, 1, 1);
            } else {
                pageSetTransform(es, 0, h * (1 - p), 1, 1);
                if (xs) |x| pageSetTransform(x, 0, -s.opts.parallax * h * p, 1, 1);
            }
        },
        .fade => {
            if (t.reverse) {
                pageSetTransform(es, 0, 0, 1, 1);
                if (xs) |x| pageSetTransform(x, 0, 0, 1, 1 - p);
            } else {
                pageSetTransform(es, 0, 0, 1, p);
                if (xs) |x| pageSetTransform(x, 0, 0, 1, 1);
            }
        },
        .scale => {
            if (t.reverse) {
                pageSetTransform(es, 0, 0, 1, 1);
                if (xs) |x| pageSetTransform(x, 0, 0, 1 - 0.08 * p, 1 - p);
            } else {
                pageSetTransform(es, 0, 0, 0.92 + 0.08 * p, p);
                if (xs) |x| pageSetTransform(x, 0, 0, 1, 1);
            }
        },
    }
    if (t.hero) |*f| applyHeroFlight(f, p);
}

fn applyHeroFlight(f: *const HeroFlight, p: f32) void {
    const fs = flightStateOf(f.flight);
    const old = flightVisualRect(fs);
    fs.dx = f.src.x + (f.dst.x - f.src.x) * p;
    fs.dy = f.src.y + (f.dst.y - f.src.y) * p;
    fs.sx = (f.src.w / f.dst.w) + (1 - f.src.w / f.dst.w) * p;
    fs.sy = (f.src.h / f.dst.h) + (1 - f.src.h / f.dst.h) * p;
    const new = flightVisualRect(fs);
    f.flight.markDirtyRect(ui.node.rectUnion(old, new));
}

fn transitionUpdate(userdata: ?*anyopaque, v: anim.Vec4) void {
    const s: *NavViewState = @ptrCast(@alignCast(userdata.?));
    applyTransition(s, v[0]);
}

fn transitionComplete(userdata: ?*anyopaque) void {
    const s: *NavViewState = @ptrCast(@alignCast(userdata.?));
    s.finishTransition();
}

/// The Navigator mutated: sync the tree (wrappers) and start the transition.
fn onChange(userdata: ?*anyopaque, kind: nav_mod.ChangeKind) void {
    const s: *NavViewState = @ptrCast(@alignCast(userdata.?));
    switch (kind) {
        .push => {
            const page = s.nav.current().?;
            const w = pageWrapper(s.node.allocator, page) catch @panic("klaxon: out of memory");
            s.node.add(w);
            s.pages_ui.append(w) catch @panic("klaxon: out of memory");
            // Lay the new page out now: its heroes register before the
            // transition starts (a hero flight needs both rects).
            w.layout(s.node.bounds);
            const exiting: ?*Node = if (s.pages_ui.items.len >= 2)
                s.pages_ui.items[s.pages_ui.items.len - 2]
            else
                null;
            s.startTransition(page.route.transition, w, exiting, false);
        },
        .pop => {
            const exiting = s.pages_ui.pop().?; // stays in the tree until the transition completes
            const entering = s.pages_ui.items[s.pages_ui.items.len - 1];
            s.startTransition(pageStateOf(exiting).transition, entering, exiting, true);
        },
        .replace => {
            const exiting = s.pages_ui.items[s.pages_ui.items.len - 1];
            const page = s.nav.current().?;
            const w = pageWrapper(s.node.allocator, page) catch @panic("klaxon: out of memory");
            // The new wrapper goes on top; the exiting wrapper STAYS in the
            // tree (painted below) until the transition completes.
            s.node.add(w);
            s.pages_ui.items[s.pages_ui.items.len - 1] = w;
            w.layout(s.node.bounds);
            s.startTransition(page.route.transition, w, exiting, false);
        },
        .reset => {
            // End any in-flight transition FIRST: it owns the exiting wrapper
            // (finishTransition retires it — and syncs pages_ui — when its
            // page left the stack).
            if (s.transition != null) s.finishTransition();
            const root_w = s.pages_ui.items[0];
            const top_w = s.pages_ui.items[s.pages_ui.items.len - 1];
            // The middle pages (between the root and the top) leave
            // immediately; the old top animates out.
            while (s.pages_ui.items.len > 2) {
                const mid = s.pages_ui.items[1];
                _ = s.pages_ui.orderedRemove(1);
                _ = s.node.remove(mid);
                mid.deinit();
            }
            _ = s.pages_ui.pop(); // the old top: no longer in pages_ui (stays in the tree)
            s.pages_ui.clearRetainingCapacity();
            s.pages_ui.append(root_w) catch @panic("klaxon: out of memory");
            s.startTransition(pageStateOf(top_w).transition, root_w, top_w, true);
        },
    }
}

fn backHandler(userdata: ?*anyopaque) bool {
    const s: *NavViewState = @ptrCast(@alignCast(userdata.?));
    return s.nav.onBack();
}

fn findNavState(n: *Node) ?*NavViewState {
    var cur = n.parent;
    while (cur) |c| : (cur = c.parent) {
        if (c.vtable == &navigator_vtable) return stateOf(NavViewState, c);
    }
    return null;
}

// --- NavigatorView vtable ---

fn navMeasure(n: *Node, c: Constraints) Size {
    var size = Size{};
    for (n.children.items) |child| {
        const cs = child.measure(c);
        size.w = @max(size.w, cs.w);
        size.h = @max(size.h, cs.h);
    }
    return c.constrain(size);
}

fn navLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(NavViewState, n);
    for (n.children.items) |child| {
        // A hero in flight is laid out at the nav node's top-left at its
        // destination size; its transform animates position + scale.
        if (s.transition) |t| {
            if (t.hero) |f| {
                if (child == f.flight) {
                    child.layout(.{ .x = 0, .y = 0, .w = f.dst.w, .h = f.dst.h });
                    continue;
                }
            }
        }
        child.layout(bounds);
    }
}

/// Escape / back pop (focused-chain delivery; the router's back handler is
/// the primary path — this covers a focused node inside the current page).
fn navOnKey(n: *Node, ev: input_mod.KeyEvent) bool {
    if (ev.kind != .key_down) return false;
    if (ev.key != .escape and ev.key != .back) return false;
    const s = stateOf(NavViewState, n);
    return s.nav.onBack();
}

fn navDeinit(n: *Node) void {
    const s = stateOf(NavViewState, n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.channel));
    if (input_mod.current()) |r| {
        if (r.back_handler) |bh| {
            if (bh.userdata == @as(?*anyopaque, @ptrCast(s))) r.setBackHandler(null);
        }
    }
    s.nav.setOnChange(null);
    for (s.heroes.items) |h| n.allocator.free(h.tag);
    s.heroes.deinit();
    s.pages_ui.deinit();
    n.allocator.destroy(s);
}
const navigator_vtable = ui.node.VTable{
    .measure = navMeasure,
    .layout = navLayout,
    .paint = noopPaint,
    .on_key = navOnKey,
    .deinit = navDeinit,
};

/// NavigatorView — renders the page stack. The Navigator itself is owned by
/// the app (like a Signal); the view subscribes to its changes.
pub fn navigatorView(allocator: std.mem.Allocator, opts: NavigatorOptions) !*Node {
    const node = try Node.create(allocator, &navigator_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(NavViewState);
    errdefer allocator.destroy(s);
    s.* = .{
        .opts = opts,
        .node = node,
        .nav = opts.navigator,
        .pages_ui = std.array_list.Managed(*Node).init(allocator),
        .heroes = std.array_list.Managed(HeroEntry).init(allocator),
    };
    node.state = s;
    // The initial stack (cold start / deep link before the first frame):
    // wrap every page, no transition.
    for (opts.navigator.pages.items) |*page| {
        const w = try pageWrapper(allocator, page);
        node.add(w);
        try s.pages_ui.append(w);
    }
    s.refreshHit();
    opts.navigator.setOnChange(.{ .fn_ptr = onChange, .userdata = s });
    if (input_mod.current()) |r| r.setBackHandler(.{ .fn_ptr = backHandler, .userdata = s });
    return node;
}

// --- tests ---

fn testTimeline() anim.Timeline {
    return anim.Timeline.init(std.testing.allocator);
}

/// A page builder: a solid box of a fixed color (the tree owns the node).
const BuilderCtx = struct {
    color: Color,
    last: ?*Node = null,
};

fn colorBuilder(userdata: ?*anyopaque, route: nav_mod.Route) *Node {
    _ = route;
    const ctx: *BuilderCtx = @ptrCast(@alignCast(userdata.?));
    const n = golden.solidBox(std.testing.allocator, 100, 100, ctx.color) catch @panic("klaxon: out of memory");
    ctx.last = n;
    return n;
}

fn defineColor(nav: *nav_mod.Navigator, pattern: []const u8, ctx: *BuilderCtx, transition: Transition) !void {
    try nav.define(pattern, .{ .fn_ptr = colorBuilder, .userdata = ctx }, transition);
}

const red: Color = 0xFF0000FF;
const blue: Color = 0x0000FFFF;
const green: Color = 0x00FF00FF;

test "push animates the entering page in; the page below parallaxes" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .slide);
    try nav.push("a", &.{});
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100, .curve = .{ .ease = .linear } });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try std.testing.expectEqual(@as(usize, 1), view.children.items.len);

    try nav.push("b", &.{});
    const s = stateOf(NavViewState, view);
    try std.testing.expectEqual(@as(usize, 2), s.pages_ui.items.len);
    try std.testing.expect(s.transition != null);
    const entering = s.pages_ui.items[1];
    const exiting = s.pages_ui.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 200), pageStateOf(entering).dx, 0.01); // p=0 applied
    try std.testing.expectApproxEqAbs(@as(f32, 0), pageStateOf(exiting).dx, 0.01);
    tl.tick(0); // lazy start
    tl.tick(50); // halfway (linear)
    try std.testing.expectApproxEqAbs(@as(f32, 100), pageStateOf(entering).dx, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -30), pageStateOf(exiting).dx, 0.01); // parallax 0.3*200*0.5
    // only the top page is interactive while the transition runs
    try std.testing.expect(!pageStateOf(exiting).hit_enabled);
    try std.testing.expect(pageStateOf(entering).hit_enabled);
    tl.tick(100); // completes
    try std.testing.expect(s.transition == null);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pageStateOf(entering).dx, 0.01);
    // the page below stays in the tree (still in the stack)
    try std.testing.expectEqual(@as(usize, 2), view.children.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pageStateOf(exiting).dx, 0.01);
}

test "pop animates in reverse; the popped page leaves the tree" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .slide);
    try nav.push("a", &.{});
    try nav.push("b", &.{});
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100, .curve = .{ .ease = .linear } });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });

    try std.testing.expect(nav.pop());
    const s = stateOf(NavViewState, view);
    try std.testing.expectEqual(@as(usize, 1), s.pages_ui.items.len);
    try std.testing.expect(s.transition != null);
    const entering = s.pages_ui.items[0]; // page a
    const exiting = view.children.items[1]; // page b (still in the tree)
    tl.tick(0);
    tl.tick(50); // halfway
    try std.testing.expectApproxEqAbs(@as(f32, 100), pageStateOf(exiting).dx, 0.01); // b slides out right
    try std.testing.expectApproxEqAbs(@as(f32, -30), pageStateOf(entering).dx, 0.01); // a back from parallax
    tl.tick(100); // completes
    try std.testing.expect(s.transition == null);
    try std.testing.expectEqual(@as(usize, 1), view.children.items.len); // b removed
    try std.testing.expectApproxEqAbs(@as(f32, 0), pageStateOf(entering).dx, 0.01);
}

test "replace swaps the top page (same depth)" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    var ctx_c = BuilderCtx{ .color = green };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .slide);
    try defineColor(&nav, "c", &ctx_c, .slide);
    try nav.push("a", &.{});
    try nav.push("b", &.{});
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100, .curve = .{ .ease = .linear } });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });

    try nav.replace("c", &.{});
    const s = stateOf(NavViewState, view);
    try std.testing.expectEqual(@as(usize, 2), s.pages_ui.items.len);
    try std.testing.expect(s.transition != null);
    try std.testing.expectEqualStrings("c", nav.current().?.route.path);
    tl.tick(0);
    tl.tick(100); // completes
    try std.testing.expect(s.transition == null);
    try std.testing.expectEqual(@as(usize, 2), view.children.items.len); // a + c (b removed)
    try std.testing.expectEqual(ctx_c.last.?, s.pages_ui.items[1].children.items[0]);
}

test "popToRoot removes the middle pages immediately, animates top → root" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    var ctx_c = BuilderCtx{ .color = green };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .slide);
    try defineColor(&nav, "c", &ctx_c, .slide);
    try nav.push("a", &.{});
    try nav.push("b", &.{});
    try nav.push("c", &.{});
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100, .curve = .{ .ease = .linear } });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });

    nav.popToRoot();
    const s = stateOf(NavViewState, view);
    try std.testing.expectEqual(@as(usize, 1), nav.depth());
    try std.testing.expectEqual(@as(usize, 1), s.pages_ui.items.len);
    try std.testing.expectEqual(@as(usize, 2), view.children.items.len); // root + old top (animating out)
    try std.testing.expect(s.transition != null);
    tl.tick(0);
    tl.tick(50);
    const root_w = s.pages_ui.items[0];
    const top_w = view.children.items[1];
    try std.testing.expectApproxEqAbs(@as(f32, 100), pageStateOf(top_w).dx, 0.01); // top slides out
    try std.testing.expectApproxEqAbs(@as(f32, -30), pageStateOf(root_w).dx, 0.01); // root back from parallax
    tl.tick(100);
    try std.testing.expect(s.transition == null);
    try std.testing.expectEqual(@as(usize, 1), view.children.items.len);
}

test "a push during a transition finishes the previous one first" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    var ctx_c = BuilderCtx{ .color = green };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .slide);
    try defineColor(&nav, "c", &ctx_c, .slide);
    try nav.push("a", &.{});
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100, .curve = .{ .ease = .linear } });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });

    try nav.push("b", &.{});
    tl.tick(0);
    tl.tick(50); // mid-transition
    try nav.push("c", &.{}); // interrupts
    const s = stateOf(NavViewState, view);
    // the interrupted transition snapped back: every page is in place
    try std.testing.expectEqual(@as(usize, 3), s.pages_ui.items.len);
    try std.testing.expectEqual(@as(usize, 3), view.children.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pageStateOf(s.pages_ui.items[0]).dx, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pageStateOf(s.pages_ui.items[1]).dx, 0.01);
    // the new transition runs (c in, b parallax)
    try std.testing.expect(s.transition != null);
    tl.tick(50); // the new tween starts here (lazy)
    tl.tick(100); // halfway
    try std.testing.expectApproxEqAbs(@as(f32, 100), pageStateOf(s.pages_ui.items[2]).dx, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -30), pageStateOf(s.pages_ui.items[1]).dx, 0.01);
    tl.tick(150); // completes
    try std.testing.expect(s.transition == null);
    try std.testing.expectEqual(@as(usize, 3), view.children.items.len);
}

test "transition none retires the exiting page only when it left the stack" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .none);
    try nav.push("a", &.{});
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100 });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try nav.push("b", &.{});
    const s = stateOf(NavViewState, view);
    try std.testing.expect(s.transition == null); // instant
    try std.testing.expectEqual(@as(usize, 2), view.children.items.len); // a stays (in the stack)
    try std.testing.expectApproxEqAbs(@as(f32, 0), pageStateOf(s.pages_ui.items[1]).dx, 0.01);
    // a pop with transition none: the popped page leaves immediately
    try std.testing.expect(nav.pop());
    try std.testing.expectEqual(@as(usize, 1), view.children.items.len);
    try std.testing.expect(s.transition == null);
}

test "cold start (deep link before the view): no transition" {
    anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .slide);
    try nav.navigateTo("klaxon://b");
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    const s = stateOf(NavViewState, view);
    try std.testing.expectEqual(@as(usize, 1), view.children.items.len);
    try std.testing.expectEqual(@as(usize, 1), s.pages_ui.items.len);
    try std.testing.expect(s.transition == null);
    try std.testing.expect(pageStateOf(s.pages_ui.items[0]).hit_enabled);
}

test "back handler pops via the input router (Android back / Escape)" {
    anim.setCurrent(null); // snap transitions
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .slide);
    try nav.push("a", &.{});
    try nav.push("b", &.{});
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav });
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try std.testing.expectEqual(@as(usize, 2), view.children.items.len);
    try std.testing.expect(router.dispatchBack()); // pops b
    try std.testing.expectEqual(@as(usize, 1), nav.depth());
    try std.testing.expectEqual(@as(usize, 1), view.children.items.len);
    try std.testing.expect(!router.dispatchBack()); // at the root
    view.deinit(); // unregisters the back handler (no defer: deinited here)
    try std.testing.expect(!router.dispatchBack());
}

test "escape/back key pops the stack (on_key, focused chain)" {
    anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .slide);
    try nav.push("a", &.{});
    try nav.push("b", &.{});
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav });
    defer view.deinit();
    const on_key = view.vtable.on_key.?;
    try std.testing.expect(on_key(view, .{ .kind = .key_down, .key = .escape })); // pops b
    try std.testing.expectEqual(@as(usize, 1), nav.depth());
    try std.testing.expect(!on_key(view, .{ .kind = .key_down, .key = .back })); // at the root: refused
    try std.testing.expectEqual(@as(usize, 1), nav.depth()); // the stack never empties
    try std.testing.expect(!on_key(view, .{ .kind = .key_down, .key = .enter })); // other keys pass through
    try std.testing.expect(!on_key(view, .{ .kind = .text_input, .key = .escape, .text = "x" }));
}

test "during a transition only the entering page is interactive" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .slide);
    try nav.push("a", &.{});
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100, .curve = .{ .ease = .linear } });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try nav.push("b", &.{});
    tl.tick(0);
    tl.tick(50); // mid-transition: entering at dx=100, exiting at dx=-30
    // the exiting page's visible zone (left) is not hittable
    const hit_left = view.hitTest(50, 50);
    try std.testing.expect(hit_left != null);
    try std.testing.expect(hit_left.? != ctx_a.last.?);
    // the entering page's zone (right) hits the entering page
    try std.testing.expectEqual(ctx_b.last.?, view.hitTest(150, 50).?);
}

test "popToRoot during a push finishes the transition before removing pages" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    var ctx_c = BuilderCtx{ .color = green };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .slide);
    try defineColor(&nav, "c", &ctx_c, .slide);
    try nav.push("a", &.{});
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100, .curve = .{ .ease = .linear } });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try nav.push("b", &.{});
    tl.tick(0);
    tl.tick(100); // b in place
    try nav.push("c", &.{});
    tl.tick(100); // c's tween starts here (lazy)
    tl.tick(150); // mid-transition (exiting = b)
    nav.popToRoot(); // interrupts: finishTransition retires b (its page left the stack)
    const s = stateOf(NavViewState, view);
    try std.testing.expectEqual(@as(usize, 1), nav.depth());
    try std.testing.expectEqual(@as(usize, 1), s.pages_ui.items.len);
    try std.testing.expectEqual(@as(usize, 2), view.children.items.len); // a + c (b retired)
    try std.testing.expect(s.transition != null); // c animates out
    tl.tick(200); // the reset tween starts here (lazy)
    tl.tick(250);
    tl.tick(300); // completes
    try std.testing.expect(s.transition == null);
    try std.testing.expectEqual(@as(usize, 1), view.children.items.len);
}

test "replace keeps the outgoing page in the tree until the transition completes" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    var ctx_c = BuilderCtx{ .color = green };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .slide);
    try defineColor(&nav, "c", &ctx_c, .slide);
    try nav.push("a", &.{});
    try nav.push("b", &.{});
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100, .curve = .{ .ease = .linear } });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });

    try nav.replace("c", &.{});
    try std.testing.expectEqual(@as(usize, 3), view.children.items.len); // a + b (exiting) + c
    tl.tick(0);
    tl.tick(50);
    try std.testing.expectEqual(@as(usize, 3), view.children.items.len); // b still painted mid-transition
    tl.tick(100); // completes
    try std.testing.expectEqual(@as(usize, 2), view.children.items.len); // b retired
}

test "transition damage covers the swept region (window space, no double transform)" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .slide);
    try nav.push("a", &.{});
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100, .curve = .{ .ease = .linear } });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try nav.push("b", &.{});
    view.clearDamage();
    tl.tick(0);
    tl.tick(50); // entering dx=100, exiting dx=-30
    try std.testing.expect(view.damage_valid);
    // The swept region of both pages, in window space: x from -30 (exiting)
    // to 400 (entering's right edge). markDirtyRect takes the rect in the
    // node's PARENT space — damageRectUp applies the ANCESTORS' maps only,
    // so the wrapper's own transform is not applied twice.
    try std.testing.expectApproxEqAbs(@as(f32, -30), view.damage.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 430), view.damage.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), view.damage.h, 0.01);
}

test "push clears keyboard focus from the page below" {
    anim.setCurrent(null); // snap transitions
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .slide);
    try nav.push("a", &.{});
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    router.focus(ctx_a.last.?);
    try std.testing.expect(router.focused != null);
    try nav.push("b", &.{});
    try std.testing.expect(router.focused == null); // the page below is not interactive
    // focus inside the top page is kept
    router.focus(ctx_b.last.?);
    try std.testing.expect(router.focused != null);
}

test "hero: the source hero is visible again after the flight" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = HeroPageCtx{ .bg = red, .hero_w = 40, .hero_h = 40 };
    var ctx_b = HeroPageCtx{ .bg = blue, .hero_w = 120, .hero_h = 120 };
    try nav.define("a", .{ .fn_ptr = heroPageBuilder, .userdata = &ctx_a }, .slide);
    try nav.define("b", .{ .fn_ptr = heroPageBuilder, .userdata = &ctx_b }, .slide);
    try nav.push("a", &.{});
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100, .curve = .{ .ease = .linear } });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    try nav.push("b", &.{}); // flight: hero A hidden
    try std.testing.expect(!ctx_a.hero_node.?.visible);
    tl.tick(0);
    tl.tick(100); // completes
    try std.testing.expect(ctx_a.hero_node.?.visible); // restored (page A stays in the stack)
    try std.testing.expect(nav.pop()); // back to A (a hero flight runs b → a)
    tl.tick(100); // lazy start
    tl.tick(200); // completes
    try std.testing.expect(ctx_a.hero_node.?.visible); // the top page's hero, visible
}

// --- hero tests ---

const HeroPageCtx = struct {
    bg: Color,
    hero_w: f32,
    hero_h: f32,
    hero_node: ?*Node = null,
};

fn heroPageBuilder(userdata: ?*anyopaque, route: nav_mod.Route) *Node {
    _ = route;
    const ctx: *HeroPageCtx = @ptrCast(@alignCast(userdata.?));
    const a = std.testing.allocator;
    const h = hero(a, .{ .tag = "cover" }) catch @panic("klaxon: out of memory");
    ctx.hero_node = h;
    h.add(golden.solidBox(a, ctx.hero_w, ctx.hero_h, green) catch @panic("klaxon: out of memory"));
    const c = layout_w.center(a) catch @panic("klaxon: out of memory");
    c.add(h);
    const p = layout_w.padding(a, ui.layout.EdgeInsets.all(20)) catch @panic("klaxon: out of memory");
    p.add(c);
    const box = container_w.container(a, .{ .color = ctx.bg }) catch @panic("klaxon: out of memory");
    box.add(p);
    return box;
}

test "hero flight: the shared element flies source → destination" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = HeroPageCtx{ .bg = red, .hero_w = 40, .hero_h = 40 };
    var ctx_b = HeroPageCtx{ .bg = blue, .hero_w = 120, .hero_h = 120 };
    try nav.define("a", .{ .fn_ptr = heroPageBuilder, .userdata = &ctx_a }, .slide);
    try nav.define("b", .{ .fn_ptr = heroPageBuilder, .userdata = &ctx_b }, .slide);
    try nav.push("a", &.{});
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100, .curve = .{ .ease = .linear } });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    const s = stateOf(NavViewState, view);
    // hero rects: A centered in (20,20,160,160) → (80,80,40,40); B → (40,40,120,120)
    try std.testing.expectEqual(@as(usize, 1), s.heroes.items.len);
    try std.testing.expectEqual(@as(f32, 80), s.heroes.items[0].rect.x);

    try nav.push("b", &.{});
    try std.testing.expect(s.transition != null);
    const flight = s.transition.?.hero.?;
    // the source hero is hidden; the flight wrapper is topmost
    try std.testing.expect(!ctx_a.hero_node.?.visible);
    try std.testing.expectEqual(view, flight.flight.parent.?);
    try std.testing.expectEqual(@as(usize, 3), view.children.items.len); // 2 pages + flight
    // the hero wrapper keeps the destination size (placeholder: no layout jump)
    try std.testing.expect(heroStateOf(ctx_b.hero_node.?).flight_dst != null);
    tl.tick(0);
    tl.tick(50); // halfway
    const fs = flightStateOf(flight.flight);
    try std.testing.expectApproxEqAbs(@as(f32, 60), fs.dx, 0.01); // lerp(80, 40, 0.5)
    try std.testing.expectApproxEqAbs(@as(f32, 60), fs.dy, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 80), flight.flight.bounds.w * fs.sx, 0.01); // lerp(40, 120)
    tl.tick(100); // completes
    try std.testing.expect(s.transition == null);
    try std.testing.expectEqual(@as(usize, 2), view.children.items.len); // flight removed
    // the child is back in the hero wrapper; the placeholder is cleared
    try std.testing.expectEqual(ctx_b.hero_node.?, flight.child.parent.?);
    try std.testing.expect(heroStateOf(ctx_b.hero_node.?).flight_dst == null);
}

test "golden: slide transition — entering covers from the right, the page below parallaxes" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .slide);
    try nav.push("a", &.{});
    var r = try golden.Renderer.init(std.testing.allocator, 200, 100);
    defer r.deinit();
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100, .curve = .{ .ease = .linear } });
    defer view.deinit(); // LIFO: the tree dies before the renderer's ctx
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });

    try nav.push("b", &.{});
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    tl.tick(0);
    tl.tick(50); // halfway: entering dx=100, exiting dx=-30
    r.paint(view, 0x000000FF);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    try std.testing.expectEqual(blue, f1.pixelAt(150, 50)); // entering covers the right half
    try std.testing.expectEqual(red, f1.pixelAt(50, 50)); // the page below (parallaxed left)
    tl.tick(100); // completes
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    r.paint(view, 0x000000FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(blue, f2.pixelAt(50, 50)); // the entering page covers everything
}

test "golden: fade transition cross-fades the two pages" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = BuilderCtx{ .color = red };
    var ctx_b = BuilderCtx{ .color = blue };
    try defineColor(&nav, "a", &ctx_a, .none);
    try defineColor(&nav, "b", &ctx_b, .fade);
    try nav.push("a", &.{});
    var r = try golden.Renderer.init(std.testing.allocator, 200, 100);
    defer r.deinit();
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100, .curve = .{ .ease = .linear } });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });

    try nav.push("b", &.{});
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    tl.tick(0);
    tl.tick(50); // halfway: entering alpha = 0.5
    r.paint(view, 0x000000FF);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    const px = f1.pixelAt(50, 50);
    const pr: i32 = @intCast((px >> 24) & 0xFF);
    const pg: i32 = @intCast((px >> 16) & 0xFF);
    const pb: i32 = @intCast((px >> 8) & 0xFF);
    try std.testing.expect(@abs(pr - 127) <= 2); // 50% red
    try std.testing.expect(@abs(pg - 0) <= 2);
    try std.testing.expect(@abs(pb - 127) <= 2); // 50% blue
    tl.tick(100);
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    r.paint(view, 0x000000FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(blue, f2.pixelAt(50, 50));
}

test "golden: hero flies from the source rect to the destination rect" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var nav = nav_mod.Navigator.init(std.testing.allocator);
    defer nav.deinit();
    var ctx_a = HeroPageCtx{ .bg = red, .hero_w = 40, .hero_h = 40 };
    var ctx_b = HeroPageCtx{ .bg = blue, .hero_w = 120, .hero_h = 120 };
    try nav.define("a", .{ .fn_ptr = heroPageBuilder, .userdata = &ctx_a }, .slide);
    try nav.define("b", .{ .fn_ptr = heroPageBuilder, .userdata = &ctx_b }, .slide);
    try nav.push("a", &.{});
    var r = try golden.Renderer.init(std.testing.allocator, 200, 200);
    defer r.deinit();
    const view = try navigatorView(std.testing.allocator, .{ .navigator = &nav, .duration_ms = 100, .curve = .{ .ease = .linear } });
    defer view.deinit();
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    r.paint(view, 0x000000FF);
    var f0 = try r.readback(std.testing.allocator);
    defer f0.deinit();
    try std.testing.expectEqual(green, f0.pixelAt(90, 90)); // hero A at (80,80,40,40)
    try std.testing.expectEqual(red, f0.pixelAt(10, 10));

    try nav.push("b", &.{});
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    tl.tick(0);
    tl.tick(50); // halfway: flight at (60,60,80,80); B slides in (dx=100); A parallaxed
    r.paint(view, 0x000000FF);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    try std.testing.expectEqual(green, f1.pixelAt(70, 70)); // the flying hero
    try std.testing.expectEqual(red, f1.pixelAt(25, 25)); // source hero hidden, page A shows
    try std.testing.expectEqual(blue, f1.pixelAt(150, 150)); // page B covers the right
    tl.tick(100); // completes: the hero lands at (40,40,120,120)
    view.layout(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    r.paint(view, 0x000000FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(green, f2.pixelAt(100, 100)); // the hero at its destination
    try std.testing.expectEqual(blue, f2.pixelAt(10, 10)); // page B everywhere else
}
