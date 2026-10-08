// Image widget (Phase 1b P0) — RGBA pixels drawn stretched into the bounds.
// The image handle is created lazily at first paint (paint has the ctx; the
// factory and measure/layout stay pure) and destroyed with the widget.
// Skia uploads the raster image to the GPU on first draw and caches the
// texture in the ctx's resource cache, so repeated draws are cheap.
//
// Lifetime rule: the widget tree must be destroyed BEFORE the kx ctx it
// painted on (same rule as the golden helper) — releasing the handle touches
// the ctx. Handles are per-ctx: painting on a different ctx re-uploads.
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
    if (s.ctx != ctx) {
        // First paint or context switch: (re)upload on this ctx. Releasing the
        // old handle touches the old ctx (alive per the lifetime rule above).
        if (s.id != 0) {
            if (s.ctx) |old| ui.paint.imageDestroy(old, s.id);
            s.id = 0;
        }
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
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(ImageState);
    errdefer allocator.destroy(s);
    const pixels = try allocator.alloc(u8, rgba.len);
    errdefer allocator.free(pixels);
    @memcpy(pixels, rgba);
    s.* = .{ .pixels = pixels, .src_w = w, .src_h = h };
    node.state = s;
    ui.semantics.attach(node, .{ .role = .image }); // Phase 2c (label via attach)
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

test "image re-uploads when the painting context changes" {
    const bg = 0x101010FF;
    // 2x2 opaque red (RGBA memory order).
    const src = [_]u8{
        0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF,
        0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF,
    };
    const ctx1 = kx.create(null, 4, 4, kx.c.KX_BACKEND_RASTER) orelse return error.KxCreateFailed;
    defer kx.c.kx_destroy(ctx1);
    const ctx2 = kx.create(null, 4, 4, kx.c.KX_BACKEND_RASTER) orelse return error.KxCreateFailed;
    defer kx.c.kx_destroy(ctx2);
    const root = try image(std.testing.allocator, 2, 2, &src);
    defer root.deinit(); // tree dies before the ctxs (defer LIFO: declared last)
    root.layout(.{ .x = 0, .y = 0, .w = 4, .h = 4 });
    for ([_]*kx.Ctx{ ctx1, ctx2 }) |ctx| {
        kx.c.kx_begin_frame(ctx);
        kx.c.kx_clear(ctx, bg);
        root.paint(ctx);
        kx.c.kx_end_frame(ctx);
        const pixels = try std.testing.allocator.alloc(u8, 4 * 4 * 4);
        defer std.testing.allocator.free(pixels);
        var ow: c_int = 0;
        var oh: c_int = 0;
        try std.testing.expect(kx.c.kx_readback_rgba(ctx, pixels.ptr, pixels.len, &ow, &oh));
        // 2x2 red image stretched to 4x4 → all 16 pixels opaque red.
        var i: usize = 0;
        while (i < pixels.len) : (i += 4) {
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0x00, 0x00, 0xFF }, pixels[i .. i + 4]);
        }
    }
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
