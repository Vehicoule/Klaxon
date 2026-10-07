// Golden-only test runner (Phase 1g).
//
// Zig 0.17's compile-time --test-filter only matches tests declared in the
// ROOT module; this repo's tests live in the widget modules (pulled in via
// refAllDecls from src/main.zig), so the golden suite filters by test NAME
// at runtime instead. Mirrors the default runner's per-test allocator /
// leak checking and exit code.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

var log_err_count: usize = 0;

pub fn main(init: std.process.Init.Minimal) !void {
    @disableInstrumentation();
    const fns = builtin.test_functions;
    var total: usize = 0;
    for (fns) |f| {
        if (std.mem.indexOf(u8, f.name, "golden") != null) total += 1;
    }
    var ok: usize = 0;
    var fail: usize = 0;
    var leaks: usize = 0;
    var run: usize = 0;
    for (fns) |test_fn| {
        if (std.mem.indexOf(u8, test_fn.name, "golden") == null) continue;
        run += 1;
        testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            testing.io_instance.deinit();
            if (testing.allocator_instance.deinit() != 0) leaks += 1;
        }
        testing.log_level = .warn;
        testing.environ = init.environ;
        std.debug.print("{d}/{d} {s}...", .{ run, total, test_fn.name });
        if (test_fn.func()) |_| {
            ok += 1;
            std.debug.print("OK\n", .{});
        } else |err| switch (err) {
            error.SkipZigTest => std.debug.print("SKIP\n", .{}),
            else => {
                fail += 1;
                std.debug.print("FAIL ({t})\n", .{err});
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }
    if (ok == total) {
        std.debug.print("All {d} golden tests passed.\n", .{ok});
    } else {
        std.debug.print("{d} passed; {d} failed.\n", .{ ok, fail });
    }
    if (log_err_count != 0) std.debug.print("{d} errors were logged.\n", .{log_err_count});
    if (leaks != 0) std.debug.print("{d} tests leaked memory.\n", .{leaks});
    if (leaks != 0 or log_err_count != 0 or fail != 0) {
        std.process.exit(1);
    }
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@backingInt(message_level) <= @backingInt(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@backingInt(message_level) <= @backingInt(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
