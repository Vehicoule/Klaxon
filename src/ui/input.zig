// Input — pointer + keyboard routing (Phase 1c).
// The host converts platform events (SDL) into PointerEvent/KeyEvent — this
// module knows nothing about SDL — and dispatches them into the widget tree:
//   - down: hit-test → deepest node, capture it (it receives move/up = drag),
//     events bubble up until a node reports them handled.
//   - move: to the captured node while dragging, else hover (enter/leave).
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

const Node = node_mod.Node;

pub const PointerPhase = enum { down, move, up, enter, leave, outside_down };

pub const PointerEvent = struct {
    phase: PointerPhase,
    x: f32,
    y: f32,
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
    _,
};

pub const KeyEvent = struct {
    pub const Kind = enum { key_down, text_input };
    kind: Kind,
    key: Key = .unknown, // key_down
    text: []const u8 = "", // text_input (UTF-8, borrowed from the event source)
};

/// Max simultaneously captured pointers (mouse + fingers). Fixed slots: the
/// router never allocates.
pub const MAX_POINTERS = 8;

pub const Capture = struct { pointer: u64, node: *Node };

fn nullCaptureSlots() [MAX_POINTERS]?Capture {
    var slots: [MAX_POINTERS]?Capture = undefined;
    for (&slots) |*s| s.* = null;
    return slots;
}

pub const InputRouter = struct {
    captured: [MAX_POINTERS]?Capture = nullCaptureSlots(), // per-pointer capture (drag)
    hovered: ?*Node = null,
    focused: ?*Node = null,
    open_popup: ?*Node = null,

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

    pub fn dispatchPointer(self: *InputRouter, root: *Node, ev: PointerEvent) void {
        switch (ev.phase) {
            .down => {
                // A click outside an open popup closes it and is consumed
                // (barrier semantics — the next click reaches the tree).
                if (self.open_popup) |popup| {
                    // Popup children live outside the popup's bounds (overlay):
                    // hit-test within the popup subtree without the
                    // ancestor-bounds gate.
                    const hit = hitTestSubtree(popup, ev.x, ev.y) orelse root.hitTest(ev.x, ev.y);
                    const inside = if (hit) |h| isDescendant(h, popup) else false;
                    if (!inside) {
                        self.open_popup = null;
                        _ = sendPointer(popup, .{ .phase = .outside_down, .x = ev.x, .y = ev.y, .pointer = ev.pointer, .time_ms = ev.time_ms });
                        return;
                    }
                    if (hit) |t| {
                        self.captureSet(ev.pointer, t);
                        _ = sendPointer(t, ev);
                    }
                    return;
                }
                const target = root.hitTest(ev.x, ev.y);
                if (target) |t| {
                    self.captureSet(ev.pointer, t);
                    _ = sendPointer(t, ev);
                }
            },
            .move => {
                if (self.capturedNode(ev.pointer)) |c| {
                    _ = sendPointer(c, ev);
                } else if (ev.pointer == 0) {
                    // Hover follows the primary (mouse) pointer only.
                    const hit = root.hitTest(ev.x, ev.y);
                    if (hit != self.hovered) {
                        if (self.hovered) |h| _ = sendPointer(h, .{ .phase = .leave, .x = ev.x, .y = ev.y, .pointer = ev.pointer, .time_ms = ev.time_ms });
                        self.hovered = hit;
                        if (hit) |h| _ = sendPointer(h, .{ .phase = .enter, .x = ev.x, .y = ev.y, .pointer = ev.pointer, .time_ms = ev.time_ms });
                    }
                }
            },
            .up => {
                if (self.capturedNode(ev.pointer)) |c| {
                    self.captureClear(ev.pointer);
                    _ = sendPointer(c, ev);
                } else if (root.hitTest(ev.x, ev.y)) |t| {
                    _ = sendPointer(t, ev);
                }
            },
            // enter/leave/outside_down are synthesized by the router itself.
            .enter, .leave, .outside_down => {},
        }
    }

    pub fn dispatchKey(self: *InputRouter, ev: KeyEvent) void {
        if (self.focused) |f| _ = sendKey(f, ev);
    }

    pub fn focus(self: *InputRouter, node: ?*Node) void {
        self.focused = node;
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

/// Deliver a pointer event to `node`, bubbling up to the root until handled.
fn sendPointer(node: *Node, ev: PointerEvent) bool {
    var n: ?*Node = node;
    while (n) |cur| : (n = cur.parent) {
        if (cur.vtable.on_pointer) |h| {
            if (h(cur, ev)) return true;
        }
    }
    return false;
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

fn isDescendant(node: *Node, ancestor: *Node) bool {
    var n: ?*Node = node;
    while (n) |cur| : (n = cur.parent) {
        if (cur == ancestor) return true;
    }
    return false;
}

/// Deepest visible descendant of `node` containing the point — unlike
/// Node.hitTest, intermediate bounds are not required to contain the point
/// (popup children paint and hit outside their parent's bounds).
fn hitTestSubtree(node: *Node, px: f32, py: f32) ?*Node {
    if (!node.visible) return null;
    var i = node.children.items.len;
    while (i > 0) {
        i -= 1;
        if (hitTestSubtree(node.children.items[i], px, py)) |hit| return hit;
    }
    if (node.bounds.contains(px, py)) return node;
    return null;
}

// --- process-global current router (single-window P0) ---

var current: ?*InputRouter = null;

pub fn setCurrent(r: ?*InputRouter) void {
    current = r;
}

pub fn requestFocus(node: ?*Node) void {
    if (current) |r| r.focus(node);
}

pub fn isFocused(node: *Node) bool {
    return if (current) |r| r.focused == node else false;
}

pub fn setOpenPopup(node: ?*Node) void {
    if (current) |r| r.open_popup = node;
}

pub fn releaseNode(node: *Node) void {
    if (current) |r| r.releaseNode(node);
}

// --- tests (recording stub widget) ---

const RecState = struct {
    log: std.array_list.Managed(PointerPhase),
    keys: std.array_list.Managed(KeyEvent.Kind),
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
    try std.testing.expectEqual(@as(usize, 0), recState(b).log.items.len);
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

test "keyboard goes to the focused node" {
    const root = try recNode(std.testing.allocator, true);
    defer root.deinit();
    const child = try recNode(std.testing.allocator, true);
    root.add(child);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    child.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    var router = InputRouter{};
    router.dispatchKey(.{ .kind = .text_input, .text = "x" }); // nobody focused
    try std.testing.expectEqual(@as(usize, 0), recState(child).keys.items.len);
    router.focus(child);
    router.dispatchKey(.{ .kind = .text_input, .text = "x" });
    try std.testing.expectEqual(@as(usize, 1), recState(child).keys.items.len);
    router.focus(null);
    router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(usize, 1), recState(child).keys.items.len);
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
