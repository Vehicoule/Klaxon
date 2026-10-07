// Theme — design tokens for the gallery (Phase 1g). P0: two presets (dark,
// light). A full design system (more presets, tokens, dark/light variants per
// widget) is explicitly V2 — see docs/ROADMAP.md.
//
// Colors are 0xRRGGBBAA (see ui/paint.zig).
const ui = @import("ui.zig");

pub const Color = ui.paint.Color;

pub const Theme = struct {
    name: []const u8,
    bg: Color, // window background
    surface: Color, // cards / panels
    surface_2: Color, // input wells, secondary panels
    text: Color,
    text_dim: Color,
    accent: Color,
    accent_hover: Color,
    border: Color,
    danger: Color,
};

pub const dark: Theme = .{
    .name = "dark",
    .bg = 0x14141FFF,
    .surface = 0x1E1E2EFF,
    .surface_2 = 0x282838FF,
    .text = 0xFFFFFFFF,
    .text_dim = 0x9A9AA8FF,
    .accent = 0x4C6EF5FF,
    .accent_hover = 0x748FFCFF,
    .border = 0x3A3A4AFF,
    .danger = 0xFF6B6BFF,
};

pub const light: Theme = .{
    .name = "light",
    .bg = 0xF4F4F6FF,
    .surface = 0xFFFFFFFF,
    .surface_2 = 0xE9E9EEFF,
    .text = 0x1B1B1FFF,
    .text_dim = 0x66666EFF,
    .accent = 0x3B5BDBFF,
    .accent_hover = 0x4C6EF5FF,
    .border = 0xD2D2DAFF,
    .danger = 0xE03131FF,
};

test "theme presets are opaque and distinct" {
    const std = @import("std");
    try std.testing.expect(dark.bg != light.bg);
    try std.testing.expect(dark.text != light.text);
    try std.testing.expectEqual(@as(u8, 0xFF), @as(u8, @truncate(dark.bg & 0xFF)));
    try std.testing.expectEqual(@as(u8, 0xFF), @as(u8, @truncate(light.surface & 0xFF)));
}
