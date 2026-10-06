// Klaxon — build script (Phase 0.2).
// Links SDL3 (static, from deps/) and builds the hello app.
// The deps tag must match scripts/fetch-deps.sh.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Deps tag — must match the TAG logic in scripts/fetch-deps.sh.
    const tag: []const u8 = switch (target.result.os.tag) {
        .macos => "macos-arm64", // arm64 only, no x64
        .linux => if (target.result.cpu.arch == .x86_64) "linux-x64" else "linux-arm64",
        else => @panic("unsupported target OS (see scripts/fetch-deps.sh)"),
    };

    // SDL3 (static lib + bindings). Bindings come from `zig translate-c` over
    // src/sdl_c.h (Zig 0.17 removed @cImport — b.addTranslateC is the replacement).
    const translate_sdl = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl_c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_sdl.addIncludePath(b.path("deps/SDL/include"));
    exe.root_module.addImport("sdl_c", translate_sdl.createModule());
    exe.root_module.addObjectFile(b.path(b.fmt("deps/SDL/build-{s}/libSDL3.a", .{tag})));
    if (target.result.os.tag == .macos) {
        inline for (.{
            "Cocoa", "IOKit", "CoreVideo", "CoreAudio", "AudioToolbox", "AudioUnit",
            "ForceFeedback", "GameController", "Metal", "QuartzCore", "CoreHaptics",
            "AVFoundation", "UniformTypeIdentifiers", "CoreBluetooth", "CoreFoundation",
            "CoreGraphics", "Carbon",
        }) |framework| {
            exe.root_module.linkFramework(framework, .{});
        }
    }

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run the hello app");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("sdl_c", translate_sdl.createModule());
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
