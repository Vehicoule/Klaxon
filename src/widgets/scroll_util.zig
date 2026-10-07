// Scroll widget internals (Phase 1f) — shared by ListView, GridView and
// ScrollView. Not a widget module (no exports in widgets.zig).
//
//   ItemFactory    — creates one item node per index (ADR-0009: fn ptr + userdata)
//   ScrollInput    — drag-to-scroll + wheel handlers (embedded in widget state)
//   syncItemWindow — the virtualization diff: trims items that left the
//                    visible window, creates the ones that entered
const std = @import("std");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const scroll_mod = @import("../ui/scroll.zig");

const Node = ui.node.Node;

/// Creates one item node for `index`. OOM inside the factory is fatal (same
/// convention as Node.add).
pub const ItemFactory = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, index: usize) *Node,
    userdata: ?*anyopaque,
};

/// Drag-to-scroll + wheel input, embedded in a scrollable's state.
///
/// Drag: .move events reach the scrollable by bubbling (items consume
/// down/up for taps but not moves). A move only scrolls while the router
/// has a capture for the pointer (a real drag — hover moves never scroll).
/// Each pointer has its own track (down/hover/drag positions) so concurrent
/// fingers never jump the content, and a new drag starts without a jump.
/// Tracks live in window space (raw_*): the delta is physical finger
/// motion — the content scrolling under a held finger must not cancel it.
///
/// `set_offset` is the widget's apply function: it clamps, shifts the
/// virtualization window and marks the node dirty — and returns whether the
/// offset changed.
pub const ScrollInput = struct {
    pub const MAX_TRACKS = 8; // matches input.MAX_POINTERS
    /// y is window-space (raw_y) — see the struct doc above.
    const Track = struct { pointer: u64 = 0, y: f32 = 0, active: bool = false };
    tracks: [MAX_TRACKS]Track = std.mem.zeroes([MAX_TRACKS]Track),

    pub const SetOffset = *const fn (n: *Node, value: f32) bool;

    fn trackFor(inp: *ScrollInput, pointer: u64) *Track {
        for (&inp.tracks) |*t| {
            if (t.active and t.pointer == pointer) return t;
        }
        for (&inp.tracks) |*t| {
            if (!t.active) return t;
        }
        return &inp.tracks[0]; // full: reuse slot 0 (P0)
    }

    fn releaseTrack(inp: *ScrollInput, pointer: u64) void {
        for (&inp.tracks) |*t| {
            if (t.active and t.pointer == pointer) t.active = false;
        }
    }

    /// Call from the widget's on_pointer.
    pub fn onPointer(inp: *ScrollInput, ev: input.PointerEvent, scroll: *scroll_mod.ScrollState, set_offset: SetOffset, n: *Node) bool {
        switch (ev.phase) {
            .down => {
                const t = inp.trackFor(ev.pointer);
                t.* = .{ .pointer = ev.pointer, .y = ev.raw_y, .active = true };
                return false; // items handle taps
            },
            .up, .outside_down => {
                inp.releaseTrack(ev.pointer);
                return false;
            },
            .move => {},
            else => return false,
        }
        const router = input.current() orelse return false;
        const dragging = router.capturedNode(ev.pointer) != null;
        const t = inp.trackFor(ev.pointer);
        const last = if (t.active and t.pointer == ev.pointer) t.y else ev.raw_y;
        t.* = .{ .pointer = ev.pointer, .y = ev.raw_y, .active = true };
        if (!dragging) return false; // hover move: no scroll
        const dy = ev.raw_y - last;
        if (dy == 0) return false;
        // The finger drags the content: moving up (dy < 0) increases the offset.
        return set_offset(n, scroll.offset - dy);
    }

    /// Call from the widget's on_scroll (wheel). Positive delta_y = scroll
    /// up = offset decreases.
    pub fn onScroll(inp: *ScrollInput, ev: input.ScrollEvent, scroll: *scroll_mod.ScrollState, wheel_speed: f32, set_offset: SetOffset, n: *Node) bool {
        _ = inp;
        if (!scroll.info().canScroll()) return false;
        return set_offset(n, scroll.offset - ev.delta_y * wheel_speed);
    }
};

/// The virtualization diff: children[0] is item `first`; the window is
/// [range.first, range.last). Trims items that left (front then back),
/// creates the ones that entered (front then back), laying out each new
/// child at its content position via `layout_item`.
pub fn syncItemWindow(
    n: *Node,
    first: *usize,
    factory: ItemFactory,
    range: scroll_mod.Range,
    layout_item: *const fn (n: *Node, child: *Node, index: usize) void,
) void {
    // Non-overlapping windows (or an empty window): drop everything and
    // re-anchor — a large jump must NOT materialize the intervening items.
    const old_last = first.* + n.children.items.len;
    const overlaps = first.* < range.last and range.first < old_last;
    if (!overlaps) {
        for (n.children.items) |child| child.deinit();
        n.children.clearRetainingCapacity();
        first.* = range.first;
    }
    // Trim items that left the window (front): destroy the child and
    // advance `first` — advancing continues past an empty window (the
    // children were never created or are already gone).
    while (first.* < range.first) {
        if (n.children.items.len > 0) {
            const child = n.children.items[0];
            _ = n.children.orderedRemove(0);
            child.deinit();
        }
        first.* += 1;
    }
    // Trim items that left the window (back).
    while (first.* + n.children.items.len > range.last and n.children.items.len > 0) {
        const last = n.children.items.len - 1;
        const child = n.children.items[last];
        _ = n.children.orderedRemove(last);
        child.deinit();
    }
    // Items entering at the front (scrolled up): prepend.
    while (first.* > range.first) {
        first.* -= 1;
        const node = factory.fn_ptr(factory.userdata, first.*);
        n.children.insert(0, node) catch @panic("klaxon: out of memory");
        node.parent = n;
        layout_item(n, node, first.*);
    }
    // Items entering at the back (scrolled down): append.
    while (first.* + n.children.items.len < range.last) {
        const index = first.* + n.children.items.len;
        const node = factory.fn_ptr(factory.userdata, index);
        n.add(node); // sets parent + marks dirty
        layout_item(n, node, index);
    }
}
