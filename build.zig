// Klaxon — build script (Phase 0.2/0.3).
// Builds the kx_skia C++/ObjC++ shim, links Skia + SDL3 (static, from deps/),
// and builds the hello app. The deps tag must match scripts/fetch-deps.sh.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Phase 3f: wasm32-emscripten web target (docs/specs/phase-3f-wasm-plan.md).
    const is_wasm = target.result.os.tag == .emscripten;
    // Phase 3d: Android target (aarch64-linux-android).
    const is_android = target.result.os.tag == .linux and target.result.abi == .android;
    // Phase 3e: iOS target (aarch64-ios.15.0 / aarch64-ios.15.0-simulator).
    const is_ios = target.result.os.tag == .ios;

    // Deps tag — must match the TAG logic in scripts/fetch-deps.sh.
    const tag: []const u8 = if (is_wasm)
        "web-wasm" // emsdk + Skia out/web-wasm + SDL build-web-wasm
    else if (is_android)
        "android-arm64" // Skia out/android-arm64 + SDL build-android-arm64 (CMake/NDK)
    else if (is_ios)
        if (target.result.abi == .simulator) "ios-sim-arm64" else "ios-arm64"
    else switch (target.result.os.tag) {
        .macos => "macos-arm64", // arm64 only, no x64
        .linux => if (target.result.cpu.arch == .x86_64) "linux-x64" else "linux-arm64",
        .windows => if (target.result.cpu.arch == .x86_64) "windows-x64" else "windows-arm64",
        else => @panic("unsupported target OS (see scripts/fetch-deps.sh)"),
    };
    const is_macos = target.result.os.tag == .macos;

    // The wasm target gets its own build graph (static lib + emcc link step);
    // the native steps (run/test/test-golden/gallery/...) are not defined for it.
    if (is_wasm) {
        addWasmWeb(b, target, optimize, tag);
        return;
    }

    // Phase 3d/3e: android + ios get their own build graphs (static lib +
    // external link step); the native steps are not defined for them.
    if (is_android) {
        addAndroidLib(b, target, optimize, tag);
        return;
    }
    if (is_ios) {
        addIosApp(b, target, optimize, tag);
        return;
    }

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

        // --- package-macos-dmg: same + drag-and-drop .dmg (Phase 3b.3) ---
        const pkg_dmg = b.addSystemCommand(&.{ "scripts/package-macos.sh", "gallery", "./dist", "--dmg" });
        pkg_dmg.step.dependOn(b.getInstallStep());
        const pkg_dmg_step = b.step("package-macos-dmg", "Build + package gallery into a .dmg (macOS)");
        pkg_dmg_step.dependOn(&pkg_dmg.step);
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

/// Phase 3f web target (wasm32-emscripten). Zig cannot link an executable for
/// emscripten, so the app is built as a static library and the final link is a
/// manual emcc step (sokol-zig pattern — docs/specs/phase-3f-wasm-plan.md §2):
///
///   libhello.a + libkx_skia.a + libSDL3.a + libskia*.wasm.a
///     -- emcc --> zig-out/web/hello.html (+ .js + .wasm)
///
/// No LTO anywhere on this path (LTO miscompiles wasm — plan §2), no pthreads,
/// no Asyncify: the browser owns the main thread (rAF loop).
fn addWasmWeb(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tag: []const u8,
) void {
    const emsdk = "deps/emsdk";
    // Emscripten sysroot: <emscripten.h>, <GLES3/gl32.h>, musl headers.
    const sysroot_include = b.fmt("{s}/upstream/emscripten/cache/sysroot/include", .{emsdk});

    // --- kx_skia shim (C++): common + wasm impl (Ganesh WebGL2) ---
    const kx_skia = b.addLibrary(.{
        .name = "kx_skia",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = false, // emcc links musl
            // No link_libcpp: Zig's bundled libc++ headers are incompatible
            // with the emscripten sysroot. Emscripten provides its own libc++
            // in sysroot/include/c++/v1 (added to the include path below).
            .link_libcpp = false,
        }),
    });
    const shim_flags = &[_][]const u8{
        "-std=c++20",  "-fno-exceptions", "-fno-rtti",
        "-DSK_GANESH", "-DSK_GL",         "-DSK_FORCE_8_BYTE_ALIGNMENT",
        "-DNDEBUG",
        // Disable all default include paths: zig cc adds its own musl/libc++
        // headers which conflict with the emscripten sysroot. All include paths
        // are provided explicitly below (sysroot + c++/v1 + project headers).
        "-nostdinc", "-nostdinc++",
        // Emscripten's sysroot has no xlocale.h (BSD header); tell libc++ it's
        // absent so locale_base_api.h skips the #include <xlocale.h>.
        "-D_LIBCPP_HAS_NO_XLOCALE",
    };
    kx_skia.root_module.addCSourceFiles(.{
        .files = &.{
            "kx_skia/src/kx_skia_common.cpp",
            "kx_skia/src/kx_skia_wasm.cpp",
        },
        .flags = shim_flags,
        .language = .cpp,
    });
    kx_skia.root_module.addIncludePath(b.path("kx_skia/include"));
    kx_skia.root_module.addIncludePath(b.path("deps/skia"));
    kx_skia.root_module.addIncludePath(b.path("deps/skia/include"));
    kx_skia.root_module.addIncludePath(b.path("deps/SDL/include"));
    // Include path ORDER matters: emscripten's libc++ (c++/v1) must come
    // BEFORE the sysroot C headers. libc++ wrappers (e.g. cstring) do
    // #include <string.h> expecting to find c++/v1/string.h first (which
    // then #include_next's the musl string.h). If sysroot/include comes
    // first, the musl string.h is found directly and libc++ errors out
    // ("didn't find libc++'s <string.h> header").
    kx_skia.root_module.addIncludePath(b.path(b.fmt("{s}/c++/v1", .{sysroot_include})));
    kx_skia.root_module.addIncludePath(b.path(sysroot_include));

    // C bindings: SDL3 (sdl_c) + kx_skia (kx_c) via zig translate-c, with the
    // emscripten target + sysroot include.
    const translate_sdl = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl_c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_sdl.addIncludePath(b.path("deps/SDL/include"));
    translate_sdl.addIncludePath(b.path(sysroot_include));

    const translate_kx = b.addTranslateC(.{
        .root_source_file = b.path("kx_skia/include/kx_skia.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_kx.addIncludePath(b.path(sysroot_include));

    // --- hello app as a static library (Zig cannot link an exe for emscripten) ---
    const app = b.addLibrary(.{
        .name = "hello",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false, // emcc links musl
            .link_libcpp = false, // pure Zig app; emcc links libc++ at the final link
        }),
    });
    app.root_module.addImport("sdl_c", translate_sdl.createModule());
    app.root_module.addImport("kx_c", translate_kx.createModule());
    b.installArtifact(app);
    b.installArtifact(kx_skia);

    // --- emcc link step ---
    const opt_flag: []const u8 = switch (optimize) {
        .Debug => "-O0",
        .ReleaseSafe => "-O2",
        .ReleaseFast => "-O3",
        .ReleaseSmall => "-Oz",
    };
    // Non-CanvasKit wasm builds emit lib<name>.wasm.a (gn/toolchain/BUILD.gn).
    // Same lib list as the native linkRuntime — update both together.
    const skia_libs = [_][]const u8{
        "libfreetype2.wasm.a",     "libharfbuzz.wasm.a", "libicu.wasm.a",
        "libpng.wasm.a",           "libskcms.wasm.a",    "libskia.wasm.a",
        "libskparagraph.wasm.a",   "libskshaper.wasm.a", "libskunicode_core.wasm.a",
        "libskunicode_icu.wasm.a", "libzlib.wasm.a",
    };
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(b.allocator, b.fmt("{s}/upstream/emscripten/emcc", .{emsdk})) catch unreachable;
    argv.append(b.allocator, "zig-out/lib/libhello.a") catch unreachable;
    argv.append(b.allocator, "zig-out/lib/libkx_skia.a") catch unreachable;
    argv.append(b.allocator, b.fmt("deps/SDL/build-{s}/libSDL3.a", .{tag})) catch unreachable;
    for (skia_libs) |lib| {
        argv.append(b.allocator, b.fmt("deps/skia/out/{s}/{s}", .{ tag, lib })) catch unreachable;
    }
    argv.appendSlice(b.allocator, &.{
        "-o",
        "zig-out/web/hello.html",
        "--shell-file",
        "web/shell.html",
        "--js-library",
        "web/kx_a11y.js",
        "-sUSE_WEBGL2=1",
        "-sALLOW_MEMORY_GROWTH=1",
        "-sMAXIMUM_MEMORY=2GB",
        "-sENVIRONMENT=web",
        "-sSTACK_SIZE=1MB",
        "-sEXPORTED_FUNCTIONS=_main,_kx_a11y_dump_tree,_kx_a11y_free_string,_kx_a11y_key,_kx_a11y_root_node,_kx_a11y_text",
        "-sEXPORTED_RUNTIME_METHODS=ccall,cwrap,FS,malloc,free",
        opt_flag,
    }) catch unreachable;

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/web" });
    const link = b.addSystemCommand(argv.items);
    link.step.dependOn(&mkdir.step);
    // Installs libhello.a + libkx_skia.a into zig-out/lib (paths referenced above).
    link.step.dependOn(b.getInstallStep());
    const web_step = b.step("web", "Build the wasm web target (hello.html)");
    web_step.dependOn(&link.step);
}

/// Phase 3d Android target (aarch64-linux-android). Zig cannot link an APK, so
/// the app is built as a static library and the final link is done by CMake/NDK
/// (Gradle project). The kx_skia C++ shim is NOT compiled by Zig here — CMake/NDK
/// handles it (same split as the emcc link on wasm, but with the NDK toolchain).
///
///   lib<app>.a  (zig build -Dtarget=aarch64-linux-android android-lib)
///     + kx_skia shim .o   (CMake/NDK)
///     + libSDL3.a + libskia*.a  (deps, tag android-arm64)
///       -- NDK clang++ --> lib<app>.so  (loaded by the Android app)
///
/// No run/test/package steps for android — the NDK/CMake toolchain links.
fn addAndroidLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tag: []const u8,
) void {
    _ = tag; // deps tag for the CMake/NDK link (not used by Zig here)

    // -Dandroid-app=gallery|hello (default: gallery)
    const app_opt = b.option([]const u8, "android-app", "Android app to build: gallery|hello") orelse "gallery";
    const is_hello = std.mem.eql(u8, app_opt, "hello");
    const app_name: []const u8 = if (is_hello) "hello" else "gallery";
    const root_src: []const u8 = if (is_hello) "src/main.zig" else "src/gallery_main.zig";

    // C bindings: SDL3 (sdl_c) + kx_skia (kx_c) via zig translate-c, with the
    // android target (Zig provides bionic libc headers for android targets).
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

    // App as a static library (Zig provides bionic libc for android targets).
    const app = b.addLibrary(.{
        .name = app_name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_src),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // Zig provides Android bionic libc
        }),
    });
    app.root_module.addImport("sdl_c", translate_sdl.createModule());
    app.root_module.addImport("kx_c", translate_kx.createModule());
    b.installArtifact(app);

    // Step: android-lib → zig-out/lib/lib<app>.a (CMake/NDK links the shim + Skia + SDL).
    const lib_step = b.step("android-lib", "Build the Android static library (aarch64-linux-android)");
    lib_step.dependOn(b.getInstallStep());
}

/// Phase 3e iOS target (aarch64-ios.15.0 / aarch64-ios.15.0-simulator). Zig
/// cannot link an iOS app bundle, so the app is built as a static library and
/// the final link is a manual xcrun clang++ step (same split as emcc on wasm).
/// The kx_skia ObjC++ shim is NOT compiled by Zig — xcrun clang++ handles it.
///
///   lib<app>.a  (zig build-lib -target aarch64-ios.15.0 -O ReleaseSmall)
///     + kx_skia shim .o   (xcrun clang++ -x objective-c++)
///     + libSDL3.a + libskia*.a  (deps, tag ios-arm64 / ios-sim-arm64)
///     + SDL_main TU + iOS frameworks
///       -- xcrun clang++ --> <app>.app
///
/// Guard: optimize == .ReleaseSmall is required — Zig 0.17 std.Io.Threaded
/// has a bug on iOS in Debug/ReleaseSafe.
/// No run/test steps for iOS device (cannot run on host).
fn addIosApp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tag: []const u8,
) void {
    // Guard: ReleaseSmall only (Zig 0.17 std.Io.Threaded iOS bug in Debug/ReleaseSafe).
    // Note: use .small (not .ReleaseSmall) — deprecated enum aliases only work
    // in switch statements, not in if comparisons (Zig 0.17 quirk).
    if (optimize != .small) {
        @panic("iOS target requires -Doptimize=ReleaseSmall (Zig 0.17 std.Io.Threaded bug on iOS in Debug/ReleaseSafe)");
    }

    const is_sim = target.result.abi == .simulator;
    const sdk_name: []const u8 = if (is_sim) "iphonesimulator" else "iphoneos";

    // SDK path via xcrun (runs on macOS host with Xcode installed).
    const sdk_path_raw = b.run(&.{ "xcrun", "--sdk", sdk_name, "--show-sdk-path" });
    const sdk_path = std.mem.trimEnd(u8, sdk_path_raw, "\r\n");

    // C bindings: SDL3 (sdl_c) + kx_skia (kx_c) via zig translate-c, with the
    // ios target. No -lc flag — it breaks libc detection for iOS targets.
    const translate_sdl = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl_c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_sdl.addIncludePath(b.path("deps/SDL/include"));
    translate_sdl.addIncludePath(b.graph.cwdRelativePath(sdk_path));

    const translate_kx = b.addTranslateC(.{
        .root_source_file = b.path("kx_skia/include/kx_skia.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_kx.addIncludePath(b.graph.cwdRelativePath(sdk_path));

    // App as a static library. src/main_ios.zig will be the iOS entry point;
    // for now gallery_main.zig is used as a placeholder so the graph evaluates.
    const app = b.addLibrary(.{
        .name = "gallery",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gallery_main.zig"), // placeholder for src/main_ios.zig
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    app.root_module.addImport("sdl_c", translate_sdl.createModule());
    app.root_module.addImport("kx_c", translate_kx.createModule());
    b.installArtifact(app);

    // Final link: xcrun clang++ compiles the SDL_main TU + links the static
    // lib + shim .o + Skia .a + SDL .a + iOS frameworks. The shim and deps
    // are not yet built for iOS — this step may fail at link time; the graph
    // just needs to evaluate.
    const skia_libs = [_][]const u8{
        "libfreetype2.a", "libharfbuzz.a",    "libicu.a",      "libpng.a",            "libskcms.a",
        "libskia.a",      "libskparagraph.a", "libskshaper.a", "libskunicode_core.a", "libskunicode_icu.a",
        "libzlib.a",
    };
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(b.allocator, "xcrun") catch unreachable;
    argv.append(b.allocator, "clang++") catch unreachable;
    argv.append(b.allocator, b.fmt("-isysroot{s}", .{sdk_path})) catch unreachable;
    argv.append(b.allocator, "-std=c++20") catch unreachable;
    argv.append(b.allocator, "-arch") catch unreachable;
    argv.append(b.allocator, "arm64") catch unreachable;
    argv.append(b.allocator, "-mios-version-min=15.0") catch unreachable;
    argv.append(b.allocator, "zig-out/lib/libgallery.a") catch unreachable;
    // kx_skia shim .o (compiled by xcrun clang++ from kx_skia_common.cpp + kx_skia_ios.mm)
    argv.append(b.allocator, "zig-out/lib/libkx_skia_ios.a") catch unreachable;
    // SDL3 static
    argv.append(b.allocator, b.fmt("deps/SDL/build-{s}/libSDL3.a", .{tag})) catch unreachable;
    // Skia static libs
    for (skia_libs) |lib| {
        argv.append(b.allocator, b.fmt("deps/skia/out/{s}/{s}", .{ tag, lib })) catch unreachable;
    }
    // iOS frameworks
    argv.appendSlice(b.allocator, &.{
        "-framework", "UIKit",
        "-framework", "Foundation",
        "-framework", "CoreGraphics",
        "-framework", "CoreText",
        "-framework", "QuartzCore",
        "-framework", "Metal",
        "-framework", "IOSurface",
        "-framework", "AudioToolbox",
        "-framework", "AVFoundation",
        "-framework", "CoreAudio",
        "-framework", "CoreHaptics",
        "-framework", "GameController",
        "-framework", "UniformTypeIdentifiers",
        "-framework", "CoreBluetooth",
    }) catch unreachable;
    argv.appendSlice(b.allocator, &.{ "-o", "zig-out/ios/gallery" }) catch unreachable;

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/ios" });
    const link = b.addSystemCommand(argv.items);
    link.step.dependOn(&mkdir.step);
    // Installs libgallery.a into zig-out/lib (path referenced above).
    link.step.dependOn(b.getInstallStep());

    // Steps: "ios" (hello placeholder) and "ios-gallery" (default).
    const ios_step = b.step("ios", "Build the iOS app (hello placeholder)");
    ios_step.dependOn(&link.step);
    const ios_gallery_step = b.step("ios-gallery", "Build the iOS gallery app");
    ios_gallery_step.dependOn(&link.step);
}
