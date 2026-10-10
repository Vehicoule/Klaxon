// a11y_bridge.zig — Zig side of the macOS NSAccessibility bridge (Phase 3a).
//
// Exposes C-callable functions consumed by kx_a11y_macos.mm:
//   - kx_a11y_set_bridge: registers the C bridge callback (wraps setBridgeC)
//   - kx_a11y_dump_tree: serializes the semantic tree to a flat text dump
//   - kx_a11y_free_string: frees a string allocated by kx_a11y_dump_tree
//
// The dump format (one line per visible semantic node):
//   "depth|role|label|value|focusable|x|y|w|h\n"
// depth is the indentation level (0 = root). The macOS bridge parses this
// to build the NSAccessibility hierarchy.
const std = @import("std");
const ui = @import("ui.zig");
const Node = ui.node.Node;
const sem = ui.semantics;

const c = @import("kx.zig").c;

/// Install (or clear) the C bridge callback. Wraps semantics.setBridgeC.
export fn kx_a11y_set_bridge(
    fn_ptr: ?*const fn (userdata: ?*anyopaque, event: sem.BridgeEventC) callconv(.c) void,
    userdata: ?*anyopaque,
) void {
    sem.setBridgeC(fn_ptr, userdata);
}

/// Serialize the semantic tree to a flat text dump. Returns a malloc'd
/// C string (caller must free with kx_a11y_free_string) or null on error.
export fn kx_a11y_dump_tree(root_node: ?*anyopaque) callconv(.c) ?[*]u8 {
    const root: *Node = @ptrCast(@alignCast(root_node orelse return null));
    var tree = sem.buildSemanticTree(std.heap.c_allocator, root) catch return null;
    defer tree.deinit(std.heap.c_allocator);

    var buf = std.array_list.Managed(u8).init(std.heap.c_allocator);
    defer buf.deinit();
    dumpNode(&tree, 0, &buf) catch return null;

    // Null-terminate.
    buf.append(0) catch return null;
    const result: [*]u8 = buf.items.ptr;
    return result;
}

/// Free a string allocated by kx_a11y_dump_tree.
export fn kx_a11y_free_string(s: ?[*]u8) callconv(.c) void {
    if (s) |ptr| {
        // Find the length (null-terminated).
        var len: usize = 0;
        while (ptr[len] != 0) : (len += 1) {}
        std.heap.c_allocator.free(ptr[0..len :0]);
    }
}

fn dumpNode(sn: *sem.SemanticNode, depth: usize, buf: *std.array_list.Managed(u8)) !void {
    // Format: "depth|role|label|value|focusable|x|y|w|h\n"
    const role_str = @tagName(sn.role);
    const label = if (sn.label.len > 0) sn.label else "";
    const value = if (sn.value.len > 0) sn.value else "";
    const focusable: u8 = if (sn.focusable) 1 else 0;

    var line_buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{d}|{s}|{s}|{s}|{d}|0|0|0|0\n", .{
        depth, role_str, label, value, focusable,
    }) catch return;
    try buf.appendSlice(line);

    for (sn.children) |*child| {
        try dumpNode(child, depth + 1, buf);
    }
}
