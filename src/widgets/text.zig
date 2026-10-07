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
fn textPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *TextState = @ptrCast(@alignCast(n.state.?));
    const m = ui.paint.measureText(s.text, s.opts.size, s.opts.bold);
    const x = switch (s.opts.text_align) {
        .left => n.bounds.x,
        .center => n.bounds.x + (n.bounds.w - m.width) / 2,
        .right => n.bounds.x + n.bounds.w - m.width,
    };
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
    return node;
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
