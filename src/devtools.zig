// DevTools — real-time performance overlay (Phase 4a.1 + 4a.5).
// A debug panel painted above the widget tree when enabled: FPS (current /
// average / p99 over a rolling buffer), frame + paint times, backend name,
// RSS, and a 60-frame FPS bar graph. Toggled with F12 (host.zig) or the
// --devtools flag (main.zig). When disabled the host skips recordFrame and
// paint entirely — zero interference with the normal render path (and the
// golden tests, which run with the overlay off).
const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl.zig");
const kx = @import("kx.zig");
const host_mod = @import("host.zig");

const Stats = host_mod.Stats;

/// Rolling buffer length (frame-time samples kept for avg/p99).
pub const HISTORY_LEN: usize = 120;
/// Bars drawn in the FPS graph (the most recent frames).
pub const GRAPH_LEN: usize = 60;

// Panel layout (pixels, origin top-left). Fixed size, anchored top-left.
const PANEL_X: f32 = 8;
const PANEL_Y: f32 = 8;
const PANEL_W: f32 = 280;
const PANEL_H: f32 = 120;
const TEXT_X: f32 = 16;
const LINE_H: f32 = 14;
const LINE_1_Y: f32 = 25; // first text baseline
const GRAPH_X: f32 = 16;
const GRAPH_BOTTOM: f32 = 102;
const GRAPH_H: f32 = 28;
const BAR_W: f32 = 3;
const BAR_PITCH: f32 = 4; // bar + 1px gap
const FOOTER_Y: f32 = 119;

// 0xRRGGBBAA (matches kx_skia.h).
const PANEL_BG: u32 = 0x000000CC;
const PANEL_BORDER: u32 = 0xFFFFFF1A;
const TEXT: u32 = 0xFFFFFFFF;
const TEXT_DIM: u32 = 0xAAAAAAFF;
const GRAPH_GREEN: u32 = 0x66BB6AFF; // frame < 8 ms
const GRAPH_YELLOW: u32 = 0xFFC107FF; // 8 ms <= frame < 16 ms
const GRAPH_RED: u32 = 0xEF5350FF; // frame >= 16 ms
const GRAPH_BASELINE: u32 = 0xFFFFFF33;

/// 16.67 ms = one 60 fps frame: a bar taller than the graph means the frame
/// missed the 60 fps budget (the height is clamped).
const FRAME_60FPS_MS: f32 = 16.67;
/// RSS is re-read at most this often (per paint call).
const RSS_TTL_MS: u64 = 250;

pub const DevTools = struct {
    enabled: bool = false,
    /// Ring buffer of frame times (ms). Valid samples are [0..history_count]
    /// until the buffer wraps (writes are sequential from slot 0); once full,
    /// every slot is valid and history_index is the next write slot.
    frame_times: [HISTORY_LEN]f32 = @splat(0),
    history_index: usize = 0,
    history_count: usize = 0,
    // RSS cache (readRssMb is throttled to one read per RSS_TTL_MS). The
    // clock is SDL_GetTicks (ms since SDL_Init) — the host's own clock.
    rss_mb: f32 = 0,
    rss_last_read_ms: ?u64 = null,

    pub fn init() DevTools {
        return .{};
    }

    pub fn toggle(devtools: *DevTools) void {
        devtools.enabled = !devtools.enabled;
    }

    /// Push a frame time into the ring buffer (oldest sample is overwritten
    /// once the buffer is full).
    pub fn recordFrame(devtools: *DevTools, frame_time_ms: f32) void {
        devtools.frame_times[devtools.history_index] = frame_time_ms;
        devtools.history_index = (devtools.history_index + 1) % HISTORY_LEN;
        if (devtools.history_count < HISTORY_LEN) devtools.history_count += 1;
    }

    /// Mean frame time over the valid samples (0 when empty).
    pub fn avgFrameTimeMs(devtools: *const DevTools) f32 {
        if (devtools.history_count == 0) return 0;
        var sum: f32 = 0;
        for (devtools.frame_times[0..devtools.history_count]) |ft| sum += ft;
        return sum / @as(f32, @floatFromInt(devtools.history_count));
    }

    /// 99th percentile frame time over the valid samples (0 when empty).
    pub fn p99FrameTimeMs(devtools: *const DevTools) f32 {
        const n = devtools.history_count;
        if (n == 0) return 0;
        var sorted: [HISTORY_LEN]f32 = undefined;
        @memcpy(sorted[0..n], devtools.frame_times[0..n]);
        std.mem.sort(f32, sorted[0..n], {}, std.sort.asc(f32));
        const idx = @min((n * 99) / 100, n - 1);
        return sorted[idx];
    }

    /// Paint the overlay: a semi-transparent panel in the top-left corner
    /// with the stats lines, the FPS bar graph, and the toggle hint. Drawn
    /// with the plain kx primitives (fill/stroke rect, text) — no widget
    /// tree, no layout pass.
    pub fn paint(devtools: *DevTools, ctx: *kx.Ctx, width: c_int, height: c_int, stats: *Stats) void {
        _ = width; // the panel is fixed-size, anchored top-left
        _ = height;
        // Throttled RSS read (a /proc or mach call per paint would be waste).
        const now_ms = sdl.c.SDL_GetTicks();
        if (devtools.rss_last_read_ms == null or now_ms - devtools.rss_last_read_ms.? >= RSS_TTL_MS) {
            devtools.rss_mb = readRssMb();
            devtools.rss_last_read_ms = now_ms;
        }
        // Panel + border.
        kx.c.kx_fill_rrect(ctx, PANEL_X, PANEL_Y, PANEL_W, PANEL_H, 8, PANEL_BG);
        kx.c.kx_stroke_rrect(ctx, PANEL_X, PANEL_Y, PANEL_W, PANEL_H, 8, 1, PANEL_BORDER);
        // Stats lines. The stats still describe the PREVIOUS frame here (the
        // host updates them after present) — one frame of display lag.
        var buf: [96]u8 = undefined;
        const fps_line = std.fmt.bufPrintSentinel(&buf, "FPS: {d:.1} (avg {d:.1}, p99 {d:.1})", .{
            fpsFromMs(stats.frame_time_ms),
            fpsFromMs(devtools.avgFrameTimeMs()),
            fpsFromMs(devtools.p99FrameTimeMs()),
        }, 0) catch return;
        kx.c.kx_draw_text(ctx, fps_line, TEXT_X, LINE_1_Y, 11, TEXT);
        const frame_line = std.fmt.bufPrintSentinel(&buf, "Frame: {d:.2} ms (paint {d:.2} ms)", .{
            stats.frame_time_ms,
            stats.paint_time_ms,
        }, 0) catch return;
        kx.c.kx_draw_text(ctx, frame_line, TEXT_X, LINE_1_Y + LINE_H, 11, TEXT);
        const backend_line = std.fmt.bufPrintSentinel(&buf, "Backend: {s}", .{stats.backend}, 0) catch return;
        kx.c.kx_draw_text(ctx, backend_line, TEXT_X, LINE_1_Y + 2 * LINE_H, 11, TEXT);
        const rss_line = std.fmt.bufPrintSentinel(&buf, "RSS: {d:.1} MB", .{devtools.rss_mb}, 0) catch return;
        kx.c.kx_draw_text(ctx, rss_line, TEXT_X, LINE_1_Y + 3 * LINE_H, 11, TEXT);
        // FPS graph: one bar per recent frame, oldest → newest left → right.
        // Height = frame_time / 16.67 ms (clamped to the graph height);
        // color = green < 8 ms, yellow < 16 ms, red >= 16 ms.
        const n = @min(GRAPH_LEN, devtools.history_count);
        kx.c.kx_fill_rect(ctx, GRAPH_X, GRAPH_BOTTOM, BAR_PITCH * @as(f32, @floatFromInt(n)) - 1, 1, GRAPH_BASELINE);
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const slot = (devtools.history_index + HISTORY_LEN - n + j) % HISTORY_LEN;
            const ft = devtools.frame_times[slot];
            const bar_h = @max(@min(ft / FRAME_60FPS_MS * GRAPH_H, GRAPH_H), 1.0);
            const color: u32 = if (ft < 8.0) GRAPH_GREEN else if (ft < 16.0) GRAPH_YELLOW else GRAPH_RED;
            kx.c.kx_fill_rect(ctx, GRAPH_X + @as(f32, @floatFromInt(j)) * BAR_PITCH, GRAPH_BOTTOM - bar_h, BAR_W, bar_h, color);
        }
        // Toggle hint.
        kx.c.kx_draw_text(ctx, "F12: toggle devtools", TEXT_X, FOOTER_Y, 10, TEXT_DIM);
    }
};

/// FPS for a frame time in ms (0 for a non-positive time).
pub fn fpsFromMs(frame_time_ms: f32) f32 {
    return if (frame_time_ms > 0) 1000.0 / frame_time_ms else 0.0;
}

/// Resident set size in MB. Linux: the VmRSS line of /proc/self/status
/// (kB). macOS: mach_task_basic_info's resident_size (bytes). Any other
/// target (emscripten, …): 0.0 — unsupported.
pub fn readRssMb() f32 {
    return switch (builtin.os.tag) {
        .linux => readRssMbLinux(),
        .macos => readRssMbMac(),
        else => 0.0,
    };
}

fn readRssMbLinux() f32 {
    var file = std.fs.openFileAbsolute("/proc/self/status", .{}) catch return 0.0;
    defer file.close();
    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.read(buf[total..]) catch return 0.0;
        if (n == 0) break;
        total += n;
    }
    const status = buf[0..total];
    const idx = std.mem.indexOf(u8, status, "VmRSS:") orelse return 0.0;
    var i = idx + "VmRSS:".len;
    while (i < status.len and (status[i] == ' ' or status[i] == '\t')) i += 1;
    var kb: u64 = 0;
    while (i < status.len and status[i] >= '0' and status[i] <= '9') : (i += 1) {
        kb = kb * 10 + (status[i] - '0');
    }
    return @as(f32, @floatFromInt(kb)) / 1024.0;
}

// mach_task_basic_info (MACH_TASK_BASIC_INFO = 20, "always 64-bit basic
// info"): resident_size is the RSS in bytes. mach_task_self() is a macro
// over the mach_task_self_ global, hence the extern var. The declarations
// are portable (plain integer types) — the function is only ever CALLED on
// macOS (readRssMb's switch), so no mach symbol is referenced elsewhere.
const mach = struct {
    const mach_port_t = c_uint; // natural_t
    const kern_return_t = c_int;
    const time_value_t = extern struct { seconds: c_int, microseconds: c_int };
    const info_t = extern struct {
        virtual_size: u64, // mach_vm_size_t (LP64)
        resident_size: u64,
        resident_size_max: u64,
        user_time: time_value_t,
        system_time: time_value_t,
        policy: c_int, // policy_t
        suspend_count: c_int, // integer_t
    };
    const MACH_TASK_BASIC_INFO: c_int = 20;
    extern var mach_task_self_: mach_port_t;
    extern fn task_info(target_task: mach_port_t, flavor: c_int, task_info_out: *anyopaque, task_info_out_count: *c_uint) kern_return_t;
};

fn readRssMbMac() f32 {
    var info: mach.info_t = undefined;
    var count: c_uint = @intCast(@sizeOf(mach.info_t) / @sizeOf(c_uint));
    if (mach.task_info(mach.mach_task_self_, mach.MACH_TASK_BASIC_INFO, &info, &count) != 0) return 0.0;
    return @as(f32, @floatFromInt(info.resident_size)) / (1024.0 * 1024.0);
}

test "toggle flips enabled" {
    var dt = DevTools.init();
    try std.testing.expect(!dt.enabled);
    dt.toggle();
    try std.testing.expect(dt.enabled);
    dt.toggle();
    try std.testing.expect(!dt.enabled);
}

test "rolling buffer wraps correctly" {
    var dt = DevTools.init();
    // Fill less than the buffer: sequential slots, count grows.
    for (0..10) |i| dt.recordFrame(@floatFromInt(i));
    try std.testing.expectEqual(@as(usize, 10), dt.history_count);
    try std.testing.expectEqual(@as(usize, 10), dt.history_index);
    for (0..10) |i| try std.testing.expectEqual(@as(f32, @floatFromInt(i)), dt.frame_times[i]);
    // Record 200 frames into a fresh 120-slot buffer: only the last 120 are kept.
    var full = DevTools.init();
    for (0..200) |i| full.recordFrame(@floatFromInt(i));
    try std.testing.expectEqual(@as(usize, HISTORY_LEN), full.history_count);
    try std.testing.expectEqual(@as(usize, 200 % HISTORY_LEN), full.history_index);
    // Slot s holds the last value v in [80..200) with v % HISTORY_LEN == s.
    for (0..HISTORY_LEN) |s| {
        const expected: f32 = if (s >= 200 - HISTORY_LEN) @floatFromInt(s) else @floatFromInt(s + HISTORY_LEN);
        try std.testing.expectEqual(expected, full.frame_times[s]);
    }
}

test "fps computation: avg and p99 over known frame times" {
    var dt = DevTools.init();
    for (1..101) |i| dt.recordFrame(@floatFromInt(i)); // 1.0 .. 100.0 ms
    try std.testing.expectApproxEqAbs(@as(f32, 50.5), dt.avgFrameTimeMs(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), dt.p99FrameTimeMs(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), fpsFromMs(10.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), fpsFromMs(FRAME_60FPS_MS), 0.05);
    // Empty buffer: no samples, no division by zero.
    const empty = DevTools.init();
    try std.testing.expectEqual(@as(f32, 0), empty.avgFrameTimeMs());
    try std.testing.expectEqual(@as(f32, 0), empty.p99FrameTimeMs());
    try std.testing.expectEqual(@as(f32, 0), fpsFromMs(0));
}

test "readRssMb returns a sane value on supported platforms" {
    const mb = readRssMb();
    try std.testing.expect(mb >= 0.0);
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        // /proc/self/status or mach must report a non-zero RSS for the test exe.
        try std.testing.expect(mb > 0.0);
    }
}
