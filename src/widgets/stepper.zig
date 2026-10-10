// M3E Stepper (Phase 4d P2) — a horizontal step indicator: numbered
// circles connected by lines, with labels below each circle.
//
// Spec: docs/specs/m3e-specs-4d-p2-stepper.md
//
// Tokens:
//   - circle: 24dp, active/completed = Primary fill + OnPrimary content,
//     upcoming = SurfaceContainerHighest fill + OnSurfaceVariant content
//   - connector: 1dp Primary (completed) / OutlineVariant (upcoming)
//   - label: BodySmall, OnSurface (active) / OnSurfaceVariant (upcoming)
//   - spacing: 8dp circle→label, min step width 80dp
//
// State: `current` is a two-way Signal(usize) — the active step index.
// Steps < current: completed (check). Step == current: active (number).
// Steps > current: upcoming (number, muted).
//
// v1 deviations: horizontal only; no connector animation; no error state;
// no optional steps.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

pub const StepperStep = struct {
    label: []const u8,
};

pub const StepperOptions = struct {
    theme: Theme = theme_mod.light,
    /// When true, tapping a step sets current to that index.
    tappable: bool = false,
};

// --- M3E tokens ---

const circle_d: f32 = 24;
const circle_gap: f32 = 8; // circle → label
const min_step_w: f32 = 80;
const connector_h: f32 = 1;

// --- State ---

const StepperState = struct {
    opts: StepperOptions,
    sig: ?*ui.state.Signal(usize),
    steps: std.array_list.Managed(StepDef),
    hovered: i32 = -1,
};

const StepDef = struct {
    label: [:0]u8, // owned, null-terminated
};

fn stateOf(n: *Node) *StepperState {
    return @ptrCast(@alignCast(n.state.?));
}

fn currentStep(s: *StepperState) usize {
    return if (s.sig) |sig| sig.peek() else 0;
}

fn stepState(s: *StepperState, index: usize) enum { completed, active, upcoming } {
    const cur = currentStep(s);
    if (index < cur) return .completed;
    if (index == cur) return .active;
    return .upcoming;
}

// --- Measure ---

fn stMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const t = s.opts.theme;
    const ls = t.type_scale.body_small;
    var total_w: f32 = 0;
    for (s.steps.items) |step| {
        const label_w = ui.paint.measureText(step.label, ls.size, false).width;
        total_w += @max(min_step_w, label_w + 16);
    }
    if (s.steps.items.len > 1) {
        // Connectors are drawn inside the step columns (no extra width).
    }
    const h = circle_d + circle_gap + ls.line_height;
    return .{
        .w = @max(c.min_w, @min(c.max_w, total_w)),
        .h = @max(c.min_h, @min(c.max_h, h)),
    };
}

// --- Layout ---

fn stepColumnWidth(s: *StepperState, index: usize) f32 {
    const t = s.opts.theme;
    const ls = t.type_scale.body_small;
    const label_w = ui.paint.measureText(s.steps.items[index].label, ls.size, false).width;
    return @max(min_step_w, label_w + 16);
}

fn stLayout(_: *Node, _: Rect) void {}

// --- Paint ---

fn stPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const ls = t.type_scale.body_small;

    if (s.steps.items.len == 0) return;

    // Compute column widths + positions.
    var x = b.x;
    const circle_cy = b.y + circle_d / 2;
    var i: usize = 0;
    while (i < s.steps.items.len) : (i += 1) {
        const col_w = stepColumnWidth(s, i);
        const circle_cx = x + col_w / 2;
        const state = stepState(s, i);

        // Circle.
        const fill = switch (state) {
            .completed, .active => t.colors.primary,
            .upcoming => t.colors.surface_container_highest,
        };
        const content_color = switch (state) {
            .completed, .active => t.colors.on_primary,
            .upcoming => t.colors.on_surface_variant,
        };
        ui.paint.fillRRect(ctx, circle_cx - circle_d / 2, b.y, circle_d, circle_d, circle_d / 2, fill);

        // Content: check for completed, number for active/upcoming.
        const content: [:0]const u8 = switch (state) {
            .completed => "\u{2713}", // ✓
            .active, .upcoming => blk: {
                // Format the step number (1-based).
                var buf: [5]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{i + 1}) catch "?";
                const len = str.len;
                buf[len] = 0;
                break :blk buf[0..len :0];
            },
        };
        const font_size = circle_d * 0.5;
        const metrics = ui.paint.measureText(content, font_size, state == .active);
        const tx = circle_cx - metrics.width / 2;
        const ty = b.y + (circle_d - metrics.height) / 2 + metrics.height * 0.8;
        ui.paint.text(ctx, content, tx, ty, font_size, state == .active, content_color);

        // Label.
        const label = s.steps.items[i].label;
        const label_metrics = ui.paint.measureText(label, ls.size, false);
        const label_x = circle_cx - label_metrics.width / 2;
        const label_y = b.y + circle_d + circle_gap + ls.line_height * 0.8;
        const label_color = if (state == .upcoming) t.colors.on_surface_variant else t.colors.on_surface;
        ui.paint.text(ctx, label, label_x, label_y, ls.size, false, label_color);

        // Connector to the next step.
        if (i + 1 < s.steps.items.len) {
            const next_col_w = stepColumnWidth(s, i + 1);
            const conn_x0 = circle_cx + circle_d / 2;
            const conn_x1 = x + col_w + next_col_w / 2 - circle_d / 2;
            const conn_color = if (state == .completed) t.colors.primary else t.colors.outline_variant;
            if (conn_x1 > conn_x0) {
                ui.paint.fillRect(ctx, conn_x0, circle_cy - connector_h / 2, conn_x1 - conn_x0, connector_h, conn_color);
            }
        }

        x += col_w;
    }
}

// --- Input ---

fn stPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.tappable or s.steps.items.len == 0) return false;
    if (ev.phase != .up) return false;

    // Find which step was tapped.
    const b = n.bounds;
    var x = b.x;
    var i: usize = 0;
    while (i < s.steps.items.len) : (i += 1) {
        const col_w = stepColumnWidth(s, i);
        if (ev.x >= x and ev.x <= x + col_w) {
            if (s.sig) |sig| sig.set(i);
            return true;
        }
        x += col_w;
    }
    return false;
}

// --- Deinit ---

fn stDeinit(n: *Node) void {
    const s = stateOf(n);
    for (s.steps.items) |*step| n.allocator.free(step.label);
    s.steps.deinit();
    n.allocator.destroy(s);
}

// --- VTable ---

const st_vtable = ui.node.VTable{
    .measure = stMeasure,
    .layout = stLayout,
    .paint = stPaint,
    .on_pointer = stPointer,
    .deinit = stDeinit,
};

// --- Factory ---

/// Create an M3E stepper.
///
/// `sig` — a live Signal(usize) holding the active step index (0-based).
/// `steps` — the step definitions (labels are copied).
/// `opts` — theme, tappable.
pub fn stepper(
    allocator: std.mem.Allocator,
    sig: ?*ui.state.Signal(usize),
    steps: []const StepperStep,
    opts: StepperOptions,
) !*Node {
    const node = try Node.create(allocator, &st_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(StepperState);
    errdefer allocator.destroy(s);

    s.* = .{
        .opts = opts,
        .sig = sig,
        .steps = std.array_list.Managed(StepDef).init(allocator),
    };

    for (steps) |step| {
        const buf = try allocator.alloc(u8, step.label.len + 1);
        @memcpy(buf[0..step.label.len], step.label);
        buf[step.label.len] = 0;
        try s.steps.append(.{ .label = buf[0..step.label.len :0] });
    }

    node.state = @ptrCast(s);

    ui.semantics.attach(node, .{
        .role = .group,
        .label = "Stepper",
        .focusable = false,
    });

    return node;
}

// --- Tests ---

test "stepper: measure includes all steps" {
    const a = std.testing.allocator;
    const n = try stepper(a, null, &.{ .{ .label = "One" }, .{ .label = "Two" }, .{ .label = "Three" } }, .{});
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expect(sz.w >= min_step_w * 3);
    try std.testing.expect(sz.h > circle_d);
}

test "stepper: step states follow current" {
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 1);
    defer sig.deinit();
    const a = std.testing.allocator;
    const n = try stepper(a, sig, &.{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } }, .{});
    defer n.deinit();
    const s = stateOf(n);
    try std.testing.expectEqual(@as(usize, 1), currentStep(s));
    try std.testing.expect(stepState(s, 0) == .completed);
    try std.testing.expect(stepState(s, 1) == .active);
    try std.testing.expect(stepState(s, 2) == .upcoming);
}

test "stepper: tappable sets current" {
    const sig = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sig.deinit();
    const a = std.testing.allocator;
    const n = try stepper(a, sig, &.{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } }, .{ .tappable = true });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 300, .h = 50 });
    // Tap the 3rd step.
    const col_w = min_step_w;
    const x3 = col_w * 2 + col_w / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = x3, .y = 12, .raw_x = x3, .raw_y = 12 });
    try std.testing.expectEqual(@as(usize, 2), sig.peek());
}

test "golden: the stepper paints Primary circles for completed+active, SurfaceContainerHighest for upcoming" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(usize).init(a, 1);
    defer sig.deinit();
    const n = try stepper(a, sig, &.{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } }, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 300, 60);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 280, .h = 44 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // Step 0 (completed): Primary circle center.
    const col_w = min_step_w;
    const cx0 = 10 + col_w / 2;
    const cy = 10 + circle_d / 2;
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(@intFromFloat(cx0), @intFromFloat(cy)));
    // Step 2 (upcoming): SurfaceContainerHighest circle center (offset by text ink).
    const cx2 = 10 + col_w * 2 + col_w / 2;
    // Sample slightly off-center to avoid the number ink.
    try std.testing.expectEqual(t.colors.surface_container_highest, f.pixelAt(@intFromFloat(cx2 - 8), @intFromFloat(cy)));
}
