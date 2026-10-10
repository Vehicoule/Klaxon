// Klaxon — build script (Phase 0.2/0.3).
// Builds the kx_skia C++/ObjC++ shim, links Skia + SDL3 (static, from deps/),
// and builds the hello app. The deps tag must match scripts/fetch-deps.sh.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Deps tag — must match the TAG logic in scripts/fetch-deps.sh.
    const tag: []const u8 = switch (target.result.os.tag) {
        .macos => "macos-arm64", // arm64 only, no x64
        .linux => if (target.result.cpu.arch == .x86_64) "linux-x64" else "linux-arm64",
        else => @panic("unsupported target OS (see scripts/fetch-deps.sh)"),
    };
    const is_macos = target.result.os.tag == .macos;

    // --- kx_skia shim (C++ / ObjC++ static lib) ---
    const kx_skia = b.addLibrary(.{
        .name = "kx_skia",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    const shim_flags = &[_][]const u8{
        "-std=c++20",  "-fno-exceptions", "-fno-rtti",
        "-DSK_GANESH", "-DSK_GRAPHITE",   "-DNDEBUG",
    };
    kx_skia.root_module.addCSourceFiles(.{
        .files = &.{"kx_skia/src/kx_skia_common.cpp"},
        .flags = shim_flags,
        .language = .cpp,
    });
    switch (target.result.os.tag) {
        .macos => {
            kx_skia.root_module.addCSourceFiles(.{
                .files = &.{"kx_skia/src/kx_skia_macos.mm"},
                .flags = shim_flags,
                .language = .objective_cpp,
            });
            kx_skia.root_module.addCSourceFiles(.{
                .files = &.{"kx_skia/src/kx_a11y_macos.mm"},
                .flags = shim_flags,
                .language = .objective_cpp,
            });
        },
        .linux => kx_skia.root_module.addCSourceFiles(.{
            .files = &.{"kx_skia/src/kx_skia_linux.cpp"},
            .flags = shim_flags,
            .language = .cpp,
        }),
        else => @panic("no kx_skia platform impl for this OS yet (add kx_skia/src/kx_skia_<os>)"),
    }
    kx_skia.root_module.addIncludePath(b.path("kx_skia/include"));
    kx_skia.root_module.addIncludePath(b.path("deps/skia"));
    kx_skia.root_module.addIncludePath(b.path("deps/skia/include"));
    kx_skia.root_module.addIncludePath(b.path("deps/SDL/include"));
    if (is_macos) {
        inline for (.{ "Metal", "QuartzCore", "Foundation", "CoreGraphics", "CoreText", "CoreFoundation", "IOSurface" }) |fw| {
            kx_skia.root_module.linkFramework(fw, .{});
        }
    }

    // C bindings: SDL3 (sdl_c) + kx_skia (kx_c) via zig translate-c
    // (Zig 0.17 removed @cImport — b.addTranslateC is the replacement).
    const translate_sdl = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl_c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_sdl.addIncludePath(b.path("deps/SDL/include"));

    const translate_kx = b.addTranslateC(.{
        .root_source_file = b.path("kx_skia/include/kx_skia.h"),
        .target = target,
        .optimize = optimize,
    });

    // --- hello app ---
    const exe = addApp(b, target, optimize, "hello", "src/main.zig", translate_sdl, translate_kx, kx_skia, is_macos, tag);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run the hello app");
    run_step.dependOn(&run.step);

    // --- gallery app (Phase 1g) ---
    const gallery_exe = addApp(b, target, optimize, "gallery", "src/gallery_main.zig", translate_sdl, translate_kx, kx_skia, is_macos, tag);
    b.installArtifact(gallery_exe);

    const run_gallery = b.addRunArtifact(gallery_exe);
    run_gallery.step.dependOn(b.getInstallStep());
    const gallery_step = b.step("gallery", "Build and run the gallery app");
    gallery_step.dependOn(&run_gallery.step);

    // --- navigator demo app (Phase 2a) ---
    const nav_exe = addApp(b, target, optimize, "navigator", "src/navigator_main.zig", translate_sdl, translate_kx, kx_skia, is_macos, tag);
    b.installArtifact(nav_exe);

    const run_nav = b.addRunArtifact(nav_exe);
    run_nav.step.dependOn(b.getInstallStep());
    const nav_step = b.step("navigator", "Build and run the navigator demo app");
    nav_step.dependOn(&run_nav.step);

    // --- i18n demo app (Phase 2b) ---
    const i18n_exe = addApp(b, target, optimize, "i18n", "src/i18n_main.zig", translate_sdl, translate_kx, kx_skia, is_macos, tag);
    b.installArtifact(i18n_exe);

    const run_i18n = b.addRunArtifact(i18n_exe);
    run_i18n.step.dependOn(b.getInstallStep());
    const i18n_step = b.step("i18n", "Build and run the i18n demo app");
    i18n_step.dependOn(&run_i18n.step);

    // --- a11y demo app (Phase 2c) ---
    const a11y_exe = addApp(b, target, optimize, "a11y", "src/a11y_main.zig", translate_sdl, translate_kx, kx_skia, is_macos, tag);
    b.installArtifact(a11y_exe);

    const run_a11y = b.addRunArtifact(a11y_exe);
    run_a11y.step.dependOn(b.getInstallStep());
    const a11y_step = b.step("a11y", "Build and run the a11y demo app");
    a11y_step.dependOn(&run_a11y.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    tests.root_module.addImport("sdl_c", translate_sdl.createModule());
    tests.root_module.addImport("kx_c", translate_kx.createModule());
    // Golden tests render through the shim: the test exe links the same runtime.
    linkRuntime(b, tests.root_module, kx_skia, is_macos, tag);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Golden tests only. The 0.17 compile-time --test-filter only matches
    // tests declared in the ROOT module, and this repo's tests live in the
    // widget modules (pulled in via refAllDecls) — so the golden suite uses
    // a custom test runner that filters by test name at runtime.
    const golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
        .test_runner = .{ .path = b.path("src/test_runner_golden.zig"), .mode = .simple },
    });
    golden_tests.root_module.addImport("sdl_c", translate_sdl.createModule());
    golden_tests.root_module.addImport("kx_c", translate_kx.createModule());
    linkRuntime(b, golden_tests.root_module, kx_skia, is_macos, tag);
    const run_golden = b.addRunArtifact(golden_tests);
    const golden_step = b.step("test-golden", "Run golden tests only");
    golden_step.dependOn(&run_golden.step);

    // --- package-macos: build + bundle a .app (macOS only) ---
    if (is_macos) {
        const pkg = b.addSystemCommand(&.{ "scripts/package-macos.sh", "gallery", "./dist" });
        pkg.step.dependOn(b.getInstallStep());
        const pkg_step = b.step("package-macos", "Build + package gallery into a .app bundle (macOS)");
        pkg_step.dependOn(&pkg.step);
    }
}

/// Create an app executable: module + C bindings + runtime link.
fn addApp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_src: []const u8,
    translate_sdl: *std.Build.Step.TranslateC,
    translate_kx: *std.Build.Step.TranslateC,
    kx_skia: *std.Build.Step.Compile,
    is_macos: bool,
    tag: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_src),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    exe.root_module.addImport("sdl_c", translate_sdl.createModule());
    exe.root_module.addImport("kx_c", translate_kx.createModule());
    linkRuntime(b, exe.root_module, kx_skia, is_macos, tag);
    return exe;
}

/// Link the runtime (SDL3 static + kx_skia shim + Skia static libs + macOS
/// frameworks) into a module. Shared by the exe and the test exe.
fn linkRuntime(
    b: *std.Build,
    module: *std.Build.Module,
    kx_skia: *std.Build.Step.Compile,
    is_macos: bool,
    tag: []const u8,
) void {
    // SDL3 (static lib).
    module.addObjectFile(b.path(b.fmt("deps/SDL/build-{s}/libSDL3.a", .{tag})));
    if (is_macos) {
        inline for (.{
            "Cocoa",                  "IOKit",          "CoreVideo",      "CoreAudio",    "AudioToolbox", "AudioUnit",
            "ForceFeedback",          "GameController", "Metal",          "QuartzCore",   "CoreHaptics",  "AVFoundation",
            "UniformTypeIdentifiers", "CoreBluetooth",  "CoreFoundation", "CoreGraphics", "Carbon",
        }) |framework| {
            module.linkFramework(framework, .{});
        }
    }

    // kx_skia shim + Skia static libs. The .a list is deterministic for our
    // args.gn (scripts/fetch-deps.sh) — update both together if args.gn changes.
    module.linkLibrary(kx_skia);
    const skia_libs = [_][]const u8{
        "libfreetype2.a", "libharfbuzz.a",    "libicu.a",      "libpng.a",            "libskcms.a",
        "libskia.a",      "libskparagraph.a", "libskshaper.a", "libskunicode_core.a", "libskunicode_icu.a",
        "libzlib.a",
    };
    for (skia_libs) |lib| {
        module.addObjectFile(b.path(b.fmt("deps/skia/out/{s}/{s}", .{ tag, lib })));
    }
    if (is_macos) {
        inline for (.{ "Metal", "Foundation", "CoreFoundation", "CoreGraphics", "CoreText", "QuartzCore", "IOSurface" }) |fw| {
            module.linkFramework(fw, .{});
        }
    }
}
