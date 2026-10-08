// Theme — Material 3 Expressive design tokens (Phase 2d-0).
//
// The full M3E token set: color roles (light/dark baseline schemes), type
// scale, shape, elevation, motion (durations, easings, springs), state-layer
// opacities and spacing. Widgets consume a Theme value — apps override
// tokens (or the whole Theme) to reskin; that override layer is where custom
// branding lands (see docs/DESIGN-SYSTEM.md).
//
// Colors are 0xRRGGBBAA (see ui/paint.zig). Color values are Google's M3
// baseline schemes. Dynamic color (HCT palettes from a seed/wallpaper) is a
// later addition — the ColorScheme struct isolates it.
//
// Decision record: docs/adr/ADR-0010-design-system-m3e.md.

const std = @import("std");
const ui = @import("ui.zig");
const anim = @import("ui/anim.zig");

pub const Color = ui.paint.Color;

/// M3 state layer: the on-color of a container blended over the base color
/// at the state opacity (hover 0.08, focus 0.10, pressed 0.12, drag 0.16).
pub fn stateLayer(base: Color, on: Color, alpha: f32) Color {
    return anim.lerpColor(base, on, alpha);
}

/// Relative luminance (WCAG 2.x): 0 = black, 1 = white. Used for contrast
/// checks in tests and by accessibility tooling.
pub fn relativeLuminance(c: Color) f32 {
    const lin = struct {
        fn f(chan: u32) f32 {
            const s = @as(f32, @floatFromInt(chan)) / 255.0;
            return if (s <= 0.04045) s / 12.92 else std.math.pow(f32, (s + 0.055) / 1.055, 2.4);
        }
    }.f;
    const r = lin((c >> 24) & 0xFF);
    const g = lin((c >> 16) & 0xFF);
    const b = lin((c >> 8) & 0xFF);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// WCAG contrast ratio between two colors (1..21).
pub fn contrastRatio(a: Color, b: Color) f32 {
    const la = relativeLuminance(a);
    const lb = relativeLuminance(b);
    const hi = @max(la, lb);
    const lo = @min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

/// M3 color roles — one scheme (light or dark). Baseline values published by
/// Google; M3E keeps the same roles.
pub const ColorScheme = struct {
    primary: Color,
    on_primary: Color,
    primary_container: Color,
    on_primary_container: Color,
    secondary: Color,
    on_secondary: Color,
    secondary_container: Color,
    on_secondary_container: Color,
    tertiary: Color,
    on_tertiary: Color,
    tertiary_container: Color,
    on_tertiary_container: Color,
    @"error": Color, // keyword — quoted identifier keeps the M3 role name
    on_error: Color,
    error_container: Color,
    on_error_container: Color,
    surface: Color,
    on_surface: Color,
    surface_variant: Color,
    on_surface_variant: Color,
    surface_container_lowest: Color,
    surface_container_low: Color,
    surface_container: Color,
    surface_container_high: Color,
    surface_container_highest: Color,
    background: Color, // deprecated in M3 in favor of surface; kept for completeness
    on_background: Color,
    outline: Color,
    outline_variant: Color,
    inverse_surface: Color,
    inverse_on_surface: Color,
    inverse_primary: Color,
    surface_tint: Color, // = primary
    surface_bright: Color,
    surface_dim: Color,
    scrim: Color,
    shadow: Color,
};

/// One M3 type style: font size, line height (px at scale 1), weight
/// (400/500), letter spacing (px at scale 1 — the M3 tracking values).
pub const TypeStyle = struct {
    size: f32,
    line_height: f32,
    weight: u16,
    letter_spacing: f32,
};

/// M3 type scale: 5 roles x 3 sizes.
pub const TypeScale = struct {
    display_large: TypeStyle,
    display_medium: TypeStyle,
    display_small: TypeStyle,
    headline_large: TypeStyle,
    headline_medium: TypeStyle,
    headline_small: TypeStyle,
    title_large: TypeStyle,
    title_medium: TypeStyle,
    title_small: TypeStyle,
    body_large: TypeStyle,
    body_medium: TypeStyle,
    body_small: TypeStyle,
    label_large: TypeStyle,
    label_medium: TypeStyle,
    label_small: TypeStyle,
};

/// M3 shape scale (corner radii, px). "Full" (pill) has no fixed token —
/// components compute it as height/2.
pub const Shape = struct {
    extra_small: f32, // 4
    small: f32, // 8
    medium: f32, // 12
    large: f32, // 16
    extra_large: f32, // 28
};

/// One elevation level as a raster shadow approximation. M3 specifies
/// key/ambient umbra+penumbra shadows; the raster backend draws a single
/// blurred offset shadow — these values approximate the M3 levels.
pub const Shadow = struct {
    dy: f32,
    blur: f32,
    alpha: f32,
};

/// M3 elevation levels 0-5.
pub const Elevation = struct {
    level0: Shadow,
    level1: Shadow,
    level2: Shadow,
    level3: Shadow,
    level4: Shadow,
    level5: Shadow,
};

/// M3 duration scale (ms).
pub const Durations = struct {
    short1: u32,
    short2: u32,
    short3: u32,
    short4: u32,
    medium1: u32,
    medium2: u32,
    medium3: u32,
    medium4: u32,
    long1: u32,
    long2: u32,
    long3: u32,
    long4: u32,
};

/// A cubic-bezier easing (CSS-style control points; endpoints fixed at
/// (0,0)/(1,1)). Samples through ui.anim.cubicBezier.
pub const Bezier = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    pub fn sample(b: Bezier, t: f32) f32 {
        return anim.cubicBezier(b.x1, b.y1, b.x2, b.y2, t);
    }
};

/// M3 easing curves.
pub const Easings = struct {
    standard: Bezier, // (0.2, 0, 0, 1)
    standard_accelerate: Bezier, // (0.3, 0, 1, 1)
    standard_decelerate: Bezier, // (0, 0, 0, 1)
    emphasized: Bezier, // (0.2, 0, 0, 1)
    emphasized_accelerate: Bezier, // (0.3, 0.1, 0.2, 1)
    emphasized_decelerate: Bezier, // (0.05, 0.7, 0.1, 1)
};

/// M3E spring presets, per the M3E motion spec (stiffness + damping ratio,
/// converted to the anim.Spring parameterization c = 2*zeta*sqrt(k*m)):
/// default — general container transforms; spatial — large movements
/// (sheets, drawers); effects — small effects (ripples, toggles).
pub const Springs = struct {
    default_spring: anim.Spring,
    spatial_spring: anim.Spring,
    effects_spring: anim.Spring,
};

pub const Motion = struct {
    durations: Durations,
    easings: Easings,
    springs: Springs,
};

/// M3 state-layer opacities (the on-color blended over the base).
pub const StateLayers = struct {
    hover: f32, // 0.08
    focus: f32, // 0.10
    pressed: f32, // 0.12
    drag: f32, // 0.16
};

/// Spacing scale (px). M3 does not publish spacing tokens; this is the
/// conventional 4-based scale used across M3 implementations.
pub const Spacing = struct {
    xs: f32,
    s: f32,
    m: f32,
    l: f32,
    xl: f32,
    xxl: f32,
};

const type_scale: TypeScale = .{
    .display_large = .{ .size = 57, .line_height = 64, .weight = 400, .letter_spacing = -0.25 },
    .display_medium = .{ .size = 45, .line_height = 52, .weight = 400, .letter_spacing = 0 },
    .display_small = .{ .size = 36, .line_height = 44, .weight = 400, .letter_spacing = 0 },
    .headline_large = .{ .size = 32, .line_height = 40, .weight = 400, .letter_spacing = 0 },
    .headline_medium = .{ .size = 28, .line_height = 36, .weight = 400, .letter_spacing = 0 },
    .headline_small = .{ .size = 24, .line_height = 32, .weight = 400, .letter_spacing = 0 },
    .title_large = .{ .size = 22, .line_height = 28, .weight = 400, .letter_spacing = 0 },
    .title_medium = .{ .size = 16, .line_height = 24, .weight = 500, .letter_spacing = 0.15 },
    .title_small = .{ .size = 14, .line_height = 20, .weight = 500, .letter_spacing = 0.1 },
    .body_large = .{ .size = 16, .line_height = 24, .weight = 400, .letter_spacing = 0.5 },
    .body_medium = .{ .size = 14, .line_height = 20, .weight = 400, .letter_spacing = 0.25 },
    .body_small = .{ .size = 12, .line_height = 16, .weight = 400, .letter_spacing = 0.4 },
    .label_large = .{ .size = 14, .line_height = 20, .weight = 500, .letter_spacing = 0.1 },
    .label_medium = .{ .size = 12, .line_height = 16, .weight = 500, .letter_spacing = 0.5 },
    .label_small = .{ .size = 11, .line_height = 16, .weight = 500, .letter_spacing = 0.5 },
};

const shape: Shape = .{ .extra_small = 4, .small = 8, .medium = 12, .large = 16, .extra_large = 28 };

const elevation: Elevation = .{
    .level0 = .{ .dy = 0, .blur = 0, .alpha = 0 },
    .level1 = .{ .dy = 1, .blur = 3, .alpha = 0.10 }, // 1dp
    .level2 = .{ .dy = 1, .blur = 6, .alpha = 0.12 }, // 3dp
    .level3 = .{ .dy = 2, .blur = 10, .alpha = 0.14 }, // 6dp
    .level4 = .{ .dy = 3, .blur = 14, .alpha = 0.16 }, // 8dp
    .level5 = .{ .dy = 4, .blur = 18, .alpha = 0.18 }, // 12dp
};

const motion: Motion = .{
    .durations = .{
        .short1 = 50,
        .short2 = 100,
        .short3 = 150,
        .short4 = 200,
        .medium1 = 250,
        .medium2 = 300,
        .medium3 = 350,
        .medium4 = 400,
        .long1 = 450,
        .long2 = 500,
        .long3 = 550,
        .long4 = 600,
    },
    .easings = .{
        .standard = .{ .x1 = 0.2, .y1 = 0.0, .x2 = 0.0, .y2 = 1.0 },
        .standard_accelerate = .{ .x1 = 0.3, .y1 = 0.0, .x2 = 1.0, .y2 = 1.0 },
        .standard_decelerate = .{ .x1 = 0.0, .y1 = 0.0, .x2 = 0.0, .y2 = 1.0 },
        .emphasized = .{ .x1 = 0.2, .y1 = 0.0, .x2 = 0.0, .y2 = 1.0 },
        .emphasized_accelerate = .{ .x1 = 0.3, .y1 = 0.1, .x2 = 0.2, .y2 = 1.0 },
        .emphasized_decelerate = .{ .x1 = 0.05, .y1 = 0.7, .x2 = 0.1, .y2 = 1.0 },
    },
    .springs = .{
        .default_spring = anim.Spring.fromDampingRatio(1400, 0.8, 1),
        .spatial_spring = anim.Spring.fromDampingRatio(700, 0.8, 1),
        .effects_spring = anim.Spring.fromDampingRatio(3800, 0.9, 1),
    },
};

const state_layers: StateLayers = .{ .hover = 0.08, .focus = 0.10, .pressed = 0.12, .drag = 0.16 };

const spacing: Spacing = .{ .xs = 4, .s = 8, .m = 12, .l = 16, .xl = 24, .xxl = 32 };

/// A complete theme: every design token a widget needs. Copy and override
/// fields (or the whole value) to reskin — widgets read tokens, never
/// hardcode them.
pub const Theme = struct {
    name: []const u8,
    colors: ColorScheme,
    type_scale: TypeScale,
    shape: Shape,
    elevation: Elevation,
    motion: Motion,
    state: StateLayers,
    spacing: Spacing,
};

/// M3 baseline light scheme.
const light_colors: ColorScheme = .{
    .primary = 0x6750A4FF,
    .on_primary = 0xFFFFFFFF,
    .primary_container = 0xEADDFFFF,
    .on_primary_container = 0x21005DFF,
    .secondary = 0x625B71FF,
    .on_secondary = 0xFFFFFFFF,
    .secondary_container = 0xE8DEF8FF,
    .on_secondary_container = 0x1D192BFF,
    .tertiary = 0x7D5260FF,
    .on_tertiary = 0xFFFFFFFF,
    .tertiary_container = 0xFFD8E4FF,
    .on_tertiary_container = 0x31111DFF,
    .@"error" = 0xB3261EFF,
    .on_error = 0xFFFFFFFF,
    .error_container = 0xF9DEDCFF,
    .on_error_container = 0x410E0BFF,
    .surface = 0xFEF7FFFF,
    .on_surface = 0x1D1B20FF,
    .surface_variant = 0xE7E0ECFF,
    .on_surface_variant = 0x49454FFF,
    .surface_container_lowest = 0xFFFFFFFF,
    .surface_container_low = 0xF7F2FAFF,
    .surface_container = 0xF3EDF7FF,
    .surface_container_high = 0xECE6F0FF,
    .surface_container_highest = 0xE6E0E9FF,
    .background = 0xFEF7FFFF,
    .on_background = 0x1D1B20FF,
    .outline = 0x79747EFF,
    .outline_variant = 0xCAC4D0FF,
    .inverse_surface = 0x322F35FF,
    .inverse_on_surface = 0xF5EFF7FF,
    .inverse_primary = 0xD0BCFFFF,
    .surface_tint = 0x6750A4FF,
    .surface_bright = 0xFEF7FFFF,
    .surface_dim = 0xDED8E1FF,
    .scrim = 0x000000FF,
    .shadow = 0x000000FF,
};

/// M3 baseline dark scheme.
const dark_colors: ColorScheme = .{
    .primary = 0xD0BCFFFF,
    .on_primary = 0x381E72FF,
    .primary_container = 0x4F378BFF,
    .on_primary_container = 0xEADDFFFF,
    .secondary = 0xCCC2DCFF,
    .on_secondary = 0x332D41FF,
    .secondary_container = 0x4A4458FF,
    .on_secondary_container = 0xE8DEF8FF,
    .tertiary = 0xEFB8C8FF,
    .on_tertiary = 0x492532FF,
    .tertiary_container = 0x633B48FF,
    .on_tertiary_container = 0xFFD8E4FF,
    .@"error" = 0xF2B8B5FF,
    .on_error = 0x601410FF,
    .error_container = 0x8C1D18FF,
    .on_error_container = 0xF9DEDCFF,
    .surface = 0x141218FF,
    .on_surface = 0xE6E0E9FF,
    .surface_variant = 0x49454FFF,
    .on_surface_variant = 0xCAC4D0FF,
    .surface_container_lowest = 0x0F0D13FF,
    .surface_container_low = 0x1D1B20FF,
    .surface_container = 0x211F26FF,
    .surface_container_high = 0x2B2930FF,
    .surface_container_highest = 0x36343BFF,
    .background = 0x141218FF,
    .on_background = 0xE6E0E9FF,
    .outline = 0x938F99FF,
    .outline_variant = 0x49454FFF,
    .inverse_surface = 0xE6E0E9FF,
    .inverse_on_surface = 0x322F35FF,
    .inverse_primary = 0x6750A4FF,
    .surface_tint = 0xD0BCFFFF,
    .surface_bright = 0x3B383EFF,
    .surface_dim = 0x141218FF,
    .scrim = 0x000000FF,
    .shadow = 0x000000FF,
};

pub const light: Theme = .{
    .name = "light",
    .colors = light_colors,
    .type_scale = type_scale,
    .shape = shape,
    .elevation = elevation,
    .motion = motion,
    .state = state_layers,
    .spacing = spacing,
};

pub const dark: Theme = .{
    .name = "dark",
    .colors = dark_colors,
    .type_scale = type_scale,
    .shape = shape,
    .elevation = elevation,
    .motion = motion,
    .state = state_layers,
    .spacing = spacing,
};

// --- tests ---

test "theme: stateLayer blends the on-color at the state alpha" {
    const a: Color = 0x000000FF;
    const b: Color = 0xFFFFFFFF;
    try std.testing.expectEqual(a, anim.lerpColor(a, b, 0));
    try std.testing.expectEqual(b, anim.lerpColor(a, b, 1));
    try std.testing.expectEqual(b, anim.lerpColor(a, b, 2)); // clamped
    try std.testing.expectEqual(0x7F7F7FFF, anim.lerpColor(a, b, 0.5)); // truncating: 127.5 → 127
    try std.testing.expectEqual(
        anim.lerpColor(dark.colors.primary, dark.colors.on_primary, 0.08),
        stateLayer(dark.colors.primary, dark.colors.on_primary, dark.state.hover),
    );
}

test "theme: schemes are opaque, distinct, and WCAG-contrastive" {
    inline for (.{ light.colors, dark.colors }) |cs| {
        inline for (@typeInfo(ColorScheme).@"struct".field_names) |name| {
            try std.testing.expectEqual(@as(u8, 0xFF), @as(u8, @truncate(@field(cs, name) & 0xFF)));
        }
    }
    try std.testing.expect(light.colors.primary != dark.colors.primary);
    try std.testing.expect(light.colors.surface != dark.colors.surface);
    // M3 guarantees >= 4.5:1 for text on its container (both schemes).
    inline for (.{ light.colors, dark.colors }) |cs| {
        const pairs = .{
            .{ cs.primary, cs.on_primary },
            .{ cs.surface, cs.on_surface },
            .{ cs.surface_variant, cs.on_surface_variant },
            .{ cs.primary_container, cs.on_primary_container },
            .{ cs.@"error", cs.on_error },
            .{ cs.inverse_surface, cs.inverse_on_surface },
        };
        inline for (pairs) |p| {
            try std.testing.expect(contrastRatio(p[0], p[1]) >= 4.5);
        }
    }
}

test "theme: type scale matches the M3 spec" {
    const ts = light.type_scale;
    try std.testing.expectEqual(@as(f32, 57), ts.display_large.size);
    try std.testing.expectEqual(@as(f32, 64), ts.display_large.line_height);
    try std.testing.expectEqual(@as(u16, 500), ts.title_medium.weight);
    try std.testing.expectEqual(@as(f32, 11), ts.label_small.size);
    inline for (@typeInfo(TypeScale).@"struct".field_names) |name| {
        const st: TypeStyle = @field(ts, name);
        try std.testing.expect(st.line_height >= st.size);
        try std.testing.expect(st.weight == 400 or st.weight == 500);
    }
}

test "theme: motion tokens are ordered and springs settle" {
    const m = light.motion;
    try std.testing.expect(m.durations.short1 < m.durations.short4);
    try std.testing.expect(m.durations.short4 < m.durations.medium1);
    try std.testing.expect(m.durations.medium4 < m.durations.long1);
    try std.testing.expect(m.durations.long1 < m.durations.long4);
    inline for (@typeInfo(Easings).@"struct".field_names) |name| {
        const b: Bezier = @field(m.easings, name);
        try std.testing.expectApproxEqAbs(@as(f32, 0), b.sample(0), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1), b.sample(1), 1e-4);
    }
    // Springs settle on target (closed form, tick-rate independent).
    inline for (.{ m.springs.default_spring, m.springs.spatial_spring, m.springs.effects_spring }) |s| {
        try std.testing.expect(@abs(s.displacement(100, 0, 5.0)) < 0.5);
    }
}

test "theme: light and dark share the non-color tokens" {
    try std.testing.expectEqual(light.type_scale.display_large.size, dark.type_scale.display_large.size);
    try std.testing.expectEqual(light.shape.medium, dark.shape.medium);
    try std.testing.expectEqual(light.motion.durations.medium2, dark.motion.durations.medium2);
    try std.testing.expectEqual(light.state.hover, dark.state.hover);
    try std.testing.expectEqual(light.spacing.m, dark.spacing.m);
}
