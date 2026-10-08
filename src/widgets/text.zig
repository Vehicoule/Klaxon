// Text widgets (Phase 1b P0) — Text (single line) and RichText (styled spans).
// Metrics come from the kx_skia ABI (kx_measure_text — real font metrics, not
// approximations). Shaped text / ellipsis / overflow land with SkParagraph later.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const TextAlign = ui.layout.TextAlign;
const Color = ui.paint.Color;

pub const TextOptions = struct {
    size: f32 = 16,
    color: Color = 0x000000FF, // opaque black (0xRRGGBBAA)
    bold: bool = false,
    text_align: TextAlign = .left, // named text_align — `align` is a Zig keyword
};

const TextState = struct {
    text: [:0]const u8, // owned, null-terminated
    opts: TextOptions,
};

fn textMeasure(n: *Node, c: Constraints) Size {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    const m = ui.paint.measureText(s.text, s.opts.size, s.opts.bold);
    return c.constrain(.{ .w = m.width, .h = m.height });
}
fn textLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: bounds come from the parent
}
/// The text's x for an alignment (start/end resolve against the current
/// text direction — Phase 2b).
fn textX(n: *Node, m: ui.paint.TextMetrics, text_align: ui.layout.TextAlign) f32 {
    const resolved = ui.layout.resolveAlign(text_align, ui.i18n.direction());
    return switch (resolved) {
        .left => n.bounds.x,
        .center => n.bounds.x + (n.bounds.w - m.width) / 2,
        .right => n.bounds.x + n.bounds.w - m.width,
        .start, .end => unreachable, // resolved above
    };
}

fn textPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    const m = ui.paint.measureText(s.text, s.opts.size, s.opts.bold);
    const x = textX(n, m, s.opts.text_align);
    // Skia draws from the baseline: one ascent below the top.
    ui.paint.text(ctx, s.text, x, n.bounds.y + m.ascent, s.opts.size, s.opts.bold, s.opts.color);
}
fn textDeinit(n: *Node) void {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    n.allocator.free(s.text);
    n.allocator.destroy(s);
}
const text_vtable = ui.node.VTable{ .measure = textMeasure, .layout = textLayout, .paint = textPaint, .deinit = textDeinit };

pub fn text(allocator: std.mem.Allocator, str: []const u8, opts: TextOptions) !*Node {
    const node = try Node.create(allocator, &text_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(TextState);
    errdefer allocator.destroy(s);
    const buf = try allocator.alloc(u8, str.len + 1);
    errdefer allocator.free(buf);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    s.* = .{ .text = buf[0..str.len :0], .opts = opts };
    node.state = s;
    ui.semantics.attach(node, .{ .role = .text, .label = s.text }); // Phase 2c
    return node;
}

// --- BoundText: a Text whose string follows a signal ---

/// Text bound to a signal: the string is `fmt(sig.peek())`, reformatted and
/// re-measured on every change (the size may change → markLayoutDirty, not
/// just markDirty). `fmt` writes into the provided buffer and returns the
/// slice used (the widget appends the null sentinel).
pub fn BoundText(comptime T: type) type {
    return struct {
        const State = struct {
            sig: *ui.state.Signal(T),
            fmt: *const fn (T, []u8) []const u8,
            opts: TextOptions,
            buf: [128]u8 = undefined,
        };

        fn bound(n: *Node) [:0]const u8 {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            const out = s.fmt(s.sig.peek(), &s.buf);
            const len = @min(out.len, s.buf.len - 1);
            s.buf[len] = 0;
            return s.buf[0..len :0];
        }

        fn measure(n: *Node, c: Constraints) Size {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            const m = ui.paint.measureText(bound(n), s.opts.size, s.opts.bold);
            return c.constrain(.{ .w = m.width, .h = m.height });
        }
        fn layout(n: *Node, bounds: Rect) void {
            _ = n;
            _ = bounds; // leaf: bounds come from the parent
        }
        fn paint(n: *Node, ctx: *kx.Ctx) void {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            const str = bound(n);
            const m = ui.paint.measureText(str, s.opts.size, s.opts.bold);
            const x = textX(n, m, s.opts.text_align);
            ui.paint.text(ctx, str, x, n.bounds.y + m.ascent, s.opts.size, s.opts.bold, s.opts.color);
        }
        fn dirtyCb(userdata: ?*anyopaque) void {
            const n: *Node = @ptrCast(@alignCast(userdata.?));
            if (n.semantics) |sem| sem.label = bound(n); // a11y: the label follows the signal
            n.markLayoutDirty(); // the text (and its size) changed
            n.markDirty(); // wake the dirty-flag render path (idle repaint)
        }
        fn deinit(n: *Node) void {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = dirtyCb, .userdata = n } });
            n.allocator.destroy(s);
        }
        const vtable = ui.node.VTable{ .measure = measure, .layout = layout, .paint = paint, .deinit = deinit };

        pub fn text(allocator: std.mem.Allocator, sig: *ui.state.Signal(T), fmt: *const fn (T, []u8) []const u8, opts: TextOptions) !*Node {
            const node = try Node.create(allocator, &vtable);
            errdefer node.allocator.destroy(node); // no state yet
            const s = try allocator.create(State);
            errdefer allocator.destroy(s);
            s.* = .{ .sig = sig, .fmt = fmt, .opts = opts };
            node.state = s;
            // Phase 2c: the label is the initial text — dynamic changes go
            // through live regions (semantics.announce).
            ui.semantics.attach(node, .{ .role = .text, .label = bound(node) });
            sig.subscribe(.{ .callback = .{ .fn_ptr = dirtyCb, .userdata = node } });
            return node;
        }
    };
}

// --- RichText ---

pub const TextSpan = struct {
    text: []const u8,
    size: f32 = 16,
    color: Color = 0x000000FF, // opaque black (0xRRGGBBAA)
    bold: bool = false,
};

const SpanState = struct {
    text: [:0]const u8, // owned, null-terminated
    size: f32,
    color: Color,
    bold: bool,
};

const RichTextState = struct {
    spans: std.array_list.Managed(SpanState),
};

fn richTextMeasure(n: *Node, c: Constraints) Size {
    const s: *RichTextState = @ptrCast(@alignCast(n.state.?));
    var w: f32 = 0;
    var h: f32 = 0;
    for (s.spans.items) |span| {
        const m = ui.paint.measureText(span.text, span.size, span.bold);
        w += m.width;
        h = @max(h, m.height);
    }
    return c.constrain(.{ .w = w, .h = h });
}
fn richTextLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn richTextPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *RichTextState = @ptrCast(@alignCast(n.state.?));
    // Shared baseline: the tallest span's ascent.
    var ascent: f32 = 0;
    for (s.spans.items) |span| {
        const m = ui.paint.measureText(span.text, span.size, span.bold);
        ascent = @max(ascent, m.ascent);
    }
    const baseline = n.bounds.y + ascent;
    var x = n.bounds.x;
    for (s.spans.items) |span| {
        const m = ui.paint.measureText(span.text, span.size, span.bold);
        ui.paint.text(ctx, span.text, x, baseline, span.size, span.bold, span.color);
        x += m.width;
    }
}
fn richTextDeinit(n: *Node) void {
    const s: *RichTextState = @ptrCast(@alignCast(n.state.?));
    for (s.spans.items) |span| n.allocator.free(span.text);
    s.spans.deinit();
    n.allocator.destroy(s);
}
const rich_text_vtable = ui.node.VTable{ .measure = richTextMeasure, .layout = richTextLayout, .paint = richTextPaint, .deinit = richTextDeinit };

/// RichText — a single line of styled spans. Copies the span strings.
/// Error-safe: spans are copied first; on failure everything is freed.
pub fn richText(allocator: std.mem.Allocator, spans: []const TextSpan) !*Node {
    var owned = std.array_list.Managed(SpanState).init(allocator);
    errdefer {
        for (owned.items) |span| allocator.free(span.text);
        owned.deinit();
    }
    for (spans) |span| {
        const buf = try allocator.alloc(u8, span.text.len + 1);
        @memcpy(buf[0..span.text.len], span.text);
        buf[span.text.len] = 0;
        owned.append(.{
            .text = buf[0..span.text.len :0],
            .size = span.size,
            .color = span.color,
            .bold = span.bold,
        }) catch {
            allocator.free(buf);
            return error.OutOfMemory;
        };
    }
    const node = try Node.create(allocator, &rich_text_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(RichTextState);
    errdefer allocator.destroy(s);
    s.* = .{ .spans = owned }; // moves the list (no fallible ops after this)
    node.state = s;
    return node;
}

// --- tests ---

test "text measure uses real font metrics" {
    const t = try text(std.testing.allocator, "Hi", .{ .size = 24 });
    defer t.deinit();
    const size = t.measure(.{});
    try std.testing.expect(size.w > 0);
    try std.testing.expect(size.h > 0);
    // Height tracks the font size (ascent + descent).
    try std.testing.expect(size.h > 24 * 0.8);
    try std.testing.expect(size.h < 24 * 2);
    // Longer strings measure wider (monotonic, font-agnostic).
    const long = try text(std.testing.allocator, "Hi Hi Hi Hi", .{ .size = 24 });
    defer long.deinit();
    try std.testing.expect(long.measure(.{}).w > size.w);
}

test "rich text measure sums span widths, max height" {
    const rt = try richText(std.testing.allocator, &.{
        .{ .text = "Hello ", .size = 16, .color = 0xFFFFFFFF },
        .{ .text = "world", .size = 32, .color = 0xFF0000FF, .bold = true },
    });
    defer rt.deinit();
    const single = try text(std.testing.allocator, "Hello ", .{ .size = 16 });
    defer single.deinit();
    const world = try text(std.testing.allocator, "world", .{ .size = 32, .bold = true });
    defer world.deinit();
    const size = rt.measure(.{});
    const expected_w = single.measure(.{}).w + world.measure(.{}).w;
    try std.testing.expectApproxEqAbs(expected_w, size.w, 0.001);
    try std.testing.expectApproxEqAbs(world.measure(.{}).h, size.h, 0.001);
}

test "golden: text renders ink inside its bounds, none outside" {
    const bg = 0x101010FF;
    const white = 0xFFFFFFFF;
    const root = try text(std.testing.allocator, "Hi", .{ .size = 24, .color = white });
    var frame = try golden.render(std.testing.allocator, root, 128, 64, bg);
    defer frame.deinit();
    const m = ui.paint.measureText("Hi", 24, false);
    try std.testing.expect(m.width > 0); // requires fonts (CI runners have them)
    const ink = frame.countNotIn(.{ .x = 0, .y = 0, .w = m.width, .h = 64 }, bg);
    try std.testing.expect(ink > 0);
    // Right of the text: pure background.
    const margin_x = @as(i32, @intFromFloat(m.width)) + 4;
    try std.testing.expectEqual(@as(u64, 0), frame.countNotIn(.{
        .x = @floatFromInt(margin_x),
        .y = 0,
        .w = @floatFromInt(128 - margin_x),
        .h = 64,
    }, bg));
}

test "golden: rich text paints both spans" {
    const bg = 0x101010FF;
    const white = 0xFFFFFFFF;
    const red = 0xFF0000FF;
    const rt = try richText(std.testing.allocator, &.{
        .{ .text = "ab", .size = 24, .color = white },
        .{ .text = "cd", .size = 24, .color = red },
    });
    var frame = try golden.render(std.testing.allocator, rt, 128, 64, bg);
    defer frame.deinit();
    // White and red ink are both present (AA blends differ per span color).
    try std.testing.expect(frame.countNot(bg) > 0);
    try std.testing.expect(frame.countColor(white) > 0);
    try std.testing.expect(frame.countColor(red) > 0);
}

fn fmtBoundCount(v: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "Pressed {d} times", .{v}) catch "Pressed";
}

test "boundText: follows the signal and re-layouts on change" {
    const sig = try ui.state.Signal(u32).init(std.testing.allocator, 1);
    defer sig.deinit();
    const node = try BoundText(u32).text(std.testing.allocator, sig, fmtBoundCount, .{ .size = 16, .color = 0xFFFFFFFF });
    defer node.deinit();
    const m1 = ui.paint.measureText("Pressed 1 times", 16, false);
    const s1 = node.measure(.{ .max_w = 400, .max_h = 20 });
    try std.testing.expectApproxEqAbs(m1.width, s1.w, 0.01);
    try std.testing.expectApproxEqAbs(m1.height, s1.h, 0.01);
    node.layout_dirty = false;
    node.dirty = false;
    sig.set(12345); // value changed → the node must re-layout (size changes)
    try std.testing.expect(node.layout_dirty);
    try std.testing.expect(node.dirty); // and repaint (idle host renders only when dirty)
    const m2 = ui.paint.measureText("Pressed 12345 times", 16, false);
    const s2 = node.measure(.{ .max_w = 400, .max_h = 20 });
    try std.testing.expectApproxEqAbs(m2.width, s2.w, 0.01);
    // no-op set: no re-layout
    node.layout_dirty = false;
    sig.set(12345);
    try std.testing.expect(!node.layout_dirty);
}

test "golden: boundText paints the current signal value" {
    const bg = 0x101010FF;
    const white = 0xFFFFFFFF;
    const sig = try ui.state.Signal(u32).init(std.testing.allocator, 7);
    defer sig.deinit();
    // Deinit order: the tree BEFORE the renderer (ctx-bound resources rule).
    var r = try golden.Renderer.init(std.testing.allocator, 384, 64);
    defer r.deinit(); // runs LAST
    const root = try BoundText(u32).text(std.testing.allocator, sig, fmtBoundCount, .{ .size = 24, .color = white });
    defer root.deinit(); // runs FIRST (LIFO)
    root.layout(.{ .x = 0, .y = 0, .w = 384, .h = 64 });
    r.paint(root, bg);
    var frame = try r.readback(std.testing.allocator);
    defer frame.deinit();
    const m = ui.paint.measureText("Pressed 7 times", 24, false);
    try std.testing.expect(frame.countNotIn(.{ .x = 0, .y = 0, .w = m.width, .h = 64 }, bg) > 0);
    // after a change + relayout + repaint, the wider string paints wider ink
    sig.set(100000);
    root.layout(.{ .x = 0, .y = 0, .w = 384, .h = 64 });
    r.paint(root, bg);
    var frame2 = try r.readback(std.testing.allocator);
    defer frame2.deinit();
    const m2 = ui.paint.measureText("Pressed 100000 times", 24, false);
    try std.testing.expect(m2.width > m.width);
    try std.testing.expect(frame2.countNotIn(.{ .x = 0, .y = 0, .w = m2.width, .h = 64 }, bg) > 0);
}

test "BoundText: the semantic label follows the signal (a11y)" {
    const sig = try ui.state.Signal(u32).init(std.testing.allocator, 1);
    defer sig.deinit();
    const node = try BoundText(u32).text(std.testing.allocator, sig, fmtBoundCount, .{});
    defer node.deinit();
    try std.testing.expectEqualStrings("Pressed 1 times", node.semantics.?.label);
    sig.set(42);
    try std.testing.expectEqualStrings("Pressed 42 times", node.semantics.?.label);
}
