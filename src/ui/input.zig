// Input — pointer + keyboard routing (Phase 1c).
// The host converts platform events (SDL) into PointerEvent/KeyEvent — this
// module knows nothing about SDL — and dispatches them into the widget tree:
//   - down: hit-test → deepest node, capture it (it receives move/up = drag),
//     events bubble up until a node reports them handled.
//   - move: to the captured node while dragging, else hover (enter/leave).
//     Hover phases (enter/leave/hover_move) are notifications, not claims:
//     they bubble through the whole ancestor chain even past handlers that
//     report them handled, so a wrapper (tooltip) observes hover on children
//     that claim it (a Button sets its hover state and reports handled).
//     Interaction phases (down/move/up/outside_down) stop at the first
//     handler that claims them.
//   - up: to the captured node (a "click" is down+up on the same node — the
//     widget decides, e.g. Button fires onPressed only if up is inside).
//   - keyboard: delivered to the focused node's chain (TextField).
//   - open popup: a click outside it closes it and is consumed (barrier
//     semantics — the next click reaches the tree underneath).
//
// Single-window P0: the active router is process-global (setCurrent), like
// Store(T). Widgets call requestFocus/setOpenPopup/releaseNode through it.
const std = @import("std");
const node_mod = @import("node.zig");
const semantics_mod = @import("semantics.zig");

const Node = node_mod.Node;

pub const PointerCursor = node_mod.PointerCursor;

pub const PointerPhase = enum { down, move, up, enter, leave, outside_down, hover_move };

pub const PointerEvent = struct {
    phase: PointerPhase,
    x: f32,
    y: f32,
    /// Window (viewport) coordinates before ancestor transforms — drag
    /// deltas are physical finger motion and must use these (a scrollable
    /// scrolling under a held finger shifts its content-space coords).
    raw_x: f32 = 0,
    raw_y: f32 = 0,
    button: u8 = 1, // 1 = primary (SDL_BUTTON_LEFT)
    pointer: u64 = 0, // 0 = primary (mouse); touch = SDL finger id (multi-touch)
    time_ms: u64 = 0, // event timestamp (SDL event ns / 1e6) — gesture timing
};

/// Platform-independent keys (the host maps SDL_Keycode → Key).
pub const Key = enum(u32) {
    unknown = 0,
    backspace = 0x08,
    tab = 0x09,
    enter = 0x0D,
    escape = 0x1B,
    delete = 0x7F,
    left = 0x100, // synthetic (host-mapped)
    right = 0x101,
    back = 0x102, // synthetic: hardware back (Android) / Escape (desktop)
    up = 0x103, // synthetic (host-mapped)
    down = 0x104,
    space = 0x20, // the space bar (key_down, not text input)
    _,
};

pub const KeyEvent = struct {
    pub const Kind = enum { key_down, text_input };
    kind: Kind,
    key: Key = .unknown, // key_down
    text: []const u8 = "", // text_input (UTF-8, borrowed from the event source)
    shift: bool = false, // modifier (Phase 2c: Shift+Tab = focus previous)
};

/// Scroll (mouse wheel / touchpad) event — Phase 1f.
pub const ScrollEvent = struct {
    x: f32, // pointer position (window px) — hit-test target
    y: f32,
    delta_x: f32 = 0, // wheel deltas (clicks; y positive = scroll up/away)
    delta_y: f32 = 0,
    pointer: u64 = 0,
    time_ms: u64 = 0,
};

/// Max simultaneously captured pointers (mouse + fingers). Fixed slots: the
/// router never allocates.
pub const MAX_POINTERS = 8;

pub const Capture = struct { pointer: u64, node: *Node };

/// Back-button handler (Phase 2a): the navigator pops the page stack.
/// Returns true when the back request was handled.
pub const BackHandler = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque) bool,
    userdata: ?*anyopaque,
};

fn nullCaptureSlots() [MAX_POINTERS]?Capture {
    var slots: [MAX_POINTERS]?Capture = undefined;
    for (&slots) |*s| s.* = null;
    return slots;
}

pub const InputRouter = struct {
    captured: [MAX_POINTERS]?Capture = nullCaptureSlots(), // per-pointer capture (drag)
    hovered: ?*Node = null,
    /// Last primary-pointer position (window px) — to refresh hover after a
    /// drag release, a scroll under a stationary pointer, or a layout change.
    last_x: f32 = 0,
    last_y: f32 = 0,
    has_last: bool = false,
    focused: ?*Node = null,
    open_popup: ?*Node = null,
    back_handler: ?BackHandler = null, // navigator pop (Phase 2a)
    /// Modal back handlers (Escape / hardware back), consulted by dispatchBack
    /// BEFORE the navigator's back_handler. Fixed-size stack (no allocator):
    /// nesting is shallow (drawer < dialog < bottom sheet…). LIFO.
    back_stack: [8]BackHandler = undefined,
    back_stack_len: usize = 0,

    fn captureSlot(self: *InputRouter, pointer: u64) ?usize {
        for (self.captured, 0..) |slot, i| {
            if (slot) |c| {
                if (c.pointer == pointer) return i;
            }
        }
        return null;
    }

    fn captureSet(self: *InputRouter, pointer: u64, node: *Node) void {
        if (self.captureSlot(pointer)) |i| {
            self.captured[i] = .{ .pointer = pointer, .node = node };
            return;
        }
        for (self.captured, 0..) |slot, i| {
            if (slot == null) {
                self.captured[i] = .{ .pointer = pointer, .node = node };
                return;
            }
        }
        // No free slot (8+ simultaneous pointers): drop the capture.
    }

    fn captureClear(self: *InputRouter, pointer: u64) void {
        if (self.captureSlot(pointer)) |i| self.captured[i] = null;
    }

    /// The node currently capturing `pointer` (receives its move/up), if any.
    pub fn capturedNode(self: *InputRouter, pointer: u64) ?*Node {
        if (self.captureSlot(pointer)) |i| return self.captured[i].?.node;
        return null;
    }

    pub fn dispatchPointer(self: *InputRouter, root: *Node, ev_in: PointerEvent) void {
        // Events arrive in window (viewport) coordinates; keep a copy as
        // raw_* before any local-space mapping below. Drag deltas are
        // physical finger motion: a scrollable scrolling under a held
        // finger shifts the content-space coordinates it receives.
        var ev = ev_in;
        ev.raw_x = ev_in.x;
        ev.raw_y = ev_in.y;
        if (ev.pointer == 0) {
            self.last_x = ev.x;
            self.last_y = ev.y;
            self.has_last = true;
        }
        switch (ev.phase) {
            .down => {
                // A click outside an open popup closes it and is consumed
                // (barrier semantics — the next click reaches the tree).
                if (self.open_popup) |popup| {
                    // Popup children live outside the popup's bounds (overlay):
                    // hit-test within the popup subtree without the
                    // ancestor-bounds gate. The point is mapped into the
                    // popup's parent space first (it may sit in a scrollable).
                    const p = Node.mapPointToParentSpace(popup, ev.x, ev.y);
                    const hit: ?*Node = if (hitTestSubtree(popup, p.x, p.y)) |h|
                        h
                    else if (root.hitTestMapped(ev.x, ev.y)) |m|
                        m.node
                    else
                        null;
                    const inside = if (hit) |h| isDescendant(h, popup) else false;
                    if (!inside) {
                        self.open_popup = null;
                        _ = sendPointer(popup, .{ .phase = .outside_down, .x = ev.x, .y = ev.y, .raw_x = ev.raw_x, .raw_y = ev.raw_y, .pointer = ev.pointer, .time_ms = ev.time_ms });
                        return;
                    }
                    if (hit) |t| {
                        self.captureSet(ev.pointer, t);
                        const local = Node.mapPointToParentSpace(t, ev.x, ev.y);
                        _ = sendPointer(t, .{ .phase = ev.phase, .x = local.x, .y = local.y, .raw_x = ev.raw_x, .raw_y = ev.raw_y, .button = ev.button, .pointer = ev.pointer, .time_ms = ev.time_ms });
                    }
                    return;
                }
                if (root.hitTestMapped(ev.x, ev.y)) |hit| {
                    self.captureSet(ev.pointer, hit.node);
                    // Deliver the event in the hit node's parent space:
                    // scrolled/transformed controls get local coordinates.
                    _ = sendPointer(hit.node, .{ .phase = ev.phase, .x = hit.x, .y = hit.y, .raw_x = ev.raw_x, .raw_y = ev.raw_y, .button = ev.button, .pointer = ev.pointer, .time_ms = ev.time_ms });
                }
            },
            .move => {
                if (self.capturedNode(ev.pointer)) |c| {
                    const local = Node.mapPointToParentSpace(c, ev.x, ev.y);
                    _ = sendPointer(c, .{ .phase = ev.phase, .x = local.x, .y = local.y, .raw_x = ev.raw_x, .raw_y = ev.raw_y, .button = ev.button, .pointer = ev.pointer, .time_ms = ev.time_ms });
                } else if (ev.pointer == 0) {
                    // Hover follows the primary (mouse) pointer only.
                    self.updateHover(root, ev.x, ev.y, true);
                }
            },
            .up => {
                if (self.capturedNode(ev.pointer)) |c| {
                    self.captureClear(ev.pointer);
                    const local = Node.mapPointToParentSpace(c, ev.x, ev.y);
                    _ = sendPointer(c, .{ .phase = ev.phase, .x = local.x, .y = local.y, .raw_x = ev.raw_x, .raw_y = ev.raw_y, .button = ev.button, .pointer = ev.pointer, .time_ms = ev.time_ms });
                    // after a drag, the pointer may rest over another node:
                    // refresh hover from the release position (primary pointer)
                    if (ev.pointer == 0) self.refreshHover(root);
                } else if (root.hitTestMapped(ev.x, ev.y)) |hit| {
                    _ = sendPointer(hit.node, .{ .phase = ev.phase, .x = hit.x, .y = hit.y, .raw_x = ev.raw_x, .raw_y = ev.raw_y, .button = ev.button, .pointer = ev.pointer, .time_ms = ev.time_ms });
                }
            },
            // enter/leave/outside_down/hover_move are synthesized by the router.
            .enter, .leave, .outside_down, .hover_move => {},
        }
    }

    /// Dispatch a key event to the focused node's chain. Returns true when a
    /// node handled it (Phase 2c: the host falls back to semantic activation).
    pub fn dispatchKey(self: *InputRouter, ev: KeyEvent) bool {
        if (self.focused) |f| return sendKey(f, ev);
        return false;
    }

    pub fn setBackHandler(self: *InputRouter, h: ?BackHandler) void {
        self.back_handler = h;
    }

    /// Register a modal back handler (a drawer/dialog/bottom sheet while open).
    /// Returns false when the stack is full (back falls through to the next
    /// handler). Modals must pop themselves when closed or destroyed.
    pub fn pushBackHandler(self: *InputRouter, h: BackHandler) bool {
        if (self.back_stack_len >= self.back_stack.len) return false;
        self.back_stack[self.back_stack_len] = h;
        self.back_stack_len += 1;
        return true;
    }

    /// Remove the handler registered for `userdata` (topmost match, LIFO).
    pub fn popBackHandler(self: *InputRouter, userdata: ?*anyopaque) void {
        var i = self.back_stack_len;
        while (i > 0) {
            i -= 1;
            if (self.back_stack[i].userdata == userdata) {
                for (i..self.back_stack_len - 1) |j| self.back_stack[j] = self.back_stack[j + 1];
                self.back_stack_len -= 1;
                return;
            }
        }
    }

    /// Hardware back (Android) / Escape (desktop), Phase 2a. The focused
    /// chain gets `.escape` first (a text field consumes it: Escape blurs);
    /// then the modal back stack (topmost first — an open drawer/dialog
    /// dismisses itself even when focus is outside it); then the registered
    /// back handler (the navigator pops). Returns true when handled.
    pub fn dispatchBack(self: *InputRouter) bool {
        if (self.focused) |f| {
            if (sendKey(f, .{ .kind = .key_down, .key = .escape })) return true;
        }
        if (self.back_stack_len > 0) {
            const h = self.back_stack[self.back_stack_len - 1];
            return h.fn_ptr(h.userdata);
        }
        if (self.back_handler) |h| return h.fn_ptr(h.userdata);
        return false;
    }

    /// Hit-test + update the hovered node (enter/leave notifications).
    /// `send_move` also emits hover_move for an unchanged deepest node (per-cell
    /// hover: nav bar / tabs track across cell gaps; a separate phase on
    /// purpose — uncaptured hover must never reach drag consumers of `.move`).
    fn updateHover(self: *InputRouter, root: *Node, x: f32, y: f32, send_move: bool) void {
        const hit = root.hitTestMapped(x, y);
        const hovered = if (hit) |h| h.node else null;
        if (hovered != self.hovered) {
            if (self.hovered) |h| _ = sendPointer(h, .{ .phase = .leave, .x = x, .y = y, .raw_x = x, .raw_y = y, .pointer = 0, .time_ms = 0 });
            self.hovered = hovered;
            if (hit) |h| _ = sendPointer(h.node, .{ .phase = .enter, .x = h.x, .y = h.y, .raw_x = x, .raw_y = y, .pointer = 0, .time_ms = 0 });
        } else if (send_move) {
            if (hit) |h| _ = sendPointer(h.node, .{ .phase = .hover_move, .x = h.x, .y = h.y, .raw_x = x, .raw_y = y, .pointer = 0, .time_ms = 0 });
        }
    }

    /// Re-hit-test the primary pointer's last position and update hover
    /// (enter/leave) — after a drag release, a scroll under a stationary
    /// pointer, or a layout change (the host calls this; Phase 2d-0.5).
    pub fn refreshHover(self: *InputRouter, root: *Node) void {
        if (!self.has_last) return;
        self.updateHover(root, self.last_x, self.last_y, false);
    }

    /// Scroll: hit-test at the pointer position, deliver to the node's
    /// chain (bubbles until a scrollable reports it handled).
    pub fn dispatchScroll(self: *InputRouter, root: *Node, ev: ScrollEvent) void {
        if (ev.pointer == 0) {
            self.last_x = ev.x;
            self.last_y = ev.y;
            self.has_last = true;
        }
        const hit = root.hitTest(ev.x, ev.y) orelse return;
        _ = sendScroll(hit, ev);
    }

    pub fn focus(self: *InputRouter, node: ?*Node) void {
        self.focused = node;
    }

    /// The node currently hovered by the primary (mouse) pointer, if any.
    pub fn hoveredNode(self: *InputRouter) ?*Node {
        return self.hovered;
    }

    /// Release every reference to a node being destroyed. No GC: widgets with
    /// input handlers call this from their deinit (dangling pointers are fatal).
    pub fn releaseNode(self: *InputRouter, node: *Node) void {
        for (&self.captured) |*slot| {
            if (slot.*) |c| {
                if (c.node == node) slot.* = null;
            }
        }
        if (self.hovered == node) self.hovered = null;
        if (self.focused == node) self.focused = null;
        if (self.open_popup == node) self.open_popup = null;
    }
};

/// The pointer cursor for a hovered node (Phase 2d-0.5, desktop): the
/// deepest node's VTable.cursor hook wins, then the semantic role
/// (interactive controls → hand, .text_field → ibeam), else the default
/// arrow.
pub fn cursorForNode(node: ?*Node) PointerCursor {
    var n = node;
    while (n) |cur| : (n = cur.parent) {
        if (cur.vtable.cursor) |c| return c(cur);
        if (cur.semantics) |sem| {
            switch (sem.role) {
                .button, .link, .toggle, .checkbox, .radio => return .hand,
                .text_field => return .ibeam,
                else => {},
            }
        }
    }
    return .default;
}

/// Deliver a pointer event to `node`, bubbling up to the root until handled.
/// Hover phases are notifications: they keep bubbling past handlers that
/// report them handled (see the module header).
fn sendPointer(node: *Node, ev: PointerEvent) bool {
    const notify = switch (ev.phase) {
        .enter, .leave, .hover_move => true,
        else => false,
    };
    var handled = false;
    var n: ?*Node = node;
    while (n) |cur| : (n = cur.parent) {
        if (cur.vtable.on_pointer) |h| {
            if (h(cur, ev)) {
                handled = true;
                if (!notify) return true;
            }
        }
    }
    return handled;
}

/// Deliver a key event to `node`, bubbling up to the root until handled.
fn sendKey(node: *Node, ev: KeyEvent) bool {
    var n: ?*Node = node;
    while (n) |cur| : (n = cur.parent) {
        if (cur.vtable.on_key) |h| {
            if (h(cur, ev)) return true;
        }
    }
    return false;
}

/// Deliver a scroll event to `node`, bubbling up to the root until handled.
fn sendScroll(node: *Node, ev: ScrollEvent) bool {
    var n: ?*Node = node;
    while (n) |cur| : (n = cur.parent) {
        if (cur.vtable.on_scroll) |h| {
            if (h(cur, ev)) return true;
        }
    }
    return false;
}

fn isDescendant(node: *Node, ancestor: *Node) bool {
    var n: ?*Node = node;
    while (n) |cur| : (n = cur.parent) {
        if (cur == ancestor) return true;
    }
    return false;
}

/// Deepest visible descendant of `node` containing the point — unlike
/// Node.hitTest, intermediate bounds are not required to contain the point
/// (popup children paint and hit outside their parent's bounds). Paint
/// transforms still apply (pre_children_hit) and the popup's own effective
/// hit rect is hit_bounds-aware.
fn hitTestSubtree(node: *Node, px: f32, py: f32) ?*Node {
    if (!node.visible) return null;
    var cx = px;
    var cy = py;
    if (node.vtable.pre_children_hit) |pre| {
        const p = pre(node, px, py);
        cx = p.x;
        cy = p.y;
    }
    var i = node.children.items.len;
    while (i > 0) {
        i -= 1;
        if (hitTestSubtree(node.children.items[i], cx, cy)) |hit| return hit;
    }
    const b = if (node.vtable.hit_bounds) |hb| hb(node) else node.bounds;
    if (b.contains(px, py)) return node;
    return null;
}

// --- process-global current router (single-window P0) ---

var current_router: ?*InputRouter = null;

pub fn setCurrent(r: ?*InputRouter) void {
    current_router = r;
}

/// The process-global router (setCurrent), or null (tests without a host).
pub fn current() ?*InputRouter {
    return current_router;
}

pub fn requestFocus(node: ?*Node) void {
    if (current_router) |r| r.focus(node);
    semantics_mod.routerFocusChanged(node); // keep the focus ring in sync (Phase 2c)
}

pub fn isFocused(node: *Node) bool {
    return if (current_router) |r| r.focused == node else false;
}

pub fn setOpenPopup(node: ?*Node) void {
    if (current_router) |r| r.open_popup = node;
}

pub fn releaseNode(node: *Node) void {
    if (current_router) |r| r.releaseNode(node);
}

// --- tests (recording stub widget) ---

const RecState = struct {
    log: std.array_list.Managed(PointerPhase),
    keys: std.array_list.Managed(KeyEvent.Kind),
    last_key: Key = .unknown,
    handled: bool = true,
};

fn recMeasure(n: *Node, c: ui_layout.Constraints) ui_layout.Size {
    _ = n;
    return c.constrain(.{ .w = 100, .h = 100 });
}
const ui_layout = @import("layout.zig");
fn recLayout(n: *Node, bounds: ui_node.Rect) void {
    _ = n;
    _ = bounds;
}
const ui_node = @import("node.zig");
fn recPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}
const kx = @import("../kx.zig");
fn recOnPointer(n: *Node, ev: PointerEvent) bool {
    const s: *RecState = @ptrCast(@alignCast(n.state.?));
    s.log.append(ev.phase) catch @panic("klaxon: out of memory");
    return s.handled;
}
fn recOnKey(n: *Node, ev: KeyEvent) bool {
    const s: *RecState = @ptrCast(@alignCast(n.state.?));
    s.keys.append(ev.kind) catch @panic("klaxon: out of memory");
    s.last_key = ev.key;
    return s.handled;
}
fn recDeinit(n: *Node) void {
    const s: *RecState = @ptrCast(@alignCast(n.state.?));
    s.log.deinit();
    s.keys.deinit();
    n.allocator.destroy(s);
}
const rec_vtable = ui_node.VTable{
    .measure = recMeasure,
    .layout = recLayout,
    .paint = recPaint,
    .deinit = recDeinit,
    .on_pointer = recOnPointer,
    .on_key = recOnKey,
};

fn recNode(allocator: std.mem.Allocator, handled: bool) !*Node {
    const node = try Node.create(allocator, &rec_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(RecState);
    errdefer allocator.destroy(s);
    s.* = .{
        .log = std.array_list.Managed(PointerPhase).init(allocator),
        .keys = std.array_list.Managed(KeyEvent.Kind).init(allocator),
        .handled = handled,
    };
    node.state = s;
    return node;
}

fn recState(n: *Node) *RecState {
    return @ptrCast(@alignCast(n.state.?));
}

test "pointer down dispatches to the deepest node and bubbles until handled" {
    const parent = try recNode(std.testing.allocator, false);
    defer parent.deinit();
    const child = try recNode(std.testing.allocator, false);
    parent.add(child);
    parent.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    child.layout(.{ .x = 10, .y = 10, .w = 50, .h = 50 });
    var router = InputRouter{};
    router.dispatchPointer(parent, .{ .phase = .down, .x = 20, .y = 20 });
    try std.testing.expectEqual(@as(usize, 1), recState(child).log.items.len);
    try std.testing.expectEqual(@as(usize, 1), recState(parent).log.items.len); // bubbled

    // Handled by the child: the parent sees nothing.
    const parent2 = try recNode(std.testing.allocator, false);
    defer parent2.deinit();
    const child2 = try recNode(std.testing.allocator, true);
    parent2.add(child2);
    parent2.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    child2.layout(.{ .x = 10, .y = 10, .w = 50, .h = 50 });
    router.dispatchPointer(parent2, .{ .phase = .down, .x = 20, .y = 20 });
    try std.testing.expectEqual(@as(usize, 1), recState(child2).log.items.len);
    try std.testing.expectEqual(@as(usize, 0), recState(parent2).log.items.len);
}

test "drag: move and up go to the captured node, even outside its bounds" {
    const root = try recNode(std.testing.allocator, true);
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 50, .h = 50 });
    var router = InputRouter{};
    router.dispatchPointer(root, .{ .phase = .down, .x = 10, .y = 10 });
    router.dispatchPointer(root, .{ .phase = .move, .x = 500, .y = 500 }); // outside
    router.dispatchPointer(root, .{ .phase = .up, .x = 500, .y = 500 });
    const log = recState(root).log.items;
    try std.testing.expectEqual(@as(usize, 3), log.len);
    try std.testing.expectEqual(PointerPhase.down, log[0]);
    try std.testing.expectEqual(PointerPhase.move, log[1]);
    try std.testing.expectEqual(PointerPhase.up, log[2]);
}

test "up after a down elsewhere still goes to the captured node (no phantom click)" {
    const root = try recNode(std.testing.allocator, false);
    defer root.deinit();
    const a = try recNode(std.testing.allocator, true);
    const b = try recNode(std.testing.allocator, true);
    root.add(a);
    root.add(b);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    a.layout(.{ .x = 0, .y = 0, .w = 50, .h = 100 });
    b.layout(.{ .x = 50, .y = 0, .w = 50, .h = 100 });
    var router = InputRouter{};
    router.dispatchPointer(root, .{ .phase = .down, .x = 10, .y = 10 });
    router.dispatchPointer(root, .{ .phase = .up, .x = 80, .y = 10 }); // over B
    try std.testing.expectEqual(@as(usize, 2), recState(a).log.items.len); // down + up
    // B gets no click — only the hover-refresh enter (the pointer rests on it)
    const blog = recState(b).log.items;
    try std.testing.expectEqual(@as(usize, 1), blog.len);
    try std.testing.expectEqual(PointerPhase.enter, blog[0]);
}

test "hover: enter and leave fire on move" {
    const root = try recNode(std.testing.allocator, true);
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    var router = InputRouter{};
    router.dispatchPointer(root, .{ .phase = .move, .x = 50, .y = 50 });
    router.dispatchPointer(root, .{ .phase = .move, .x = 500, .y = 500 });
    const log = recState(root).log.items;
    try std.testing.expectEqual(@as(usize, 2), log.len);
    try std.testing.expectEqual(PointerPhase.enter, log[0]);
    try std.testing.expectEqual(PointerPhase.leave, log[1]);
}

test "hover phases bubble past a child that reports them handled" {
    // A claiming child (Button sets its hover state and reports handled)
    // must not hide hover from wrapper ancestors (tooltip shows on hover).
    const parent = try recNode(std.testing.allocator, false);
    defer parent.deinit();
    const child = try recNode(std.testing.allocator, true); // claims every phase
    parent.add(child);
    parent.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    child.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    var router = InputRouter{};
    router.dispatchPointer(parent, .{ .phase = .move, .x = 50, .y = 50 }); // enter
    router.dispatchPointer(parent, .{ .phase = .move, .x = 50, .y = 50 }); // hover_move
    router.dispatchPointer(parent, .{ .phase = .move, .x = 500, .y = 500 }); // leave
    const log = recState(parent).log.items;
    try std.testing.expectEqual(@as(usize, 3), log.len);
    try std.testing.expectEqual(PointerPhase.enter, log[0]);
    try std.testing.expectEqual(PointerPhase.hover_move, log[1]);
    try std.testing.expectEqual(PointerPhase.leave, log[2]);
    // Interaction phases still stop at the claiming child.
    router.dispatchPointer(parent, .{ .phase = .down, .x = 50, .y = 50 });
    try std.testing.expectEqual(@as(usize, 3), recState(parent).log.items.len);
}

const cursor_hook_vtable = blk: {
    var vt = rec_vtable;
    vt.cursor = struct {
        fn c(_: *Node) node_mod.PointerCursor {
            return .move;
        }
    }.c;
    break :blk vt;
};

test "cursors: cursorForNode maps the vtable hook, then the semantic role" {
    // null / plain node → the default arrow
    try std.testing.expectEqual(PointerCursor.default, cursorForNode(null));
    const plain = try recNode(std.testing.allocator, false);
    defer plain.deinit();
    try std.testing.expectEqual(PointerCursor.default, cursorForNode(plain));
    // a .button semantic on the parent → hand (seen from the child)
    const parent = try recNode(std.testing.allocator, false);
    defer parent.deinit();
    const child = try recNode(std.testing.allocator, false);
    parent.add(child);
    semantics_mod.attach(parent, .{ .role = .button, .label = "ok" });
    try std.testing.expectEqual(PointerCursor.hand, cursorForNode(child));
    // the interactive toggle roles → hand too
    semantics_mod.attach(child, .{ .role = .toggle, .label = "t", .checked = false });
    try std.testing.expectEqual(PointerCursor.hand, cursorForNode(child));
    semantics_mod.attach(child, .{ .role = .checkbox, .label = "c", .checked = false });
    try std.testing.expectEqual(PointerCursor.hand, cursorForNode(child));
    // a .text_field semantic on the child → ibeam
    semantics_mod.attach(child, .{ .role = .text_field, .label = "name" });
    try std.testing.expectEqual(PointerCursor.ibeam, cursorForNode(child));
    // the vtable hook wins over the semantic role
    const custom = try recNode(std.testing.allocator, false);
    defer custom.deinit();
    custom.vtable = &cursor_hook_vtable;
    semantics_mod.attach(custom, .{ .role = .text_field, .label = "x" });
    try std.testing.expectEqual(PointerCursor.move, cursorForNode(custom));
}

test "hover refreshes after a captured drag ends over another node" {
    var router = InputRouter{};
    const root = try recNode(std.testing.allocator, false);
    defer root.deinit();
    const btn = try recNode(std.testing.allocator, true); // claims (a button)
    const bg = try recNode(std.testing.allocator, false);
    root.add(btn);
    root.add(bg);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    btn.layout(.{ .x = 0, .y = 0, .w = 50, .h = 100 });
    bg.layout(.{ .x = 50, .y = 0, .w = 50, .h = 100 });
    // hover the button, press (capture), drag over the background, release
    router.dispatchPointer(root, .{ .phase = .move, .x = 10, .y = 50 });
    try std.testing.expectEqual(btn, router.hoveredNode());
    router.dispatchPointer(root, .{ .phase = .down, .x = 10, .y = 50 });
    router.dispatchPointer(root, .{ .phase = .move, .x = 80, .y = 50 }); // captured: hover unchanged
    try std.testing.expectEqual(btn, router.hoveredNode());
    router.dispatchPointer(root, .{ .phase = .up, .x = 80, .y = 50 });
    // the release refreshes hover: the background is now hovered
    try std.testing.expectEqual(bg, router.hoveredNode());
    const log = recState(bg).log.items;
    try std.testing.expect(log.len > 0);
    try std.testing.expectEqual(PointerPhase.enter, log[log.len - 1]);
}

test "keyboard goes to the focused node" {
    const root = try recNode(std.testing.allocator, true);
    defer root.deinit();
    const child = try recNode(std.testing.allocator, true);
    root.add(child);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    child.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    var router = InputRouter{};
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "x" }); // nobody focused
    try std.testing.expectEqual(@as(usize, 0), recState(child).keys.items.len);
    router.focus(child);
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "x" });
    try std.testing.expectEqual(@as(usize, 1), recState(child).keys.items.len);
    router.focus(null);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(usize, 1), recState(child).keys.items.len);
}

fn countBack(userdata: ?*anyopaque) bool {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
    return true;
}

test "back: focused chain gets the key first, then the back handler" {
    const root = try recNode(std.testing.allocator, false);
    defer root.deinit();
    const field = try recNode(std.testing.allocator, true); // consumes every key
    root.add(field);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    field.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    var router = InputRouter{};
    var handled: u32 = 0;
    router.setBackHandler(.{ .fn_ptr = countBack, .userdata = &handled });
    // No focus: straight to the back handler.
    try std.testing.expect(router.dispatchBack());
    try std.testing.expectEqual(@as(u32, 1), handled);
    // Focused node consumes the key: the handler is not called.
    router.focus(field);
    try std.testing.expect(router.dispatchBack());
    try std.testing.expectEqual(@as(u32, 1), handled);
    try std.testing.expectEqual(@as(usize, 1), recState(field).keys.items.len);
    // Unhandled focused node: bubbles past it, the handler runs.
    router.focus(root); // root does not handle keys
    try std.testing.expect(router.dispatchBack());
    try std.testing.expectEqual(@as(u32, 2), handled);
    // No handler, no focus: unhandled.
    router.setBackHandler(null);
    router.focus(null);
    try std.testing.expect(!router.dispatchBack());
}

test "back: the focused chain receives .escape (a text field blurs on it)" {
    const root = try recNode(std.testing.allocator, true); // consumes every key
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    var router = InputRouter{};
    var handled: u32 = 0;
    router.setBackHandler(.{ .fn_ptr = countBack, .userdata = &handled });
    router.focus(root);
    try std.testing.expect(router.dispatchBack());
    try std.testing.expectEqual(@as(u32, 0), handled); // the focused chain consumed it
    try std.testing.expectEqual(Key.escape, recState(root).last_key);
}

test "click outside an open popup closes it and is consumed (barrier)" {
    const root = try recNode(std.testing.allocator, false);
    defer root.deinit();
    const popup = try recNode(std.testing.allocator, true);
    const other = try recNode(std.testing.allocator, true);
    root.add(popup);
    root.add(other);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    popup.layout(.{ .x = 0, .y = 0, .w = 50, .h = 100 });
    other.layout(.{ .x = 50, .y = 0, .w = 50, .h = 100 });
    var router = InputRouter{};
    router.open_popup = popup;
    // Click on `other`: popup gets outside_down, other gets nothing.
    router.dispatchPointer(root, .{ .phase = .down, .x = 80, .y = 10 });
    try std.testing.expectEqual(@as(usize, 1), recState(popup).log.items.len);
    try std.testing.expectEqual(PointerPhase.outside_down, recState(popup).log.items[0]);
    try std.testing.expectEqual(@as(usize, 0), recState(other).log.items.len);
    try std.testing.expect(router.open_popup == null);
    // Next click reaches the tree normally.
    router.dispatchPointer(root, .{ .phase = .down, .x = 80, .y = 10 });
    try std.testing.expectEqual(@as(usize, 1), recState(other).log.items.len);
}

test "releaseNode clears every router reference to the node" {
    const root = try recNode(std.testing.allocator, true);
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    var router = InputRouter{};
    // hover first (a move with no capture updates hovered)
    router.dispatchPointer(root, .{ .phase = .move, .x = 10, .y = 10 });
    try std.testing.expect(router.hovered == root);
    // then capture (a down while hovering)
    router.dispatchPointer(root, .{ .phase = .down, .x = 10, .y = 10 });
    try std.testing.expect(router.capturedNode(0) == root);
    router.focus(root);
    router.open_popup = root;
    router.releaseNode(root);
    try std.testing.expect(router.capturedNode(0) == null);
    try std.testing.expect(router.hovered == null);
    try std.testing.expect(router.focused == null);
    try std.testing.expect(router.open_popup == null);
}

test "multiple pointers are captured independently (multi-touch)" {
    const root = try recNode(std.testing.allocator, false);
    defer root.deinit();
    const a = try recNode(std.testing.allocator, true);
    const b = try recNode(std.testing.allocator, true);
    root.add(a);
    root.add(b);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    a.layout(.{ .x = 0, .y = 0, .w = 50, .h = 100 });
    b.layout(.{ .x = 50, .y = 0, .w = 50, .h = 100 });
    var router = InputRouter{};
    // Two fingers down on A and B.
    router.dispatchPointer(root, .{ .phase = .down, .x = 10, .y = 10, .pointer = 1 });
    router.dispatchPointer(root, .{ .phase = .down, .x = 80, .y = 10, .pointer = 2 });
    try std.testing.expect(router.capturedNode(1) == a);
    try std.testing.expect(router.capturedNode(2) == b);
    // Moving finger 1 reaches A only.
    router.dispatchPointer(root, .{ .phase = .move, .x = 20, .y = 10, .pointer = 1 });
    try std.testing.expectEqual(@as(usize, 2), recState(a).log.items.len); // down + move
    try std.testing.expectEqual(@as(usize, 1), recState(b).log.items.len); // down only
    // Lifting finger 2 releases B; A stays captured.
    router.dispatchPointer(root, .{ .phase = .up, .x = 80, .y = 10, .pointer = 2 });
    try std.testing.expect(router.capturedNode(2) == null);
    try std.testing.expect(router.capturedNode(1) == a);
    try std.testing.expectEqual(PointerPhase.up, recState(b).log.items[1]);
}

test "invisible nodes are neither painted nor hit-tested" {
    const root = try recNode(std.testing.allocator, true);
    defer root.deinit();
    const child = try recNode(std.testing.allocator, true);
    root.add(child);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    child.layout(.{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try std.testing.expectEqual(child, root.hitTest(10, 10).?);
    child.visible = false;
    try std.testing.expectEqual(root, root.hitTest(10, 10).?);
}
