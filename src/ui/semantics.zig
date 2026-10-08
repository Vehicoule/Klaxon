// Accessibility (Phase 2c) — semantic tree, keyboard focus, live regions.
//
//   - Semantics: a per-node descriptor (role, label, hint, value, checked
//     state, actions). Widgets attach one in their factory (Text → .text,
//     Button → .button, Toggle → .toggle, Slider → .slider, TextField →
//     .text_field, Icon → .image, ...).
//   - Semantic tree: the flattened view assistive tech consumes. Nodes
//     without semantics are transparent (their children are lifted);
//     `Node.exclude_semantics` hides decorative subtrees entirely.
//   - FocusManager: keyboard focus order (Tab / Shift+Tab), activation
//     (Enter/Space = a synthesized click at the node's visual center),
//     and the focus ring the host paints around the focused node.
//   - Live regions: polite/assertive announcements for dynamic changes.
//   - SemanticsBridge (ADR-0009 C ABI): the interface an OS bridge
//     implements (AT-SPI/D-Bus on Linux, NSAccessibility on macOS, UIA on
//     Windows, TalkBack on Android, ARIA on web). The default is LogBridge,
//     which records events (testable headless).
//
// The AT-SPI/D-Bus bridge itself lands with the Linux target (Phase 3a) —
// it needs a session bus + the AT-SPI registry daemon, neither of which
// exists on the dev Mac. The interface is ready for it.
const std = @import("std");
const kx = @import("../kx.zig");
const node_mod = @import("node.zig");
const state_mod = @import("state.zig");
const input_mod = @import("input.zig");
const paint_mod = @import("paint.zig");
const golden = @import("../golden.zig");

const layout_mod = @import("layout.zig");
const Node = node_mod.Node;
const Rect = node_mod.Rect;
const Size = layout_mod.Size;
const Color = paint_mod.Color;

pub const Role = enum {
    none,
    text,
    heading,
    button,
    link,
    image,
    text_field,
    toggle,
    checkbox,
    radio,
    slider,
    progress,
    scrollbar,
    list,
    list_item,
    dialog,
    alert,
    menu,
    menu_item,
    tab,
    tab_panel,
    separator,
    group,
};

pub const Action = enum { activate, increment, decrement, delete };
pub const Actions = std.enums.EnumSet(Action);

pub const LiveRegion = enum { off, polite, assertive };

/// The per-node accessibility descriptor (attached by the widget factory;
/// the node owns it — string fields are borrowed: literals or app-lifetime
/// data).
pub const Semantics = struct {
    role: Role = .none,
    label: []const u8 = "",
    hint: []const u8 = "",
    value: []const u8 = "",
    checked: ?bool = null,
    disabled: bool = false,
    focusable: bool = false,
    actions: Actions = .{},
    live: LiveRegion = .off,
};

/// Attach (or replace) a node's accessibility descriptor.
pub fn attach(node: *Node, sem: Semantics) void {
    if (node.semantics) |old| node.allocator.destroy(old);
    const s = node.allocator.create(Semantics) catch @panic("klaxon: out of memory");
    s.* = sem;
    node.semantics = s;
}

// --- Semantic tree (flattened view for assistive tech) ---

pub const SemanticNode = struct {
    node: *Node,
    role: Role,
    label: []const u8,
    hint: []const u8,
    value: []const u8,
    checked: ?bool,
    disabled: bool,
    focusable: bool,
    actions: Actions,
    live: LiveRegion,
    children: []SemanticNode, // owned

    pub fn deinit(self: *SemanticNode, allocator: std.mem.Allocator) void {
        for (self.children) |*c| c.deinit(allocator);
        allocator.free(self.children);
    }
};

/// First descendant (depth-first) with a non-empty label — the fallback for
/// container-ish roles (a Button's label is its Text child).
fn firstDescendantLabel(n: *Node) ?[]const u8 {
    for (n.children.items) |c| {
        if (c.exclude_semantics or !c.visible) continue;
        if (c.semantics) |sem| {
            if (sem.label.len > 0) return sem.label;
        }
        if (firstDescendantLabel(c)) |l| return l;
    }
    return null;
}

fn flattenInto(allocator: std.mem.Allocator, n: *Node, list: *std.array_list.Managed(SemanticNode)) !void {
    if (n.exclude_semantics or !n.visible) return;
    // A subtree that cannot be hit-tested is not interactive (e.g. the
    // navigator's background pages during a transition) — skip it.
    if (n.vtable.hit_bounds) |hb| {
        const b = hb(n);
        if (b.w <= 0 or b.h <= 0) return;
    }
    if (n.semantics) |sem| {
        var child_list = std.array_list.Managed(SemanticNode).init(allocator);
        errdefer {
            for (child_list.items) |*c| c.deinit(allocator);
            child_list.deinit();
        }
        for (n.children.items) |c| try flattenInto(allocator, c, &child_list);
        var sn = SemanticNode{
            .node = n,
            .role = sem.role,
            .label = if (sem.label.len > 0) sem.label else firstDescendantLabel(n) orelse "",
            .hint = sem.hint,
            .value = sem.value,
            .checked = sem.checked,
            .disabled = sem.disabled,
            .focusable = sem.focusable,
            .actions = sem.actions,
            .live = sem.live,
            .children = try child_list.toOwnedSlice(),
        };
        errdefer sn.deinit(allocator);
        try list.append(sn);
    } else {
        // Transparent container: lift its children into the current list.
        for (n.children.items) |c| try flattenInto(allocator, c, list);
    }
}

/// Build the semantic tree. When the root itself has no descriptor, the
/// result is a .group wrapper around the top-level semantic nodes. The
/// caller owns the tree (deinit).
pub fn buildSemanticTree(allocator: std.mem.Allocator, root: *Node) !SemanticNode {
    var list = std.array_list.Managed(SemanticNode).init(allocator);
    errdefer {
        for (list.items) |*sn| sn.deinit(allocator);
        list.deinit();
    }
    try flattenInto(allocator, root, &list);
    const items = try list.toOwnedSlice(); // exact-size owned slice
    if (items.len == 1) {
        const sn = items[0];
        allocator.free(items);
        return sn;
    }
    return .{
        .node = root,
        .role = .group,
        .label = "",
        .hint = "",
        .value = "",
        .checked = null,
        .disabled = false,
        .focusable = false,
        .actions = .{},
        .live = .off,
        .children = items,
    };
}

// --- Bridge (ADR-0009 C ABI) + live regions ---

pub const BridgeEvent = struct {
    pub const Kind = enum { tree_dirty, focus_changed, announce, control_changed };
    kind: Kind,
    node: ?*Node = null,
    text: []const u8 = "", // announce payload (borrowed during the call)
    region: LiveRegion = .off,
};

pub const SemanticsBridge = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, event: BridgeEvent) void,
    userdata: ?*anyopaque,
};

threadlocal var current_bridge: ?SemanticsBridge = null;

pub fn setBridge(b: ?SemanticsBridge) void {
    current_bridge = b;
}

pub fn bridge() ?SemanticsBridge {
    return current_bridge;
}

fn notifyBridge(ev: BridgeEvent) void {
    if (current_bridge) |b| b.fn_ptr(b.userdata, ev);
    if (bridge_c) |b| b.fn_ptr(b.userdata, .{
        .kind = @backingInt(ev.kind),
        .node_id = if (ev.node) |n| @intFromPtr(n) else 0,
        .text = ev.text.ptr,
        .text_len = ev.text.len,
        .region = @backingInt(ev.region),
    });
}

/// The extern event representation (ADR-0009 C boundary) + C-callable
/// registration for native bridges.
pub const BridgeEventC = extern struct {
    kind: u32, // BridgeEvent.Kind
    node_id: u64,
    text: [*]const u8,
    text_len: usize,
    region: u32, // LiveRegion
};

const BridgeC = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, event: BridgeEventC) callconv(.c) void,
    userdata: ?*anyopaque,
};

var bridge_c: ?BridgeC = null;

/// Install a C-callable bridge (extern event representation, ADR-0009).
pub fn setBridgeC(fn_ptr: ?*const fn (userdata: ?*anyopaque, event: BridgeEventC) callconv(.c) void, userdata: ?*anyopaque) void {
    bridge_c = if (fn_ptr) |f| .{ .fn_ptr = f, .userdata = userdata } else null;
}

/// The semantic tree changed (structure/layout) — bridges rebuild their view.
pub fn notifyTreeDirty() void {
    notifyBridge(.{ .kind = .tree_dirty });
}

/// Announce a dynamic change (live region) to the installed bridge.
pub fn announce(text: []const u8, region: LiveRegion) void {
    notifyBridge(.{ .kind = .announce, .text = text, .region = region });
}

/// A control's semantic value/checked changed (toggle, slider, ...) — bridges
/// refresh that node's value without a full tree rebuild.
pub fn notifyControlChanged(node: *Node) void {
    notifyBridge(.{ .kind = .control_changed, .node = node });
}

/// LogBridge: records every event (tests + the a11y demo). Install it with
/// `setBridge(lb.bridge())` — a11y never crashes the app.
pub const LogBridge = struct {
    allocator: std.mem.Allocator,
    events: std.array_list.Managed(LoggedEvent),

    pub const LoggedEvent = struct {
        kind: BridgeEvent.Kind,
        node_id: u64, // @intFromPtr(node) or 0
        text: []const u8, // owned
        region: LiveRegion,
    };

    pub fn init(allocator: std.mem.Allocator) !*LogBridge {
        const lb = try allocator.create(LogBridge);
        lb.* = .{
            .allocator = allocator,
            .events = std.array_list.Managed(LoggedEvent).init(allocator),
        };
        return lb;
    }

    pub fn deinit(lb: *LogBridge) void {
        for (lb.events.items) |e| lb.allocator.free(e.text);
        lb.events.deinit();
        lb.allocator.destroy(lb);
    }

    pub fn bridge(lb: *LogBridge) SemanticsBridge {
        return .{ .fn_ptr = logBridgeCb, .userdata = lb };
    }
};

fn logBridgeCb(userdata: ?*anyopaque, ev: BridgeEvent) void {
    const lb: *LogBridge = @ptrCast(@alignCast(userdata.?));
    lb.events.append(.{
        .kind = ev.kind,
        .node_id = if (ev.node) |n| @intFromPtr(n) else 0,
        .text = lb.allocator.dupe(u8, ev.text) catch @panic("klaxon: out of memory"),
        .region = ev.region,
    }) catch @panic("klaxon: out of memory");
}

// --- FocusManager (keyboard focus + focus ring) ---

/// The focus ring rect: the node's bounds expanded by `margin`; the ring
/// itself is painted on the ring rect's inner edge (ring_width thick).
fn ringRect(n: *Node, margin: f32) Rect {
    const r = n.mapRectToRoot(n.bounds);
    return .{ .x = r.x - margin, .y = r.y - margin, .w = r.w + 2 * margin, .h = r.h + 2 * margin };
}

pub const FocusManager = struct {
    allocator: std.mem.Allocator,
    root: ?*Node = null,
    focused: ?*Node = null,
    focused_sig: *state_mod.Signal(?*Node),
    ring_color: Color = 0x1C7ED6FF,
    ring_width: f32 = 2, // theme.platform.focus_ring_width
    ring_offset: f32 = 3, // theme.platform.focus_ring_offset

    pub fn init(allocator: std.mem.Allocator) !*FocusManager {
        const fm = try allocator.create(FocusManager);
        fm.* = .{
            .allocator = allocator,
            .focused_sig = try state_mod.Signal(?*Node).init(allocator, null),
        };
        return fm;
    }

    pub fn deinit(fm: *FocusManager) void {
        fm.focused_sig.deinit();
        fm.allocator.destroy(fm);
    }

    pub fn setRoot(fm: *FocusManager, root: *Node) void {
        fm.root = root;
    }

    /// The focusable nodes in semantic-tree order (freshly computed — the
    /// tree is retained, but subtrees come and go).
    pub fn focusOrder(fm: *FocusManager, allocator: std.mem.Allocator) ![]*Node {
        const root = fm.root orelse return &.{};
        var tree = try buildSemanticTree(allocator, root);
        defer tree.deinit(allocator);
        var list = std.array_list.Managed(*Node).init(allocator);
        errdefer list.deinit();
        try collectFocusable(&tree, &list);
        return list.toOwnedSlice();
    }

    fn collectFocusable(sn: *const SemanticNode, list: *std.array_list.Managed(*Node)) !void {
        if (sn.focusable) try list.append(sn.node);
        for (sn.children) |*c| try collectFocusable(c, list);
    }

    pub fn focusNode(fm: *FocusManager, node: ?*Node) void {
        fm.setFocused(node);
        input_mod.requestFocus(node); // the router delivers keys to the focused node
    }

    /// The input router's focus changed from outside (pointer click on a
    /// TextField, Escape blur) — sync the ring/signal/bridge without
    /// re-entering the router.
    pub fn onRouterFocusChanged(fm: *FocusManager, node: ?*Node) void {
        fm.setFocused(node);
    }

    fn setFocused(fm: *FocusManager, node: ?*Node) void {
        if (fm.focused == node) return;
        // Damage the old + new ring regions (mapped to window space) so the
        // host repaints exactly what the ring vacated/occupies.
        if (fm.root) |r| {
            if (fm.focused) |old| r.markDirtyRect(ringRect(old, fm.ring_offset));
            if (node) |new| r.markDirtyRect(ringRect(new, fm.ring_offset));
        }
        fm.focused = node;
        fm.focused_sig.set(node);
        if (node) |n| n.markDirty();
        notifyBridge(.{ .kind = .focus_changed, .node = node });
    }

    pub fn focusNext(fm: *FocusManager) void {
        const order = fm.focusOrder(fm.allocator) catch @panic("klaxon: out of memory");
        defer fm.allocator.free(order);
        if (order.len == 0) return;
        // No focus yet → start at the first node.
        const idx = indexOf(order, fm.focused) orelse order.len - 1;
        fm.focusNode(order[(idx + 1) % order.len]);
    }

    pub fn focusPrev(fm: *FocusManager) void {
        const order = fm.focusOrder(fm.allocator) catch @panic("klaxon: out of memory");
        defer fm.allocator.free(order);
        if (order.len == 0) return;
        const idx = indexOf(order, fm.focused) orelse 0;
        fm.focusNode(order[(idx + order.len - 1) % order.len]);
    }

    fn indexOf(order: []const *Node, node: ?*Node) ?usize {
        for (order, 0..) |n, i| {
            if (n == node) return i;
        }
        return null;
    }

    /// Keyboard handling for the focused node: Tab/Shift+Tab move the focus,
    /// Enter/Space activate (a synthesized click at the node's visual
    /// center). Returns true when the event was consumed. Other keys are
    /// left to the focused node (the router dispatches them first).
    pub fn handleKey(fm: *FocusManager, ev: input_mod.KeyEvent) bool {
        if (ev.kind != .key_down) return false;
        switch (ev.key) {
            .tab => {
                if (ev.shift) {
                    fm.focusPrev();
                } else {
                    fm.focusNext();
                }
                return true;
            },
            .enter, .space => {
                const n = fm.focused orelse return false;
                // Only nodes advertising the activate action are activated:
                // a slider has increment/decrement — a center click would
                // reset its value to 50%.
                const sem = n.semantics orelse return false;
                if (!sem.actions.contains(.activate)) return false;
                activateNode(fm, n);
                return true;
            },
            else => return false,
        }
    }

    /// Activate a node = synthesize down+up at its center, delivered straight
    /// to the node's own on_pointer (coordinates in the node's parent space,
    /// which is what on_pointer handlers compare against bounds). Bubbles up
    /// when the node has no pointer handler. Bypasses the router's hit-test
    /// on purpose: the deepest child (e.g. a Button's Text) would receive
    /// the event with child-local coordinates.
    fn activateNode(fm: *FocusManager, node: *Node) void {
        _ = fm;
        var n: ?*Node = node;
        while (n) |cur| {
            if (cur.vtable.on_pointer) |op| {
                const cx = cur.bounds.x + cur.bounds.w / 2;
                const cy = cur.bounds.y + cur.bounds.h / 2;
                _ = op(cur, .{ .phase = .down, .x = cx, .y = cy });
                _ = op(cur, .{ .phase = .up, .x = cx, .y = cy });
                return;
            }
            n = cur.parent;
        }
    }

    /// Paint the focus ring around the focused node (the host calls this
    /// after painting the tree). 4 fillRects — no stroke primitive needed.
    pub fn paintRing(fm: *FocusManager, ctx: *kx.Ctx) void {
        const n = fm.focused orelse return;
        const r = ringRect(n, fm.ring_offset);
        const w = fm.ring_width;
        const c = fm.ring_color;
        paint_mod.fillRect(ctx, r.x, r.y, r.w, w, c); // top
        paint_mod.fillRect(ctx, r.x, r.y + r.h - w, r.w, w, c); // bottom
        paint_mod.fillRect(ctx, r.x, r.y, w, r.h, c); // left
        paint_mod.fillRect(ctx, r.x + r.w - w, r.y, w, r.h, c); // right
    }
};

// --- process-global focus manager (single-window P0, like the router) ---

threadlocal var current_focus: ?*FocusManager = null;

pub fn setCurrentFocus(fm: ?*FocusManager) void {
    current_focus = fm;
}

pub fn currentFocus() ?*FocusManager {
    return current_focus;
}

/// A node is being destroyed (virtualization, navigation) — drop it from the
/// focus if it was focused (the pointer would dangle).
pub fn focusNodeDestroyed(node: *Node) void {
    if (current_focus) |fm| {
        if (fm.focused == node) fm.focusNode(null);
    }
}

/// The router's focus moved (pointer) — sync the process-global focus manager.
pub fn routerFocusChanged(node: ?*Node) void {
    if (current_focus) |fm| fm.onRouterFocusChanged(node);
}

// --- tests ---

// A leaf node with a fixed size + a click counter (stands in for a Button).
const ClickState = struct { clicks: u32 = 0 };

fn clickMeasure(n: *Node, c: layout_mod.Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = 100, .h = 40 });
}
fn clickLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn clickPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}
fn clickOnPointer(n: *Node, ev: input_mod.PointerEvent) bool {
    const s: *ClickState = @ptrCast(@alignCast(n.state.?));
    switch (ev.phase) {
        .down => return true,
        .up => {
            if (n.bounds.contains(ev.x, ev.y)) s.clicks += 1;
            return true;
        },
        else => {},
    }
    return false;
}
fn clickDeinit(n: *Node) void {
    n.allocator.destroy(@as(*ClickState, @ptrCast(@alignCast(n.state.?))));
}
const click_vtable = node_mod.VTable{
    .measure = clickMeasure,
    .layout = clickLayout,
    .paint = clickPaint,
    .deinit = clickDeinit,
    .on_pointer = clickOnPointer,
};

fn clickNode(allocator: std.mem.Allocator) !*Node {
    const node = try Node.create(allocator, &click_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(ClickState);
    errdefer allocator.destroy(s);
    s.* = .{};
    node.state = s;
    return node;
}

fn countFired(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "semantic tree: flatten, label fallback, exclude_semantics, nesting" {
    const a = std.testing.allocator;
    const root = try clickNode(a); // transparent container (no semantics)
    defer root.deinit();
    const hello = try clickNode(a);
    attach(hello, .{ .role = .text, .label = "Hello" });
    root.add(hello);
    const btn = try clickNode(a);
    attach(btn, .{ .role = .button, .focusable = true, .actions = Actions.initOne(.activate) });
    root.add(btn);
    const submit = try clickNode(a);
    attach(submit, .{ .role = .text, .label = "Submit" });
    btn.add(submit); // the button's label falls back to its Text child
    const hidden = try clickNode(a);
    attach(hidden, .{ .role = .text, .label = "Hidden" });
    hidden.exclude_semantics = true;
    root.add(hidden);
    const list = try clickNode(a);
    attach(list, .{ .role = .list });
    root.add(list);
    const item = try clickNode(a);
    attach(item, .{ .role = .list_item, .label = "One" });
    list.add(item);

    var tree = try buildSemanticTree(a, root);
    defer tree.deinit(a);
    try std.testing.expectEqual(Role.group, tree.role);
    try std.testing.expectEqual(@as(usize, 3), tree.children.len); // hello, btn, list (hidden excluded)
    try std.testing.expectEqual(Role.text, tree.children[0].role);
    try std.testing.expectEqualStrings("Hello", tree.children[0].label);
    try std.testing.expectEqual(Role.button, tree.children[1].role);
    try std.testing.expectEqualStrings("Submit", tree.children[1].label); // fallback
    try std.testing.expect(tree.children[1].focusable);
    try std.testing.expect(tree.children[1].actions.contains(.activate));
    try std.testing.expectEqual(Role.list, tree.children[2].role);
    try std.testing.expectEqual(@as(usize, 1), tree.children[2].children.len);
    try std.testing.expectEqual(Role.list_item, tree.children[2].children[0].role);
}

test "focus order: next/prev wrap around the semantic tree" {
    const a = std.testing.allocator;
    const root = try clickNode(a);
    defer root.deinit();
    const first = try clickNode(a);
    attach(first, .{ .role = .button, .focusable = true });
    root.add(first);
    const plain = try clickNode(a); // not focusable
    root.add(plain);
    const second = try clickNode(a);
    attach(second, .{ .role = .toggle, .focusable = true, .checked = false });
    root.add(second);

    const fm = try FocusManager.init(a);
    defer fm.deinit();
    fm.setRoot(root);

    const order = try fm.focusOrder(a);
    defer a.free(order);
    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expect(order[0] == first and order[1] == second);

    fm.focusNext();
    try std.testing.expect(fm.focused == first);
    fm.focusNext();
    try std.testing.expect(fm.focused == second);
    fm.focusNext(); // wraps
    try std.testing.expect(fm.focused == first);
    fm.focusPrev(); // wraps back
    try std.testing.expect(fm.focused == second);
}

test "focusNode: signal fires, router focuses, bridge notified" {
    const a = std.testing.allocator;
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    const lb = try LogBridge.init(a);
    defer lb.deinit();
    setBridge(lb.bridge());
    defer setBridge(null);

    const root = try clickNode(a);
    defer root.deinit();
    const node = try clickNode(a);
    attach(node, .{ .role = .button, .focusable = true });
    root.add(node);

    const fm = try FocusManager.init(a);
    defer fm.deinit();
    fm.setRoot(root);
    var sig_fired: u32 = 0;
    fm.focused_sig.subscribe(.{ .callback = .{ .fn_ptr = countFired, .userdata = &sig_fired } });

    fm.focusNode(node);
    try std.testing.expectEqual(@as(u32, 1), sig_fired);
    try std.testing.expect(router.focused == node);
    try std.testing.expectEqual(@as(usize, 1), lb.events.items.len);
    try std.testing.expectEqual(BridgeEvent.Kind.focus_changed, lb.events.items[0].kind);
    try std.testing.expectEqual(@intFromPtr(node), lb.events.items[0].node_id);
    fm.focusNode(node); // no-op: no signal, no event
    try std.testing.expectEqual(@as(u32, 1), sig_fired);
    try std.testing.expectEqual(@as(usize, 1), lb.events.items.len);
    fm.focusNode(null);
    try std.testing.expectEqual(@as(u32, 2), sig_fired);
    try std.testing.expect(router.focused == null);
}

test "handleKey: tab moves focus, enter/space activate (synthesized click)" {
    const a = std.testing.allocator;
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);

    const root = try clickNode(a); // the root IS the button (no parent transforms)
    defer root.deinit();
    attach(root, .{ .role = .button, .focusable = true, .actions = Actions.initOne(.activate) });
    root.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    const clicks = &@as(*ClickState, @ptrCast(@alignCast(root.state.?))).clicks;

    const fm = try FocusManager.init(a);
    defer fm.deinit();
    fm.setRoot(root);
    fm.focusNode(root);
    try std.testing.expectEqual(@as(u32, 0), clicks.*);

    // Tab with a single focusable wraps onto itself.
    try std.testing.expect(fm.handleKey(.{ .kind = .key_down, .key = .tab }));
    try std.testing.expect(fm.focused == root);
    try std.testing.expect(fm.handleKey(.{ .kind = .key_down, .key = .tab, .shift = true }));
    try std.testing.expect(fm.focused == root);

    // Enter/Space activate: a synthesized click at the visual center.
    try std.testing.expect(fm.handleKey(.{ .kind = .key_down, .key = .enter }));
    try std.testing.expectEqual(@as(u32, 1), clicks.*);
    try std.testing.expect(fm.handleKey(.{ .kind = .key_down, .key = .space }));
    try std.testing.expectEqual(@as(u32, 2), clicks.*);

    // Other keys are not consumed by the focus manager (the node's on_key
    // gets them first via the router).
    try std.testing.expect(!fm.handleKey(.{ .kind = .key_down, .key = .left }));
    try std.testing.expect(!fm.handleKey(.{ .kind = .text_input, .text = "x" }));
}

test "announce + LogBridge records live-region events" {
    const a = std.testing.allocator;
    const lb = try LogBridge.init(a);
    defer lb.deinit();
    setBridge(lb.bridge());
    defer setBridge(null);
    announce("3 items added", .polite);
    notifyTreeDirty();
    try std.testing.expectEqual(@as(usize, 2), lb.events.items.len);
    try std.testing.expectEqual(BridgeEvent.Kind.announce, lb.events.items[0].kind);
    try std.testing.expectEqualStrings("3 items added", lb.events.items[0].text);
    try std.testing.expectEqual(LiveRegion.polite, lb.events.items[0].region);
    try std.testing.expectEqual(BridgeEvent.Kind.tree_dirty, lb.events.items[1].kind);
}

test "focusNodeDestroyed: a destroyed focused node is dropped" {
    const a = std.testing.allocator;
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    const root = try clickNode(a);
    defer root.deinit();
    const node = try clickNode(a);
    attach(node, .{ .role = .button, .focusable = true });
    root.add(node);
    const fm = try FocusManager.init(a);
    defer fm.deinit();
    setCurrentFocus(fm);
    defer setCurrentFocus(null);
    fm.setRoot(root);
    fm.focusNode(node);
    try std.testing.expect(fm.focused == node);
    _ = root.remove(node);
    node.deinit(); // → focusNodeDestroyed → focus dropped
    try std.testing.expect(fm.focused == null);
    try std.testing.expect(router.focused == null);
}

test "routerFocusChanged: pointer focus syncs the focus manager" {
    const a = std.testing.allocator;
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    const root = try clickNode(a);
    defer root.deinit();
    const node = try clickNode(a);
    attach(node, .{ .role = .text_field, .focusable = true });
    root.add(node);
    const fm = try FocusManager.init(a);
    defer fm.deinit();
    setCurrentFocus(fm);
    defer setCurrentFocus(null);
    fm.setRoot(root);
    input_mod.requestFocus(node); // pointer path (TextField click)
    try std.testing.expect(fm.focused == node);
    try std.testing.expect(router.focused == node);
    input_mod.requestFocus(null); // Escape blur
    try std.testing.expect(fm.focused == null);
}

test "handleKey: enter/space activate only nodes advertising .activate" {
    const a = std.testing.allocator;
    const root = try clickNode(a); // no activate action — like a slider
    defer root.deinit();
    attach(root, .{ .role = .slider, .focusable = true, .actions = Actions.init(.{ .increment = true, .decrement = true }) });
    root.layout(.{ .x = 10, .y = 10, .w = 100, .h = 40 });
    const clicks = &@as(*ClickState, @ptrCast(@alignCast(root.state.?))).clicks;
    const fm = try FocusManager.init(a);
    defer fm.deinit();
    fm.setRoot(root);
    fm.focusNode(root);
    try std.testing.expect(!fm.handleKey(.{ .kind = .key_down, .key = .enter }));
    try std.testing.expectEqual(@as(u32, 0), clicks.*); // the pointer handler never ran
    // A node WITH .activate is activated.
    attach(root, .{ .role = .button, .focusable = true, .actions = Actions.initOne(.activate) });
    try std.testing.expect(fm.handleKey(.{ .kind = .key_down, .key = .space }));
    try std.testing.expectEqual(@as(u32, 1), clicks.*);
}

const CRec = struct {
    count: u32 = 0,
    last_kind: u32 = 0,
    last_region: u32 = 0,
    last_text: [64]u8 = undefined,
    last_text_len: usize = 0,
};

fn cCb(userdata: ?*anyopaque, ev: BridgeEventC) callconv(.c) void {
    const r: *CRec = @ptrCast(@alignCast(userdata.?));
    r.count += 1;
    r.last_kind = ev.kind;
    r.last_region = ev.region;
    const n = @min(ev.text_len, r.last_text.len);
    @memcpy(r.last_text[0..n], ev.text[0..n]);
    r.last_text_len = n;
}

test "setBridgeC: the C-callable bridge receives extern events" {
    var rec = CRec{};
    setBridgeC(cCb, &rec);
    defer setBridgeC(null, null);
    announce("hi", .assertive);
    try std.testing.expectEqual(@as(u32, 1), rec.count);
    try std.testing.expectEqual(@backingInt(BridgeEvent.Kind.announce), rec.last_kind);
    try std.testing.expectEqual(@backingInt(LiveRegion.assertive), rec.last_region);
    try std.testing.expectEqual(@as(usize, 2), rec.last_text_len);
    try std.testing.expectEqualStrings("hi", rec.last_text[0..rec.last_text_len]);
}

test "golden: focus ring paints around the focused node (exact pixels)" {
    const a = std.testing.allocator;
    const bg: Color = 0x000000FF;
    const ring: Color = 0x1C7ED6FF;
    const box: Color = 0xFF0000FF;
    const root = try golden.solidBox(a, 40, 20, box);
    defer root.deinit();
    const fm = try FocusManager.init(a);
    defer fm.deinit();
    fm.ring_color = ring;
    fm.setRoot(root);
    root.layout(.{ .x = 20, .y = 20, .w = 40, .h = 20 });
    var r = try golden.Renderer.init(a, 128, 64);
    defer r.deinit();

    // No focus → no ring.
    r.paint(root, bg);
    var f1 = try r.readback(a);
    defer f1.deinit();
    try std.testing.expectEqual(@as(u64, 0), f1.countColor(ring));

    // Focused → ring around the box (bounds 20,20,40,20 → ring rect 17,17,46,26).
    // The ring paints INSIDE the frame (the host paints it before end_frame).
    fm.focusNode(root);
    kx.c.kx_begin_frame(r.ctx);
    kx.c.kx_clear(r.ctx, bg);
    root.paint(r.ctx);
    fm.paintRing(r.ctx);
    kx.c.kx_end_frame(r.ctx);
    var f2 = try r.readback(a);
    defer f2.deinit();
    try std.testing.expect(f2.countColor(ring) > 0);
    try std.testing.expectEqual(ring, f2.pixelAt(18, 30)); // left bar (x 17..19)
    try std.testing.expectEqual(ring, f2.pixelAt(40, 18)); // top bar (y 17..19)
    try std.testing.expectEqual(box, f2.pixelAt(40, 30)); // center: the box, not the ring
}

test "focus ring: the offset expands the bounds; the tokens carry width + offset" {
    const n = try clickNode(std.testing.allocator);
    defer n.deinit();
    n.layout(.{ .x = 10, .y = 20, .w = 30, .h = 40 });
    const r = ringRect(n, 4);
    try std.testing.expectEqual(@as(f32, 6), r.x);
    try std.testing.expectEqual(@as(f32, 16), r.y);
    try std.testing.expectEqual(@as(f32, 38), r.w);
    try std.testing.expectEqual(@as(f32, 48), r.h);
    // the FocusManager carries the tokens (mobile defaults)
    const fm = try FocusManager.init(std.testing.allocator);
    defer fm.deinit();
    try std.testing.expectEqual(@as(f32, 2), fm.ring_width);
    try std.testing.expectEqual(@as(f32, 3), fm.ring_offset);
}
