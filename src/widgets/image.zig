// Image widget (Phase 1b P0) — RGBA pixels drawn stretched into the bounds.
// The GPU resource is created lazily at first paint (paint has the ctx; the
// factory and measure/layout stay pure) and destroyed with the widget.
// Decoding from files/assets lands with the asset pipeline (Phase 4/5).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;

const ImageState = struct {
    pixels: []u8, // owned, RGBA memory order (R,G,B,A), src_w*src_h*4
    src_w: i32,
    src_h: i32,
    id: u64 = 0, // kx image handle, created lazily at first paint
    ctx: ?*kx.Ctx = null,
};

fn imageMeasure(n: *Node, c: Constraints) Size {
    const s: *ImageState = @ptrCast(@alignCast(n.state.?));
    return c.constrain(.{ .w = @floatFromInt(s.src_w), .h = @floatFromInt(s.src_h) });
}
fn imageLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn imagePaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *ImageState = @ptrCast(@alignCast(n.state.?));
    if (s.id == 0) {
        s.id = ui.paint.imageCreate(ctx, s.pixels.ptr, s.src_w, s.src_h);
        s.ctx = ctx;
    }
    if (s.id != 0) {
        ui.paint.imageDraw(ctx, s.id, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h);
    }
}
fn imageDeinit(n: *Node) void {
    const s: *ImageState = @ptrCast(@alignCast(n.state.?));
    if (s.id != 0) {
        if (s.ctx) |ctx| ui.paint.imageDestroy(ctx, s.id);
    }
    n.allocator.free(s.pixels);
    n.allocator.destroy(s);
}
const image_vtable = ui.node.VTable{ .measure = imageMeasure, .layout = imageLayout, .paint = imagePaint, .deinit = imageDeinit };

/// Image from raw RGBA pixels (memory order R,G,B,A — matches kx readback).
/// Copies the pixels. Natural size = pixel size; stretches to the bounds.
pub fn image(allocator: std.mem.Allocator, w: i32, h: i32, rgba: []const u8) !*Node {
    if (w <= 0 or h <= 0) return error.InvalidImage;
    if (rgba.len != @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4) return error.InvalidImage;
    const node = try Node.create(allocator, &image_vtable);
    const s = try allocator.create(ImageState);
    const pixels = try allocator.alloc(u8, rgba.len);
    @memcpy(pixels, rgba);
    s.* = .{ .pixels = pixels, .src_w = w, .src_h = h };
    node.state = s;
    return node;
}

// --- tests ---

test "image rejects mismatched pixel buffers" {
    try std.testing.expectError(error.InvalidImage, image(std.testing.allocator, 0, 4, &.{}));
    try std.testing.expectError(error.InvalidImage, image(std.testing.allocator, 2, 2, &.{ 1, 2, 3 }));
}

test "image measures its natural pixel size" {
    var px: [16]u8 = undefined; // 2x2 RGBA
    @memset(&px, 0xFF);
    const img = try image(std.testing.allocator, 2, 2, &px);
    defer img.deinit();
    const size = img.measure(.{});
    try std.testing.expectEqual(@as(f32, 2), size.w);
    try std.testing.expectEqual(@as(f32, 2), size.h);
}

test "golden: image draws exact pixels (nearest sampling, 2x upscale)" {
    const bg = 0x101010FF;
    const red = 0xFF0000FF;
    const green = 0x00FF00FF;
    const blue = 0x0000FFFF;
    const white = 0xFFFFFFFF;
    // 2x2 source: red green / blue white, drawn into 4x4 → each pixel is a 2x2 block.
    const src = [_]u8{
        0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, // red, green
        0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // blue, white
    };
    const root = try image(std.testing.allocator, 2, 2, &src);
    defer root.deinit();
    var frame = try golden.render(std.testing.allocator, root, 4, 4, bg);
    defer frame.deinit();
    try std.testing.expectEqual(@as(u64, 4), frame.countColor(red));
    try std.testing.expectEqual(@as(u64, 4), frame.countColor(green));
    try std.testing.expectEqual(@as(u64, 4), frame.countColor(blue));
    try std.testing.expectEqual(@as(u64, 4), frame.countColor(white));
    try std.testing.expectEqual(red, frame.pixelAt(0, 0));
    try std.testing.expectEqual(green, frame.pixelAt(3, 0));
    try std.testing.expectEqual(blue, frame.pixelAt(0, 3));
    try std.testing.expectEqual(white, frame.pixelAt(3, 3));
}
